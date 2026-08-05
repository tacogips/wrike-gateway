import Foundation

/// Performs OAuth2 token and refresh exchanges against Wrike's login host.
///
/// Neither exchange is retried automatically: a repeated authorization-code
/// exchange fails by design, and a repeated refresh would resubmit a refresh
/// token that Wrike may already have rotated away.
public struct OAuthTokenExchange: Sendable {
  private let transport: any WrikeTransport
  private let tokenURL: URL
  private let hostPolicy: WrikeHostPolicy

  public init(
    transport: any WrikeTransport,
    tokenURL: URL? = URL(string: WrikeOAuthEndpoints.tokenURL),
    hostPolicy: WrikeHostPolicy = .production
  ) throws {
    guard let tokenURL else {
      throw GatewayError.internalFailure("The OAuth token endpoint is not a valid URL.")
    }
    self.transport = transport
    self.tokenURL = tokenURL
    self.hostPolicy = hostPolicy
  }

  public func exchangeAuthorizationCode(
    _ code: SecretValue,
    client: OAuthClientConfiguration,
    redirectURI: String,
    now: Date
  ) async throws -> OAuthTokenState {
    let form = [
      WrikeQueryItem(name: "client_id", value: client.clientID.reveal()),
      WrikeQueryItem(name: "client_secret", value: client.clientSecret.reveal()),
      WrikeQueryItem(name: "grant_type", value: "authorization_code"),
      WrikeQueryItem(name: "code", value: code.reveal()),
      WrikeQueryItem(name: "redirect_uri", value: redirectURI)
    ]
    return try await perform(form: form, client: client, now: now, isRefresh: false)
  }

  public func refresh(
    _ state: OAuthTokenState,
    client: OAuthClientConfiguration,
    now: Date
  ) async throws -> OAuthTokenState {
    let form = [
      WrikeQueryItem(name: "client_id", value: client.clientID.reveal()),
      WrikeQueryItem(name: "client_secret", value: client.clientSecret.reveal()),
      WrikeQueryItem(name: "grant_type", value: "refresh_token"),
      WrikeQueryItem(name: "refresh_token", value: state.refreshToken.reveal())
    ]
    return try await perform(form: form, client: client, now: now, isRefresh: true)
  }

  private func perform(
    form: [WrikeQueryItem],
    client: OAuthClientConfiguration,
    now: Date,
    isRefresh: Bool
  ) async throws -> OAuthTokenState {
    let request = PreparedRequest(
      url: tokenURL,
      method: .post,
      headers: [:],
      bearerToken: nil,
      body: .form(form),
      timeout: 30,
      capabilityID: CapabilityID("auth.token"),
      requestID: UUID().uuidString
    )

    let response: WrikeResponse
    do {
      response = try await transport.send(request)
    } catch let failure as TransportFailure {
      throw GatewayError(
        code: .transportFailed,
        message: isRefresh
          ? "The token refresh request did not complete."
          : "The authorization-code exchange did not complete.",
        outcomeUnknown: true,
        recoveryGuidance: "Run `auth oauth2` again once connectivity is restored."
      ) .withTransportContext(failure)
    }

    guard (200..<300).contains(response.statusCode) else {
      throw GatewayError.authentication(
        isRefresh
          ? "Wrike rejected the refresh token."
          : "Wrike rejected the authorization-code exchange.",
        recovery: "Run `auth oauth2` to complete a new authorization."
      )
    }

    return try decode(response.body, client: client, now: now)
  }

  /// Decodes the token response. Only the documented fields are read, and the
  /// reported data-center host is validated against the approved allowlist
  /// before it can be persisted or used to build a request URL.
  func decode(_ body: Data, client: OAuthClientConfiguration, now: Date) throws -> OAuthTokenState {
    guard let value = try? WrikeValue.decodeJSON(body), let fields = value.objectValue else {
      throw GatewayError.authentication("Wrike returned an unreadable token response.")
    }
    guard let accessToken = fields["access_token"]?.stringValue, !accessToken.isEmpty else {
      throw GatewayError.authentication("Wrike's token response did not contain an access token.")
    }
    guard let refreshToken = fields["refresh_token"]?.stringValue, !refreshToken.isEmpty else {
      throw GatewayError.authentication("Wrike's token response did not contain a refresh token.")
    }
    guard let host = fields["host"]?.stringValue, !host.isEmpty else {
      throw GatewayError.authentication("Wrike's token response did not report a data-center host.")
    }
    _ = try hostPolicy.baseURL(forOAuthHost: host)

    let expiresIn = fields["expires_in"].flatMap { entry -> Int? in
      entry.intValue ?? entry.stringValue.flatMap(Int.init)
    } ?? 3600
    let scopes = fields["scope"]?.stringValue.map { text in
      text.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
    } ?? []

    return OAuthTokenState(
      accessToken: SecretValue(accessToken),
      refreshToken: SecretValue(refreshToken),
      expiresAt: now.addingTimeInterval(TimeInterval(max(0, expiresIn))),
      grantedScopes: scopes,
      host: host.lowercased(),
      clientID: client.clientID
    )
  }
}

extension GatewayError {
  /// Attaches the safe transport summary without widening the public contract.
  func withTransportContext(_ failure: TransportFailure) -> GatewayError {
    GatewayError(
      code: code,
      message: "\(message) \(failure.safeSummary)",
      requestID: requestID,
      httpStatus: httpStatus,
      capabilityID: capabilityID,
      requiredTier: requiredTier,
      outcomeUnknown: outcomeUnknown,
      retryAfterSeconds: retryAfterSeconds,
      recoveryGuidance: recoveryGuidance
    )
  }
}
