import Foundation
import Network
import WrikeGatewayCore

/// A process-local loopback HTTP server serving canned Wrike responses.
///
/// It binds only to loopback on an ephemeral port and exists solely in the test
/// support target. It verifies real URL encoding, real HTTP headers, real
/// streamed upload bodies, and real response headers, which a recording
/// transport cannot.
public final class LoopbackHTTPServer: @unchecked Sendable {
  public struct CannedResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: String

    public init(status: Int = 200, headers: [String: String] = [:], body: String) {
      self.status = status
      self.headers = headers
      self.body = body
    }
  }

  /// A request as the server observed it on the wire.
  public struct ObservedRequest: Sendable, Equatable {
    public let method: String
    public let target: String
    public let headerNames: [String]
    public let hasAuthorizationHeader: Bool
    /// The only header value retained by the test server. Authorization and
    /// every other header value remain intentionally unobservable.
    public let uploadFileName: String?
    public let contentLength: Int
  }

  private let listener: NWListener
  private let lock = NSLock()
  private var responses: [CannedResponse]
  private var observed: [ObservedRequest] = []

  public init(responses: [CannedResponse]) throws {
    self.responses = responses
    let parameters = NWParameters.tcp
    parameters.requiredInterfaceType = .loopback
    parameters.allowLocalEndpointReuse = true
    self.listener = try NWListener(using: parameters, on: .any)
  }

  public func start() async throws {
    let ready = LoopbackReadySignal()
    listener.stateUpdateHandler = { state in
      switch state {
      case .ready:
        ready.signal(nil)
      case .failed(let error):
        ready.signal(error)
      default:
        break
      }
    }
    listener.newConnectionHandler = { [weak self] connection in
      self?.handle(connection)
    }
    listener.start(queue: .global())
    if let error = try await ready.wait() {
      throw error
    }
  }

  public func stop() {
    listener.cancel()
  }

  public var baseURL: URL {
    let port = listener.port?.rawValue ?? 0
    // The components are fixed and well-formed, so this URL always parses.
    // swiftlint:disable:next force_unwrapping
    return URL(string: "http://127.0.0.1:\(port)/api/v4")!
  }

  /// A host policy that accepts only this server. It exists in the test support
  /// target only; production composition always uses `WrikeHostPolicy.production`.
  public var hostPolicy: WrikeHostPolicy {
    WrikeHostPolicy(allowedHosts: ["127.0.0.1"], requiresHTTPS: false, requiresAPIPathPrefix: false)
  }

  public var observedRequests: [ObservedRequest] {
    lock.lock()
    defer { lock.unlock() }
    return observed
  }

  private func handle(_ connection: NWConnection) {
    connection.start(queue: .global())
    receive(connection, accumulated: Data())
  }

  private func receive(_ connection: NWConnection, accumulated: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, _ in
      guard let self else {
        connection.cancel()
        return
      }
      var buffer = accumulated
      if let data { buffer.append(data) }

      guard let parsed = Self.parse(buffer) else {
        if isComplete {
          connection.cancel()
        } else {
          self.receive(connection, accumulated: buffer)
        }
        return
      }
      // Wait for the declared body before responding, so an upload test sees
      // the full streamed payload length.
      if buffer.count < parsed.headerByteCount + parsed.request.contentLength {
        self.receive(connection, accumulated: buffer)
        return
      }

      self.lock.lock()
      self.observed.append(parsed.request)
      let response = self.responses.count > 1
        ? self.responses.removeFirst()
        : (self.responses.first ?? CannedResponse(status: 500, body: "{}"))
      self.lock.unlock()

      connection.send(
        content: Self.serialize(response),
        completion: .contentProcessed { _ in connection.cancel() }
      )
    }
  }

  static func parse(_ buffer: Data) -> (request: ObservedRequest, headerByteCount: Int)? {
    guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
    let headerBytes = buffer.subdata(in: buffer.startIndex..<separator.lowerBound)
    guard let text = String(data: headerBytes, encoding: .utf8) else { return nil }
    let lines = text.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { return nil }
    let parts = requestLine.split(separator: " ")
    guard parts.count >= 2 else { return nil }

    var headerNames: [String] = []
    var hasAuthorization = false
    var uploadFileName: String?
    var contentLength = 0
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { continue }
      let name = String(line[line.startIndex..<colon]).lowercased()
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      headerNames.append(name)
      if name == "authorization" { hasAuthorization = true }
      if name == "x-file-name" { uploadFileName = value }
      if name == "content-length" { contentLength = Int(value) ?? 0 }
    }

    return (
      ObservedRequest(
        method: String(parts[0]),
        target: String(parts[1]),
        headerNames: headerNames.sorted(),
        hasAuthorizationHeader: hasAuthorization,
        uploadFileName: uploadFileName,
        contentLength: contentLength
      ),
      separator.upperBound - buffer.startIndex
    )
  }

  static func serialize(_ response: CannedResponse) -> Data {
    let bodyData = Data(response.body.utf8)
    var head = "HTTP/1.1 \(response.status) \(reason(for: response.status))\r\n"
    head += "Content-Length: \(bodyData.count)\r\n"
    // A canned response may declare its own content type, as an attachment
    // download does. Emitting the JSON default unconditionally would send two
    // conflicting `Content-Type` headers.
    if !response.headers.keys.contains(where: { $0.lowercased() == "content-type" }) {
      head += "Content-Type: application/json\r\n"
    }
    head += "Connection: close\r\n"
    for (name, value) in response.headers.sorted(by: { $0.key < $1.key }) {
      head += "\(name): \(value)\r\n"
    }
    head += "\r\n"
    return Data(head.utf8) + bodyData
  }

  static func reason(for status: Int) -> String {
    switch status {
    case 200: return "OK"
    case 400: return "Bad Request"
    case 401: return "Unauthorized"
    case 403: return "Forbidden"
    case 404: return "Not Found"
    case 429: return "Too Many Requests"
    case 500: return "Internal Server Error"
    default: return "Status"
    }
  }
}

/// Bridges the listener's state callback into async/await exactly once.
private final class LoopbackReadySignal: @unchecked Sendable {
  private let semaphore = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var error: (any Error)?
  private var signalled = false

  func signal(_ error: (any Error)?) {
    lock.lock()
    guard !signalled else {
      lock.unlock()
      return
    }
    signalled = true
    self.error = error
    lock.unlock()
    semaphore.signal()
  }

  func wait() async throws -> (any Error)? {
    await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        _ = self.semaphore.wait(timeout: .now() + 10)
        continuation.resume()
      }
    }
    return capturedError()
  }

  private func capturedError() -> (any Error)? {
    lock.lock()
    defer { lock.unlock() }
    return error
  }
}
