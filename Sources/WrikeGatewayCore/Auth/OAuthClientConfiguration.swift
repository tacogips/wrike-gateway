import Foundation

/// OAuth2 application credentials supplied by kinko-managed environment
/// variables. CLI flags never accept these values because command lines are
/// visible to other processes.
public struct OAuthClientConfiguration: Sendable {
  public let clientID: SecretValue
  public let clientSecret: SecretValue

  public init(clientID: SecretValue, clientSecret: SecretValue) {
    self.clientID = clientID
    self.clientSecret = clientSecret
  }

  public static func resolve(from environment: any EnvironmentReader) -> OAuthClientConfiguration? {
    guard let identifier = environment.nonEmptyValue(for: .clientID),
          let secret = environment.nonEmptyValue(for: .clientSecret)
    else {
      return nil
    }
    return OAuthClientConfiguration(
      clientID: SecretValue(identifier),
      clientSecret: SecretValue(secret)
    )
  }
}

/// Wrike's fixed OAuth2 endpoints, confirmed against the official OAuth 2.0
/// authorization guide on 2026-08-05.
public enum WrikeOAuthEndpoints {
  public static let authorizationURL = "https://login.wrike.com/oauth2/authorize/v4"
  public static let tokenURL = "https://login.wrike.com/oauth2/token"

  public static let callbackHost = "localhost"
  public static let callbackPath = "/callback"

  /// The port the loopback callback service listens on when nothing overrides
  /// it.
  public static let defaultCallbackPort = 8765

  /// The redirect URI for a given callback port.
  ///
  /// The scheme is `http` by design, per RFC 8252 section 7.3: a native
  /// application cannot hold a certificate a browser will trust for
  /// `localhost`, so the loopback interface redirect is specified to use http.
  /// The authorization code never leaves this machine, because the listener
  /// binds the loopback interface only.
  public static func redirectURI(port: Int) -> String {
    "http://\(callbackHost):\(port)\(callbackPath)"
  }

  /// Resolves the callback port from the environment, falling back to the
  /// default.
  ///
  /// A malformed or out-of-range value fails locally rather than silently
  /// reverting to the default, because a login that listens on a port the
  /// operator did not intend cannot receive the redirect and the reason would
  /// not be obvious.
  public static func resolveCallbackPort(
    from environment: any EnvironmentReader
  ) throws -> Int {
    guard let raw = environment.value(for: .oauthCallbackPort)?
      .trimmingCharacters(in: .whitespaces), !raw.isEmpty
    else {
      return defaultCallbackPort
    }
    guard let port = Int(raw), (1...65535).contains(port) else {
      throw GatewayError.authentication(
        "The configured OAuth callback port is not a valid TCP port.",
        recovery: "Set \(GatewayEnvironmentKey.oauthCallbackPort.rawValue) to a number between "
          + "1 and 65535, matching the redirect URI registered for the Wrike application, "
          + "or unset it to use \(defaultCallbackPort)."
      )
    }
    return port
  }

  /// The parts of the fixed redirect URI that the callback validator checks.
  public struct RedirectComponents: Sendable, Equatable {
    public let host: String
    public let port: Int
    public let path: String
  }

  public static func components(ofRedirectURI raw: String) -> RedirectComponents? {
    guard let components = URLComponents(string: raw),
          components.scheme?.lowercased() == "http",
          let host = components.host
    else {
      return nil
    }
    return RedirectComponents(
      host: host.lowercased(),
      port: components.port ?? 80,
      path: components.path
    )
  }
}
