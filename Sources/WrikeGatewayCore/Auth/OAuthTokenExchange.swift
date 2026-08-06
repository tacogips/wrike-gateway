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
    // This policy validates the data-center host Wrike returns in the token
    // response, so it is the API policy. The request itself is gated by the
    // injected transport's policy, which must admit the login host.
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
    // A refresh response updates the record it was issued against rather than
    // replacing it, so the previous state is carried in for the fields RFC 6749
    // allows the server to omit.
    return try await perform(form: form, client: client, now: now, isRefresh: true, previous: state)
  }

  private func perform(
    form: [WrikeQueryItem],
    client: OAuthClientConfiguration,
    now: Date,
    isRefresh: Bool,
    previous: OAuthTokenState? = nil
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
      // The upstream OAuth `error` code is the only part of the failure body
      // that is surfaced. It is a short server-authored enum such as
      // `invalid_grant` or `invalid_client`, it carries no credential, and
      // without it a rejected exchange is indistinguishable from any other and
      // cannot be diagnosed. The description and the raw body stay unread.
      let upstream = Self.oauthErrorCode(in: response.body)
      let detail = upstream.map { " Wrike reported \($0)." } ?? ""
      throw GatewayError.authentication(
        (isRefresh
          ? "Wrike rejected the refresh token."
          : "Wrike rejected the authorization-code exchange.") + detail,
        recovery: "Run `auth oauth2` to complete a new authorization."
      )
    }

    return try decode(response.body, client: client, now: now, previous: previous)
  }

  /// Reads the OAuth `error` code from a failure body.
  ///
  /// Only a short, well-formed token is accepted, so a server that returned
  /// something unexpected in that field cannot push arbitrary text into an
  /// error message.
  static func oauthErrorCode(in body: Data) -> String? {
    guard let value = try? WrikeValue.decodeJSON(body),
          let fields = value.objectValue,
          let raw = fields["error"]?.stringValue
    else {
      return nil
    }
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz_-")
    let trimmed = raw.lowercased().trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, trimmed.count <= 64,
          trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) })
    else {
      return nil
    }
    return trimmed
  }

  /// Decodes the token response. Only the documented fields are read, and the
  /// reported data-center host is validated against the approved allowlist
  /// before it can be persisted or used to build a request URL.
  ///
  /// `previous` is the record a refresh was issued against, and it is `nil` for
  /// an authorization-code exchange. A refresh response is an update rather
  /// than a replacement: RFC 6749 section 5.1 makes `scope` optional when it is
  /// unchanged, and section 6 makes reissuing a refresh token optional, so a
  /// response that omits either must leave the stored value in place. Reading
  /// an omitted field as an absent one would silently empty the granted scopes,
  /// which both misreports `auth status` and disables the local scope
  /// pre-check, or would force a new browser authorization while the stored
  /// refresh token is still valid.
  func decode(
    _ body: Data,
    client: OAuthClientConfiguration,
    now: Date,
    previous: OAuthTokenState? = nil
  ) throws -> OAuthTokenState {
    guard let value = try? WrikeValue.decodeJSON(body), let fields = value.objectValue else {
      throw GatewayError.authentication("Wrike returned an unreadable token response.")
    }
    guard let accessToken = fields["access_token"]?.stringValue, !accessToken.isEmpty else {
      throw GatewayError.authentication("Wrike's token response did not contain an access token.")
    }
    let rotatedRefreshToken = fields["refresh_token"]?.stringValue.flatMap { token in
      token.isEmpty ? nil : SecretValue(token)
    }
    guard let refreshToken = rotatedRefreshToken ?? previous?.refreshToken else {
      throw GatewayError.authentication("Wrike's token response did not contain a refresh token.")
    }
    let reportedHost = fields["host"]?.stringValue.flatMap { host in
      host.isEmpty ? nil : host.lowercased()
    }
    guard let host = reportedHost ?? previous?.host else {
      throw GatewayError.authentication("Wrike's token response did not report a data-center host.")
    }
    _ = try hostPolicy.baseURL(forOAuthHost: host)

    let expiresIn = fields["expires_in"].flatMap { entry -> Int? in
      entry.intValue ?? entry.stringValue.flatMap(Int.init)
    } ?? 3600
    // A present but empty `scope` carries no information, so it is treated the
    // same as an omitted one rather than as a grant of nothing.
    let reportedScopes = fields["scope"]?.stringValue.map { text in
      text.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
    }.flatMap { $0.isEmpty ? nil : $0 }
    let scopes = reportedScopes ?? previous?.grantedScopes ?? []

    return OAuthTokenState(
      accessToken: SecretValue(accessToken),
      refreshToken: refreshToken,
      expiresAt: now.addingTimeInterval(TimeInterval(max(0, expiresIn))),
      grantedScopes: scopes,
      host: host,
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
