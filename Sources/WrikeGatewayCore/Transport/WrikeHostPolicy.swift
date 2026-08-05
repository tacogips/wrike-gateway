import Foundation

/// Decides which hosts may receive a bearer credential.
///
/// The production policy is fixed to the Wrike data-center API hosts confirmed
/// against the official API v4 reference on 2026-08-05. Tests construct a
/// loopback policy directly; no production binary exposes a flag or environment
/// variable that widens the allowlist.
public struct WrikeHostPolicy: Sendable, Equatable {
  public static let apiPathPrefix = "/api/v4"

  /// Approved Wrike API data-center hosts.
  public static let approvedAPIHosts: [String] = [
    "www.wrike.com",
    "app-eu.wrike.com",
    "app-us2.wrike.com"
  ]

  /// Approved Wrike OAuth login host.
  public static let approvedLoginHost = "login.wrike.com"

  public let allowedHosts: Set<String>
  public let requiresHTTPS: Bool
  public let requiresAPIPathPrefix: Bool

  public init(allowedHosts: Set<String>, requiresHTTPS: Bool, requiresAPIPathPrefix: Bool) {
    self.allowedHosts = allowedHosts
    self.requiresHTTPS = requiresHTTPS
    self.requiresAPIPathPrefix = requiresAPIPathPrefix
  }

  public static let production = WrikeHostPolicy(
    allowedHosts: Set(approvedAPIHosts),
    requiresHTTPS: true,
    requiresAPIPathPrefix: true
  )

  public func allows(host: String?) -> Bool {
    guard let host else { return false }
    return allowedHosts.contains(host.lowercased())
  }

  /// Validates a configured API base URL before any credential can be attached
  /// to a request. Failures are local and never reach the network.
  public func validateBaseURL(_ raw: String, source: String) throws -> URL {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw GatewayError.authentication(
        "\(source) is empty.",
        recovery: "Set \(source) to your account's Wrike API base URL ending in /api/v4."
      )
    }
    guard var components = URLComponents(string: trimmed) else {
      throw GatewayError.authentication(
        "\(source) is not a valid URL.",
        recovery: "Use an https URL such as https://www.wrike.com/api/v4."
      )
    }
    if requiresHTTPS, components.scheme?.lowercased() != "https" {
      throw GatewayError.authentication(
        "\(source) must use https.",
        recovery: "Use an https URL such as https://www.wrike.com/api/v4."
      )
    }
    guard components.user == nil, components.password == nil else {
      throw GatewayError.authentication("\(source) must not contain user information.")
    }
    guard components.query == nil, components.fragment == nil else {
      throw GatewayError.authentication("\(source) must not contain a query or fragment.")
    }
    guard allows(host: components.host) else {
      let approved = allowedHosts.sorted().joined(separator: ", ")
      throw GatewayError.authentication(
        "\(source) host is not an approved Wrike API host.",
        recovery: "Approved hosts: \(approved)."
      )
    }

    var path = components.path
    while path.count > 1, path.hasSuffix("/") {
      path.removeLast()
    }
    if requiresAPIPathPrefix, path != Self.apiPathPrefix {
      throw GatewayError.authentication(
        "\(source) must use the \(Self.apiPathPrefix) path.",
        recovery: "Append \(Self.apiPathPrefix) to the data-center host, with no extra path segments."
      )
    }
    components.path = path

    guard let url = components.url else {
      throw GatewayError.authentication("\(source) is not a valid URL.")
    }
    return url
  }

  /// Builds an API base URL for a data-center host reported by Wrike's OAuth
  /// token response. The host is validated against the same allowlist.
  public func baseURL(forOAuthHost host: String) throws -> URL {
    try validateBaseURL("https://\(host)\(Self.apiPathPrefix)", source: "Wrike OAuth host metadata")
  }

  /// True when a redirect target may continue to carry the authorization
  /// header. A different host always drops the credential and fails the request.
  public func permitsCredentialForwarding(to url: URL, from origin: URL) -> Bool {
    guard let target = url.host?.lowercased(), let source = origin.host?.lowercased() else {
      return false
    }
    guard url.scheme?.lowercased() == "https" else { return false }
    return target == source && allows(host: target)
  }
}
