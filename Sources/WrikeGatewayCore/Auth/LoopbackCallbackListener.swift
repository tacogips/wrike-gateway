import Foundation

#if canImport(Network)
import Network
#else
import Glibc
#endif

/// The production OAuth callback listener.
///
/// It binds plain HTTP on the configured loopback port, accepts exactly one
/// request, and returns its host, port, path, and query. It never writes the
/// request line, the OAuth state, or the authorization code to any output.
///
/// The transport is http rather than https by design, per RFC 8252 section 7.3:
/// a native application cannot hold a certificate a browser will trust for
/// `localhost`, so the loopback interface redirect is specified to use http.
/// On Apple platforms `requiredInterfaceType = .loopback` is the security
/// property that replaces TLS here; on Linux the socket is bound explicitly to
/// 127.0.0.1. Either way the socket is reachable only over the loopback
/// interface, so the authorization code never traverses a network the operator
/// does not control.
public struct LoopbackCallbackListener: OAuthCallbackListener {
  public init() {}

  #if canImport(Network)
  public func awaitCallback(
    port callbackPort: Int,
    timeoutSeconds: Double
  ) async throws -> OAuthCallbackRequest {
    let parameters = NWParameters.tcp
    parameters.requiredInterfaceType = .loopback
    parameters.allowLocalEndpointReuse = true

    guard (1...65535).contains(callbackPort),
          let port = NWEndpoint.Port(rawValue: UInt16(callbackPort))
    else {
      throw GatewayError.internalFailure("The configured callback port is not valid.")
    }
    let listener = try NWListener(using: parameters, on: port)

    return try await withThrowingTaskGroup(of: OAuthCallbackRequest.self) { group in
      group.addTask {
        try await Self.accept(listener: listener, port: callbackPort)
      }
      group.addTask {
        try await Task.sleep(nanoseconds: UInt64(max(1, timeoutSeconds) * 1_000_000_000))
        throw GatewayError.authentication(
          "The OAuth callback did not arrive before the timeout elapsed.",
          recovery: "Run `auth oauth2` again and complete authorization in the browser."
        )
      }
      defer {
        group.cancelAll()
        listener.cancel()
      }
      guard let first = try await group.next() else {
        throw GatewayError.authentication("The OAuth callback listener stopped unexpectedly.")
      }
      return first
    }
  }

