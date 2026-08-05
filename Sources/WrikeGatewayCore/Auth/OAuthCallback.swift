import Foundation

/// The result of a validated OAuth callback.
public struct OAuthCallbackResult: Sendable, Equatable {
  public let code: SecretValue

  public init(code: SecretValue) {
    self.code = code
  }
}

/// Raw callback data as observed by a listener, before validation.
public struct OAuthCallbackRequest: Sendable, Equatable {
  public let host: String
  public let port: Int
  public let path: String
  public let queryItems: [WrikeQueryItem]

  public init(host: String, port: Int, path: String, queryItems: [WrikeQueryItem]) {
    self.host = host
    self.port = port
    self.path = path
    self.queryItems = queryItems
  }

  public func queryValue(_ name: String) -> String? {
    queryItems.first { $0.name == name }?.value
  }
}

/// Validates a loopback OAuth callback against the fixed redirect URI and the
/// pending flow's state value.
///
/// Every rejection message is state-free: the OAuth state, the authorization
/// code, and the authorization URL are never included.
public enum OAuthCallbackValidator {
  public static func validate(
    _ request: OAuthCallbackRequest,
    expectedState: SecretValue
  ) throws -> OAuthCallbackResult {
    guard request.host.lowercased() == WrikeOAuthEndpoints.callbackHost else {
      throw GatewayError.authentication("The OAuth callback arrived on an unexpected host.")
    }
    guard request.port == WrikeOAuthEndpoints.callbackPort else {
      throw GatewayError.authentication("The OAuth callback arrived on an unexpected port.")
    }
    guard request.path == WrikeOAuthEndpoints.callbackPath else {
      throw GatewayError.authentication("The OAuth callback arrived on an unexpected path.")
    }
    if let oauthError = request.queryValue("error"), !oauthError.isEmpty {
      throw GatewayError.authentication(
        "Wrike reported an OAuth error during authorization.",
        recovery: "Approve the requested scopes in the browser and run `auth oauth2` again."
      )
    }
    guard let state = request.queryValue("state"), !state.isEmpty else {
      throw GatewayError.authentication("The OAuth callback did not include a state value.")
    }
    guard constantTimeEquals(state, expectedState.reveal()) else {
      throw GatewayError.authentication("The OAuth callback state did not match the pending request.")
    }
    guard let code = request.queryValue("code"), !code.isEmpty else {
      throw GatewayError.authentication("The OAuth callback did not include an authorization code.")
    }
    return OAuthCallbackResult(code: SecretValue(code))
  }

  /// Comparison time does not depend on how many leading characters match.
  static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
    let left = Array(lhs.utf8)
    let right = Array(rhs.utf8)
    guard left.count == right.count else { return false }
    var difference: UInt8 = 0
    for index in left.indices {
      difference |= left[index] ^ right[index]
    }
    return difference == 0
  }
}

/// The loopback listener boundary. The production implementation binds the
/// fixed HTTPS port using the Keychain identity; tests substitute a listener
/// that replays a canned callback.
public protocol OAuthCallbackListener: Sendable {
  /// Binds the listener and waits for one callback, or throws on timeout.
  func awaitCallback(
    identity: CallbackTLSIdentityHandle,
    timeoutSeconds: Double
  ) async throws -> OAuthCallbackRequest
}

/// Opens a URL through the operating-system browser API.
///
/// The URL is passed as a `SecretValue` because it embeds the client id and the
/// OAuth state; there is no manual-URL output mode in the initial contract.
public protocol BrowserOpener: Sendable {
  func open(_ authorizationURL: SecretValue) throws
}

public struct SystemBrowserOpener: BrowserOpener {
  private let runner: any ProcessRunner

  public init(runner: any ProcessRunner = SystemProcessRunner()) {
    self.runner = runner
  }

  public func open(_ authorizationURL: SecretValue) throws {
    let url = authorizationURL
    let semaphore = DispatchSemaphore(value: 0)
    let outcome = LockedBox<Result<ProcessResult, any Error>?>(nil)
    let runner = self.runner
    Task.detached {
      do {
        let result = try await runner.run(
          executable: "/usr/bin/open",
          arguments: ["--background", url.reveal()],
          standardInput: nil
        )
        outcome.set(.success(result))
      } catch {
        outcome.set(.failure(error))
      }
      semaphore.signal()
    }
    semaphore.wait()

    switch outcome.get() {
    case .success(let result) where result.exitCode == 0:
      return
    default:
      throw GatewayError.authentication(
        "The system browser could not be opened for authorization.",
        recovery: "Ensure a default browser is configured, then run `auth oauth2` again."
      )
    }
  }
}

/// Minimal mutable box used to bridge a detached task result.
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
