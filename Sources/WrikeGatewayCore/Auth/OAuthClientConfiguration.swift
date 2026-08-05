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

  /// The fixed initial redirect URI. There is deliberately no flag or
  /// environment override; `design-docs/user-qa/pending-oauth-callback.md`
  /// tracks making it configurable.
  public static let redirectURI = "https://localhost:8765/callback"
  public static let callbackHost = "localhost"
  public static let callbackPort = 8765
  public static let callbackPath = "/callback"

  /// The fixed macOS login-Keychain application label for the callback identity.
  public static let callbackIdentityLabel = "wrike-gateway.oauth.localhost"

  public static func components(ofRedirectURI raw: String) -> (host: String, port: Int, path: String)? {
    guard let components = URLComponents(string: raw),
          components.scheme?.lowercased() == "https",
          let host = components.host
    else {
      return nil
    }
    return (host.lowercased(), components.port ?? 443, components.path)
  }
}
