import Foundation
import Network

/// The production OAuth callback listener.
///
/// It binds plain HTTP on the configured loopback port, accepts exactly one
/// request, and returns its host, port, path, and query. It never writes the
/// request line, the OAuth state, or the authorization code to any output.
///
/// The transport is http rather than https by design, per RFC 8252 section 7.3:
/// a native application cannot hold a certificate a browser will trust for
/// `localhost`, so the loopback interface redirect is specified to use http.
/// `requiredInterfaceType = .loopback` is the security property that replaces
/// TLS here: the socket is reachable only over the loopback interface, so the
/// authorization code never traverses a network the operator does not control.
public struct LoopbackCallbackListener: OAuthCallbackListener {
  public init() {}

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
  ///
  /// A minimal response body keeps the browser tab from showing an error; it
  /// contains no OAuth data. The length is measured rather than written by
  /// hand, so the browser cannot receive a truncated body from a header that
  /// disagrees with it.
  private static func respond(on connection: NWConnection) {
    let payload = "Authorization complete."
    let body = "HTTP/1.1 200 OK\r\nContent-Length: \(payload.utf8.count)\r\n"
      + "Content-Type: text/plain; charset=utf-8\r\nConnection: close\r\n\r\n"
      + payload
    connection.send(
      content: Data(body.utf8),
      completion: .contentProcessed { _ in connection.cancel() }
    )
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