  private static func accept(
    listener: NWListener,
    port callbackPort: Int
  ) async throws -> OAuthCallbackRequest {
    let resumed = LockedBox(false)
    // The cancellation handler cancels the listener, which drives the state
    // handler to `.cancelled` and resumes the continuation. Without it, the
    // timeout branch of the enclosing group wins, this task is cancelled, and
    // the continuation is never resumed: the task stays suspended forever and
    // the runtime reports a leaked continuation.
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let finish: @Sendable (Result<OAuthCallbackRequest, any Error>) -> Void = { result in
          // A bind failure, a cancellation, and a connection failure can arrive
          // concurrently on the global queue, so the guard must claim the
          // continuation under a single lock acquisition; a check-then-act pair
          // would let two callbacks resume it, which traps at runtime.
          guard resumed.markResumed() else { return }
          continuation.resume(with: result)
        }

        // A listener cancelled before it is started never reports a state, so
        // an already-cancelled task is resolved here rather than waited on.
        if Task.isCancelled {
          finish(.failure(GatewayError.authentication(
            "The OAuth callback listener stopped before a callback arrived."
          )))
          return
        }

        listener.stateUpdateHandler = { state in
          switch state {
          case .failed:
            finish(.failure(GatewayError.authentication(
              "The OAuth callback listener could not bind the configured loopback port.",
              recovery: "Ensure no other process is using port \(callbackPort), or set "
                + "\(GatewayEnvironmentKey.oauthCallbackPort.rawValue) to a free port that "
                + "matches a redirect URI registered for the Wrike application."
            )))
          case .cancelled:
            finish(.failure(GatewayError.authentication(
              "The OAuth callback listener stopped before a callback arrived."
            )))
          default:
            break
          }
        }

        listener.newConnectionHandler = { connection in
          connection.start(queue: .global())
          receiveRequestLine(
            on: connection,
            accumulated: Data(),
            port: callbackPort,
            finish: finish
          )
        }
        listener.start(queue: .global())
      }
    } onCancel: {
      listener.cancel()
    }
  }
  #endif

  /// The most the listener buffers while waiting for the request line to
  /// finish arriving. A browser's callback request line is far smaller, so a
  /// peer that never sends a terminator is refused rather than read forever.
  static let maximumRequestLineBytes = 8192

  /// What a received buffer says about the request line so far.
  enum RequestLineOutcome: Equatable {
    case complete(OAuthCallbackRequest)
    /// No line terminator has arrived yet, so the buffer must not be parsed.
    case incomplete
    case invalid
  }

  #if canImport(Network)
  /// Reads until the request line is complete, then delivers or refuses it.
  ///
  /// The request must not be parsed from whatever the first read happens to
  /// return. A browser may split the callback GET across TCP segments, and the
  /// authorization code and OAuth state make that line long enough for it to
  /// happen; parsing a partial line would silently truncate the code and send
  /// the truncated value to Wrike's token endpoint, which reports only
  /// `invalid_grant`.
  private static func receiveRequestLine(
    on connection: NWConnection,
    accumulated: Data,
    port callbackPort: Int,
    finish: @escaping @Sendable (Result<OAuthCallbackRequest, any Error>) -> Void
  ) {
    connection.receive(
      minimumIncompleteLength: 1,
      maximumLength: maximumRequestLineBytes
    ) { data, _, isComplete, error in
      if error != nil {
        respond(on: connection)
        finish(.failure(GatewayError.authentication("The OAuth callback connection failed.")))
        return
      }
      var buffer = accumulated
      if let data { buffer.append(data) }

      switch requestLineOutcome(buffer, port: callbackPort) {
      case .complete(let request):
        respond(on: connection)
        finish(.success(request))
      case .invalid:
        respond(on: connection)
        finish(.failure(
          GatewayError.authentication("The OAuth callback request was unreadable.")
        ))
      case .incomplete:
        guard !isComplete, buffer.count < maximumRequestLineBytes else {
          respond(on: connection)
          finish(.failure(
            GatewayError.authentication("The OAuth callback request was unreadable.")
          ))
          return
        }
        receiveRequestLine(
          on: connection,
          accumulated: buffer,
          port: callbackPort,
          finish: finish
        )
      }
    }
  }

  /// Answers the browser and closes the connection.
  private static func respond(on connection: NWConnection) {
    connection.send(
      content: Data(successResponse.utf8),
      completion: .contentProcessed { _ in connection.cancel() }
    )
  }
  #else

  public func awaitCallback(
    port callbackPort: Int,
    timeoutSeconds: Double
  ) async throws -> OAuthCallbackRequest {
    guard (1...65535).contains(callbackPort) else {
      throw GatewayError.internalFailure("The configured callback port is not valid.")
    }
    let listenerDescriptor = try Self.bindLoopbackListener(port: callbackPort)
    defer { close(listenerDescriptor) }

    // The timeout is enforced inside the poll loop rather than by a racing
    // task, because a blocking `accept` cannot be interrupted by cancelling a
    // sibling task the way an `NWListener` can be cancelled.
    var remainingMilliseconds = Int(max(1, timeoutSeconds) * 1000)
    remainingMilliseconds = try await Self.waitReadable(
      listenerDescriptor,
      remainingMilliseconds: remainingMilliseconds
    )

    let connectionDescriptor = accept(listenerDescriptor, nil, nil)
    guard connectionDescriptor >= 0 else {
      throw GatewayError.authentication("The OAuth callback connection failed.")
    }
    defer { close(connectionDescriptor) }

    var buffer = Data()
    while true {
      remainingMilliseconds = try await Self.waitReadable(
        connectionDescriptor,
        remainingMilliseconds: remainingMilliseconds
      )
      var chunk = [UInt8](repeating: 0, count: 1024)
      let readCount = read(connectionDescriptor, &chunk, chunk.count)
      if readCount < 0 {
        if errno == EINTR { continue }
        throw GatewayError.authentication("The OAuth callback connection failed.")
      }
      buffer.append(contentsOf: chunk[0..<readCount])

      switch Self.requestLineOutcome(buffer, port: callbackPort) {
      case .complete(let request):
        Self.respond(on: connectionDescriptor)
        return request
      case .invalid:
        Self.respond(on: connectionDescriptor)
        throw GatewayError.authentication("The OAuth callback request was unreadable.")
      case .incomplete:
        guard readCount > 0, buffer.count < Self.maximumRequestLineBytes else {
          Self.respond(on: connectionDescriptor)
          throw GatewayError.authentication("The OAuth callback request was unreadable.")
        }
      }
    }
  }

  /// Binds a TCP listener explicitly to 127.0.0.1, which is what confines the
  /// callback to the loopback interface on a platform without `NWParameters`.
  private static func bindLoopbackListener(port callbackPort: Int) throws -> Int32 {
    let descriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    guard descriptor >= 0 else {
      throw GatewayError.authentication("The OAuth callback listener stopped unexpectedly.")
    }
    var reuseAddress: Int32 = 1
    _ = setsockopt(
      descriptor,
      SOL_SOCKET,
      SO_REUSEADDR,
      &reuseAddress,
      socklen_t(MemoryLayout<Int32>.size)
    )
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(UInt16(callbackPort).bigEndian)
    // 127.0.0.1; the Glibc overlay does not reliably expose INADDR_LOOPBACK.
    address.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
        bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0, listen(descriptor, 1) == 0 else {
      close(descriptor)
      throw GatewayError.authentication(
        "The OAuth callback listener could not bind the configured loopback port.",
        recovery: "Ensure no other process is using port \(callbackPort), or set "
          + "\(GatewayEnvironmentKey.oauthCallbackPort.rawValue) to a free port that "
          + "matches a redirect URI registered for the Wrike application."
      )
    }
    return descriptor
  }

  /// Polls in short slices so the timeout and task cancellation are both
  /// honoured while a blocking descriptor waits for data. Returns the timeout
  /// budget that remains, or throws once the budget is spent.
  private static func waitReadable(
    _ descriptor: Int32,
    remainingMilliseconds: Int
  ) async throws -> Int {
    var remaining = remainingMilliseconds
    while remaining > 0 {
      try Task.checkCancellation()
      let slice = Int32(min(200, remaining))
      var descriptors = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
      let result = poll(&descriptors, 1, slice)
      if result > 0 { return remaining }
      if result < 0, errno != EINTR {
        throw GatewayError.authentication("The OAuth callback listener stopped unexpectedly.")
      }
      remaining -= Int(slice)
      await Task.yield()
    }
    throw GatewayError.authentication(
      "The OAuth callback did not arrive before the timeout elapsed.",
      recovery: "Run `auth oauth2` again and complete authorization in the browser."
    )
  }

  /// Answers the browser and leaves closing to the caller's `defer`.
  private static func respond(on descriptor: Int32) {
    let bytes = Array(successResponse.utf8)
    var sent = 0
    while sent < bytes.count {
      let written = bytes.withUnsafeBytes { pointer in
        write(descriptor, pointer.baseAddress?.advanced(by: sent), bytes.count - sent)
      }
      if written <= 0 {
        if errno == EINTR { continue }
        break
      }
      sent += written
    }
  }
  #endif

  /// The reply every accepted connection receives. A minimal response body
  /// keeps the browser tab from showing an error; it contains no OAuth data.
  /// The length is measured rather than written by hand, so the browser cannot
  /// receive a truncated body from a header that disagrees with it.
  static var successResponse: String {
    let payload = "Authorization complete."
    return "HTTP/1.1 200 OK\r\nContent-Length: \(payload.utf8.count)\r\n"
      + "Content-Type: text/plain; charset=utf-8\r\nConnection: close\r\n\r\n"
      + payload
  }

  /// Extracts only the path and query from a terminated request line. Headers
  /// and body are discarded without inspection.
  static func requestLineOutcome(
    _ data: Data,
    port callbackPort: Int = WrikeOAuthEndpoints.defaultCallbackPort
  ) -> RequestLineOutcome {
    // The terminator is located in the bytes rather than in a decoded string,
    // so a buffer that ends mid-sequence is reported as incomplete instead of
    // as a decoding failure.
    guard let terminator = data.firstIndex(of: 0x0A) else { return .incomplete }
    var lineBytes = data[data.startIndex..<terminator]
    if lineBytes.last == 0x0D { lineBytes = lineBytes.dropLast() }

    guard let line = String(data: Data(lineBytes), encoding: .utf8) else { return .invalid }
    let parts = line.split(separator: " ")
    guard parts.count >= 2, parts[0] == "GET" else { return .invalid }
    let target = String(parts[1])
    guard let components = URLComponents(string: "http://\(WrikeOAuthEndpoints.callbackHost)\(target)") else {
      return .invalid
    }
    let items = (components.queryItems ?? []).map {
      WrikeQueryItem(name: $0.name, value: $0.value ?? "")
    }
    return .complete(OAuthCallbackRequest(
      host: WrikeOAuthEndpoints.callbackHost,
      port: callbackPort,
      path: components.path,
      queryItems: items
    ))
  }

  /// The delivered request, or `nil` when the buffer is not a complete and
  /// valid callback request line.
  static func parseRequestLine(
    _ data: Data,
    port callbackPort: Int = WrikeOAuthEndpoints.defaultCallbackPort
  ) -> OAuthCallbackRequest? {
    guard case .complete(let request) = requestLineOutcome(data, port: callbackPort) else {
      return nil
    }
    return request
  }
}

/// Guards the single-resume rule when bridging the listener's connection
/// callbacks into one checked continuation.
final class LockedBox<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value

  init(_ value: Value) {
    self.value = value
  }

  func set(_ newValue: Value) {
    lock.lock()
    value = newValue
    lock.unlock()
  }

  func get() -> Value {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

extension LockedBox where Value == Bool {
  /// Claims the single resume slot. Exactly one caller receives `true`, however
  /// many threads race, because the read and the write happen under one lock
  /// acquisition.
  func markResumed() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if value { return false }
    value = true
    return true
  }
}
