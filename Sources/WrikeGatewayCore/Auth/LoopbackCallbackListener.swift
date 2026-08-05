import Foundation
import Network
import Security

/// The production OAuth callback listener.
///
/// It binds HTTPS on the fixed loopback port using the validated Keychain
/// identity, accepts exactly one request, and returns its host, port, path, and
/// query. It never writes the request line, the OAuth state, or the
/// authorization code to any output.
public struct LoopbackCallbackListener: OAuthCallbackListener {
  public init() {}

  public func awaitCallback(
    identity: CallbackTLSIdentityHandle,
    timeoutSeconds: Double
  ) async throws -> OAuthCallbackRequest {
    guard let payload = identity.payload else {
      throw GatewayError.authentication("The callback TLS identity is not usable for this listener.")
    }
    // The identity is a `SecIdentity` supplied by `KeychainTLSIdentityLoader`.
    let secIdentity = payload.identity as! SecIdentity // swiftlint:disable:this force_cast
    guard let secured = sec_identity_create(secIdentity) else {
      throw CallbackTLSIdentityFailure.privateKeyUnavailable
        .asGatewayError(label: WrikeOAuthEndpoints.callbackIdentityLabel)
    }

    let tlsOptions = NWProtocolTLS.Options()
    sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, secured)
    let parameters = NWParameters(tls: tlsOptions)
    parameters.requiredInterfaceType = .loopback
    parameters.allowLocalEndpointReuse = true

    guard let port = NWEndpoint.Port(rawValue: UInt16(WrikeOAuthEndpoints.callbackPort)) else {
      throw GatewayError.internalFailure("The fixed callback port is not valid.")
    }
    let listener = try NWListener(using: parameters, on: port)

    return try await withThrowingTaskGroup(of: OAuthCallbackRequest.self) { group in
      group.addTask {
        try await Self.accept(listener: listener)
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

  private static func accept(listener: NWListener) async throws -> OAuthCallbackRequest {
    try await withCheckedThrowingContinuation { continuation in
      let resumed = LockedBox(false)
      let finish: @Sendable (Result<OAuthCallbackRequest, any Error>) -> Void = { result in
        guard !resumed.get() else { return }
        resumed.set(true)
        continuation.resume(with: result)
      }

      listener.stateUpdateHandler = { state in
        if case .failed = state {
          finish(.failure(GatewayError.authentication(
            "The OAuth callback listener could not bind the fixed loopback port.",
            recovery: "Ensure no other process is using port \(WrikeOAuthEndpoints.callbackPort)."
          )))
        }
      }

      listener.newConnectionHandler = { connection in
        connection.start(queue: .global())
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, error in
          defer {
            // A minimal response body keeps the browser tab from showing an
            // error; it contains no OAuth data.
            let body = "HTTP/1.1 200 OK\r\nContent-Length: 22\r\nConnection: close\r\n\r\n"
              + "Authorization complete."
            connection.send(
              content: Data(body.utf8),
              completion: .contentProcessed { _ in connection.cancel() }
            )
          }
          if error != nil {
            finish(.failure(GatewayError.authentication("The OAuth callback connection failed.")))
            return
          }
          guard let data, let request = parseRequestLine(data) else {
            finish(.failure(GatewayError.authentication("The OAuth callback request was unreadable.")))
            return
          }
          finish(.success(request))
        }
      }
      listener.start(queue: .global())
    }
  }

  /// Extracts only the path and query from the request line. Headers and body
  /// are discarded without inspection.
  static func parseRequestLine(_ data: Data) -> OAuthCallbackRequest? {
    guard let text = String(data: data, encoding: .utf8) else { return nil }
    guard let line = text.split(separator: "\r\n", maxSplits: 1).first else { return nil }
    let parts = line.split(separator: " ")
    guard parts.count >= 2, parts[0] == "GET" else { return nil }
    let target = String(parts[1])
    guard let components = URLComponents(string: "https://\(WrikeOAuthEndpoints.callbackHost)\(target)") else {
      return nil
    }
    let items = (components.queryItems ?? []).map {
      WrikeQueryItem(name: $0.name, value: $0.value ?? "")
    }
    return OAuthCallbackRequest(
      host: WrikeOAuthEndpoints.callbackHost,
      port: WrikeOAuthEndpoints.callbackPort,
      path: components.path,
      queryItems: items
    )
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
