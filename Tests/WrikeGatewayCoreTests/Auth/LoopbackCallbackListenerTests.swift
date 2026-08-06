import Darwin
import Foundation
import Network
import Testing
@testable import WrikeGatewayCore

/// Real-socket helpers for the callback listener tests.
///
/// These tests drive the production `LoopbackCallbackListener` over real TCP
/// rather than a stub, because the security properties under test - loopback-only
/// reachability, one request per login, and a bounded lifetime - live in the
/// socket layer and cannot be observed through an injected seam.
private enum LoopbackProbe {
  enum ProbeError: Error {
    case socketUnavailable
    case notHTTP
    case notConnected
  }

  /// Reserves an ephemeral port and releases it, so the listener under test can
  /// bind a port nothing else on this machine is using.
  static func freePort() throws -> Int {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw ProbeError.socketUnavailable }
    defer { close(descriptor) }
    try bindLoopbackEphemeral(descriptor)
    return try assignedPort(of: descriptor)
  }

  /// Binds and listens on an ephemeral loopback port, returning the still-open
  /// descriptor. The caller closes it. Used to occupy a port deterministically,
  /// with no timing race against another listener's startup.
  static func holdPort() throws -> (descriptor: Int32, port: Int) {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw ProbeError.socketUnavailable }
    do {
      try bindLoopbackEphemeral(descriptor)
      guard listen(descriptor, 1) == 0 else { throw ProbeError.socketUnavailable }
      return (descriptor, try assignedPort(of: descriptor))
    } catch {
      close(descriptor)
      throw error
    }
  }

  private static func bindLoopbackEphemeral(_ descriptor: Int32) throws {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard result == 0 else { throw ProbeError.socketUnavailable }
  }

  private static func assignedPort(of descriptor: Int32) throws -> Int {
    var resolved = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let result = withUnsafeMutablePointer(to: &resolved) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(descriptor, $0, &length)
      }
    }
    guard result == 0 else { throw ProbeError.socketUnavailable }
    return Int(UInt16(bigEndian: resolved.sin_port))
  }

  /// Every IPv4 address on an interface that is up and is not flagged
  /// `IFF_LOOPBACK`. These are the addresses a listener must never answer on.
  static func routableIPv4Addresses() -> [String] {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0 else { return [] }
    defer { freeifaddrs(head) }

    var found: [String] = []
    var cursor = head
    while let entry = cursor {
      cursor = entry.pointee.ifa_next
      guard let raw = entry.pointee.ifa_addr, raw.pointee.sa_family == UInt8(AF_INET) else {
        continue
      }
      let flags = Int32(entry.pointee.ifa_flags)
      guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }

      var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      let named = getnameinfo(
        raw,
        socklen_t(raw.pointee.sa_len),
        &buffer,
        socklen_t(buffer.count),
        nil,
        0,
        NI_NUMERICHOST
      )
      guard named == 0 else { continue }
      // `getnameinfo` NUL-terminates; decode only the bytes before it.
      let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
      guard let address = String(data: Data(bytes), encoding: .utf8) else { continue }
      if !address.isEmpty, address != "127.0.0.1" {
        found.append(address)
      }
    }
    return found
  }

  /// Attempts a bounded TCP connection without sending anything.
  ///
  /// A refused or unanswered connection never reaches the listener's request
  /// handler, so probing does not consume the one-shot service.
  static func canConnect(host: String, port: Int, timeoutSeconds: Double) async -> Bool {
    guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return false }
    let connection = NWConnection(
      host: NWEndpoint.Host(host),
      port: endpointPort,
      using: .tcp
    )
    let claim = ResumeOnce()
    let reachable = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
      let finish: @Sendable (Bool) -> Void = { value in
        guard claim.claim() else { return }
        continuation.resume(returning: value)
      }
      connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
          finish(true)
        // `waiting` carries a connection-level error such as ECONNREFUSED and
        // Network.framework would keep retrying it, so it counts as
        // unreachable rather than as something to wait out.
        case .failed, .cancelled, .waiting:
          finish(false)
        default:
          break
        }
      }
      DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) { finish(false) }
      connection.start(queue: .global())
    }
    connection.cancel()
    return reachable
  }

  /// Issues a real HTTP GET, retrying only while the connection itself cannot be
  /// established, which is the window before the listener has finished binding.
  /// A refused connection never reaches the listener, so a retry cannot consume
  /// the one callback the service accepts.
  static func get(_ url: URL, attempts: Int = 60) async throws -> (Data, HTTPURLResponse) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.connectionProxyDictionary = [:]
    configuration.timeoutIntervalForRequest = 10
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    let session = URLSession(configuration: configuration)
    defer { session.finishTasksAndInvalidate() }

    var lastError: (any Error) = ProbeError.notConnected
    for _ in 0..<attempts {
      do {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw ProbeError.notHTTP }
        return (data, http)
      } catch {
        lastError = error
        try await Task.sleep(nanoseconds: 50_000_000)
      }
    }
    throw lastError
  }

  /// A callback URL as a browser would request it, against the numeric loopback
  /// address rather than the `localhost` name.
  static func callbackURL(port: Int, code: String, state: String) throws -> URL {
    var components = URLComponents()
    components.scheme = "http"
    components.host = "127.0.0.1"
    components.port = port
    components.path = WrikeOAuthEndpoints.callbackPath
    components.queryItems = [
      URLQueryItem(name: "code", value: code),
      URLQueryItem(name: "state", value: state)
    ]
    guard let url = components.url else { throw ProbeError.notHTTP }
    return url
  }

  /// Single-resume claim for bridging a Network.framework callback and a timer
  /// into one continuation.
  final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
      lock.lock()
      defer { lock.unlock() }
      if claimed { return false }
      claimed = true
      return true
    }
  }
}

