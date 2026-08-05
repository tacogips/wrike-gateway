import Foundation

public enum CredentialMode: String, Sendable, Equatable {
  /// A permanent access token from `WRIKE_GATEWAY_ACCESS_TOKEN`.
  case permanentToken
  /// OAuth2 authorization-code state held in the credential store.
  case oauth2
}

/// Persisted OAuth2 token state.
///
/// The tokens are `SecretValue`s so that logging, mirroring, or interpolating
/// this record cannot disclose them.
public struct OAuthTokenState: Sendable, Equatable, Codable {
  public let accessToken: SecretValue
  public let refreshToken: SecretValue
  public let expiresAt: Date
  public let grantedScopes: [String]
  /// The data-center host Wrike reported for this account.
  public let host: String
  public let clientID: SecretValue

  public init(
    accessToken: SecretValue,
    refreshToken: SecretValue,
    expiresAt: Date,
    grantedScopes: [String],
    host: String,
    clientID: SecretValue
  ) {
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.expiresAt = expiresAt
    self.grantedScopes = grantedScopes
    self.host = host
    self.clientID = clientID
  }

  /// Refresh occurs before expiry using a bounded clock-skew allowance.
  public static let clockSkewAllowance: TimeInterval = 120

  public func needsRefresh(now: Date, skew: TimeInterval = clockSkewAllowance) -> Bool {
    expiresAt.timeIntervalSince(now) <= skew
  }
}

/// The credential selected for a single process, resolved once.
public struct ResolvedCredential: Sendable {
  public let mode: CredentialMode
  public let token: SecretValue
  public let baseURL: URL
  public let grantedScopes: [String]
  public let expiresAt: Date?

  public init(
    mode: CredentialMode,
    token: SecretValue,
    baseURL: URL,
    grantedScopes: [String],
    expiresAt: Date?
  ) {
    self.mode = mode
    self.token = token
    self.baseURL = baseURL
    self.grantedScopes = grantedScopes
    self.expiresAt = expiresAt
  }
}

/// The safe subset reported by `auth status`.
///
/// Every field is a mode name, host, scope name, timestamp, or boolean. No
/// token, client id, client secret, or Keychain record data appears here.
public struct AuthStatusReport: Sendable, Equatable {
  public let mode: CredentialMode?
  public let host: String?
  public let scopes: [String]
  public let expiresAt: Date?
  public let isExpired: Bool
  public let hasRefreshState: Bool
  public let hasClientConfiguration: Bool
  public let hasCallbackTLSIdentity: Bool

  public init(
    mode: CredentialMode?,
    host: String?,
    scopes: [String],
    expiresAt: Date?,
    isExpired: Bool,
    hasRefreshState: Bool,
    hasClientConfiguration: Bool,
    hasCallbackTLSIdentity: Bool
  ) {
    self.mode = mode
    self.host = host
    self.scopes = scopes
    self.expiresAt = expiresAt
    self.isExpired = isExpired
    self.hasRefreshState = hasRefreshState
    self.hasClientConfiguration = hasClientConfiguration
    self.hasCallbackTLSIdentity = hasCallbackTLSIdentity
  }

  public var stableValue: WrikeValue {
    let formatter = ISO8601DateFormatter()
    return .object([
      "mode": mode.map { .string($0.rawValue) } ?? .null,
      "host": host.map(WrikeValue.string) ?? .null,
      "scopes": .array(scopes.sorted().map(WrikeValue.string)),
      "expiresAt": expiresAt.map { .string(formatter.string(from: $0)) } ?? .null,
      "expired": .bool(isExpired),
      "refreshStateAvailable": .bool(hasRefreshState),
      "clientConfigured": .bool(hasClientConfiguration),
      "callbackIdentityAvailable": .bool(hasCallbackTLSIdentity)
    ])
  }
}
