import Foundation

/// The exact set of environment variables this project reads. Adding a variable
/// is a contract change tracked in `design-docs/specs/design-authentication.md`.
public enum GatewayEnvironmentKey: String, Sendable, CaseIterable {
  case clientID = "WRIKE_GATEWAY_API_CLIENT_ID"
  case clientSecret = "WRIKE_GATEWAY_API_CLIENT_SECRET"
  case accessToken = "WRIKE_GATEWAY_ACCESS_TOKEN"
  case apiBaseURL = "WRIKE_GATEWAY_API_BASE_URL"
  /// The port the OAuth callback service listens on. Not a secret: the
  /// redirect URI must match one registered for the Wrike application, and the
  /// registered port differs per deployment.
  case oauthCallbackPort = "WRIKE_GATEWAY_OAUTH_CALLBACK_PORT"
}

/// Injected environment access.
public protocol EnvironmentReader: Sendable {
  func value(for key: GatewayEnvironmentKey) -> String?
  /// Every variable name present in the process environment, used to prove that
  /// no undocumented override is honoured.
  func allNames() -> Set<String>
}

public struct ProcessEnvironmentReader: EnvironmentReader {
  public init() {}

  public func value(for key: GatewayEnvironmentKey) -> String? {
    ProcessInfo.processInfo.environment[key.rawValue]
  }

  public func allNames() -> Set<String> {
    Set(ProcessInfo.processInfo.environment.keys)
  }
}

/// A fixed environment, used by tests and by hosts that embed this package as
/// a library and supply one call's credentials directly. Secret-shaped values
/// are stored as plain strings; fixtures use unmistakably fake values.
public struct StaticEnvironmentReader: EnvironmentReader {
  private let values: [String: String]

  public init(_ values: [GatewayEnvironmentKey: String] = [:], extra: [String: String] = [:]) {
    var merged = extra
    for (key, value) in values {
      merged[key.rawValue] = value
    }
    self.values = merged
  }

  public func value(for key: GatewayEnvironmentKey) -> String? {
    values[key.rawValue]
  }

  public func allNames() -> Set<String> {
    Set(values.keys)
  }
}

extension EnvironmentReader {
  /// Returns the trimmed value, treating an empty or whitespace-only variable as
  /// absent so an exported-but-blank variable cannot select a credential mode.
  func nonEmptyValue(for key: GatewayEnvironmentKey) -> String? {
    guard let raw = value(for: key) else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