@Suite("Loopback callback listener over real sockets")
struct LoopbackCallbackListenerTests {
  private static let code = "fake-authorization-code"
  private static let state = "fake-oauth-state-value"

  @Test("A real loopback HTTP request delivers the callback end to end")
  func deliversRealCallback() async throws {
    let port = try LoopbackProbe.freePort()
    let listener = LoopbackCallbackListener()
    async let delivered = listener.awaitCallback(port: port, timeoutSeconds: 20)

    let url = try LoopbackProbe.callbackURL(port: port, code: Self.code, state: Self.state)
    let (body, response) = try await LoopbackProbe.get(url)

    // The browser tab gets a real HTTP response carrying no OAuth data.
    #expect(response.statusCode == 200)
    let rendered = try #require(String(data: body, encoding: .utf8))
    #expect(rendered == "Authorization complete.")
    #expect(!rendered.contains(Self.code))
    #expect(!rendered.contains(Self.state))

    let request = try await delivered
    #expect(request.host == WrikeOAuthEndpoints.callbackHost)
    #expect(request.port == port)
    #expect(request.path == WrikeOAuthEndpoints.callbackPath)
    #expect(request.queryValue("code") == Self.code)
    #expect(request.queryValue("state") == Self.state)

    // The delivered request validates against the pending flow, so a real
    // socket round trip produces a callback the validator accepts.
    let result = try OAuthCallbackValidator.validate(
      request,
      expectedState: SecretValue(Self.state),
      expectedPort: port
    )
    #expect(result.code.reveal() == Self.code)

    // The service serves exactly one request and stops when the flow returns.
    let stillListening = await LoopbackProbe.canConnect(
      host: "127.0.0.1",
      port: port,
      timeoutSeconds: 2
    )
    #expect(!stillListening, "The one-shot callback service must stop after one request")
  }

  @Test("The listener answers on loopback and on no routable interface address")
  func refusesRoutableInterfaces() async throws {
    // If this machine reports no interface that is up, carries an IPv4 address,
    // and is not flagged IFF_LOOPBACK, then there is no address from which a
    // non-loopback connection attempt can be made at all and the negative
    // assertion has nothing to run against. The loopback delivery below still
    // runs in that case, so the test never passes without proving something.
    let routable = LoopbackProbe.routableIPv4Addresses()
    let port = try LoopbackProbe.freePort()
    let listener = LoopbackCallbackListener()
    async let delivered = listener.awaitCallback(port: port, timeoutSeconds: 30)

    for address in routable {
      let reachable = await LoopbackProbe.canConnect(
        host: address,
        port: port,
        timeoutSeconds: 2
      )
      #expect(!reachable, "The callback service must not answer on routable address \(address)")
    }

    // Positive control: the same listener, on the same port, is reachable over
    // loopback. Without it, a refused routable connection could just mean the
    // listener had not bound yet.
    let url = try LoopbackProbe.callbackURL(port: port, code: Self.code, state: Self.state)
    let (_, response) = try await LoopbackProbe.get(url)
    #expect(response.statusCode == 200)
    let request = try await delivered
    #expect(request.queryValue("code") == Self.code)
  }

  @Test("A callback that never arrives times out and releases the port")
  func timesOutAndStopsListening() async throws {
    let port = try LoopbackProbe.freePort()
    let listener = LoopbackCallbackListener()

    do {
      _ = try await listener.awaitCallback(port: port, timeoutSeconds: 1)
      Issue.record("Expected the listener to time out")
    } catch let error as GatewayError {
      #expect(error.code == .authenticationFailed)
      #expect(error.exitCode == .credential)
      #expect(error.message.contains("timeout"))
      // The timeout message names no OAuth value.
      #expect(!error.description.contains(Self.state))
    }

    let stillListening = await LoopbackProbe.canConnect(
      host: "127.0.0.1",
      port: port,
      timeoutSeconds: 2
    )
    #expect(!stillListening, "A timed-out login must leave nothing listening")
  }

  @Test("A callback port already in use fails locally with actionable guidance")
  func reportsBindFailure() async throws {
    let (descriptor, port) = try LoopbackProbe.holdPort()
    defer { close(descriptor) }

    let listener = LoopbackCallbackListener()
    do {
      _ = try await listener.awaitCallback(port: port, timeoutSeconds: 10)
      Issue.record("Expected the bind to fail while the port is occupied")
    } catch let error as GatewayError {
      #expect(error.code == .authenticationFailed)
      let combined = error.message + (error.recoveryGuidance ?? "")
      #expect(combined.contains("\(port)"))
      #expect(combined.contains(GatewayEnvironmentKey.oauthCallbackPort.rawValue))
    }
  }

  @Test("An out-of-range callback port is refused before any socket is created")
  func rejectsInvalidPort() async throws {
    for port in [0, -1, 65_536] {
      await #expect(throws: GatewayError.self) {
        _ = try await LoopbackCallbackListener().awaitCallback(port: port, timeoutSeconds: 1)
      }
    }
  }

  @Test("A non-GET or unparsable request is refused rather than delivered")
  func refusesUnparsableRequest() async throws {
    #expect(LoopbackCallbackListener.parseRequestLine(Data()) == nil)
    #expect(LoopbackCallbackListener.parseRequestLine(Data("POST /callback HTTP/1.1\r\n".utf8)) == nil)
    #expect(LoopbackCallbackListener.parseRequestLine(Data("garbage\r\n".utf8)) == nil)

    let parsed = LoopbackCallbackListener.parseRequestLine(
      Data("GET /callback?code=abc&state=def HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8),
      port: 8765
    )
    let request = try #require(parsed)
    #expect(request.path == "/callback")
    #expect(request.port == 8765)
    #expect(request.queryValue("code") == "abc")
    #expect(request.queryValue("state") == "def")
  }
}
