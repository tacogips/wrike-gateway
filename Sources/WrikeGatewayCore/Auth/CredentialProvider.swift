import Foundation

/// Supplies the bearer credential for each request.
public protocol CredentialProvider: Sendable {
  func credential() async throws -> ResolvedCredential
  /// Refreshes after an upstream 401, returning `nil` when no refresh state
  /// exists. Only one refresh is attempted per request.
  func refreshedCredential(after stale: ResolvedCredential) async throws -> ResolvedCredential?
}

/// Resolves the process credential and owns single-flight refresh.
///
/// Precedence follows `design-authentication.md#resolution-precedence`:
/// a non-empty `WRIKE_GATEWAY_ACCESS_TOKEN` selects permanent-token mode and
/// requires a validated `WRIKE_GATEWAY_API_BASE_URL`; otherwise OAuth state is
/// loaded from the credential store and refreshed when near expiry.
public actor CredentialResolver: CredentialProvider {
  private let environment: any EnvironmentReader
  private let store: any CredentialStore
  private let clock: any GatewayClock
  private let hostPolicy: WrikeHostPolicy
  private let exchange: OAuthTokenExchange?

  /// The in-flight refresh, if any. Waiters await this task rather than
  /// submitting the old refresh token a second time.
  private var refreshInFlight: Task<OAuthTokenState, any Error>?
  private var cachedState: OAuthTokenState?

  public init(
    environment: any EnvironmentReader,
    store: any CredentialStore,
    clock: any GatewayClock = SystemClock(),
    hostPolicy: WrikeHostPolicy = .production,
    exchange: OAuthTokenExchange? = nil
  ) {
    self.environment = environment
    self.store = store
    self.clock = clock
    self.hostPolicy = hostPolicy
    self.exchange = exchange
  }

  public func credential() async throws -> ResolvedCredential {
    if let permanent = try permanentTokenCredential() {
      return permanent
    }
    let state = try await currentOAuthState()
    if state.needsRefresh(now: clock.now) {
      let refreshed = try await refreshState(from: state)
      return try credential(from: refreshed)
    }
    return try credential(from: state)
  }

  public func refreshedCredential(after stale: ResolvedCredential) async throws -> ResolvedCredential? {
    guard stale.mode == .oauth2 else { return nil }
    guard let state = try await loadState() else { return nil }
    // If another request already committed a newer record, reuse it rather than
    // spending the rotated refresh token again.
    if state.accessToken != SecretValue(stale.token.reveal()) {
      return try credential(from: state)
    }
    let refreshed = try await refreshState(from: state)
    return try credential(from: refreshed)
  }

  /// Permanent-token mode. It has no host default and performs no account
  /// discovery, so an unset or invalid base URL fails locally.
  private func permanentTokenCredential() throws -> ResolvedCredential? {
    guard let token = environment.nonEmptyValue(for: .accessToken) else { return nil }
    guard let rawBaseURL = environment.nonEmptyValue(for: .apiBaseURL) else {
      throw GatewayError.authentication(
        "\(GatewayEnvironmentKey.accessToken.rawValue) is set without \(GatewayEnvironmentKey.apiBaseURL.rawValue).",
        recovery: "Set \(GatewayEnvironmentKey.apiBaseURL.rawValue) to your data-center API base URL ending in /api/v4."
      )
    }
    let baseURL = try hostPolicy.validateBaseURL(
      rawBaseURL,
      source: GatewayEnvironmentKey.apiBaseURL.rawValue
    )
    return ResolvedCredential(
      mode: .permanentToken,
      token: SecretValue(token),
      baseURL: baseURL,
      // A permanent token exposes no inspectable scope metadata, so local scope
      // pre-checks are skipped and Wrike remains authoritative.
      grantedScopes: [],
      expiresAt: nil
    )
  }

  private func currentOAuthState() async throws -> OAuthTokenState {
    guard let state = try await loadState() else {
      throw GatewayError.authentication(
        "No Wrike credential is available.",
        recovery: "Run `auth oauth2`, or set \(GatewayEnvironmentKey.accessToken.rawValue) and \(GatewayEnvironmentKey.apiBaseURL.rawValue)."
      )
    }
    return state
  }

  private func loadState() async throws -> OAuthTokenState? {
    if let cachedState { return cachedState }
    guard let client = OAuthClientConfiguration.resolve(from: environment) else { return nil }
    for host in WrikeHostPolicy.approvedAPIHosts {
      let key = CredentialRecordKey(clientID: client.clientID, host: host)
      if let state = try await store.load(key) {
        cachedState = state
        return state
      }
    }
    return nil
  }

  /// Single-flight refresh. Concurrent callers await one committed result.
  private func refreshState(from state: OAuthTokenState) async throws -> OAuthTokenState {
    if let existing = refreshInFlight {
      return try await existing.value
    }
    guard let exchange else {
      throw GatewayError.authentication(
        "The stored Wrike credential expired and cannot be refreshed in this process.",
        recovery: "Run `auth oauth2` to authorize again."
      )
    }
    guard let client = OAuthClientConfiguration.resolve(from: environment) else {
      throw GatewayError.authentication(
        "OAuth client configuration is not available for refresh.",
        recovery: "Export \(GatewayEnvironmentKey.clientID.rawValue) and \(GatewayEnvironmentKey.clientSecret.rawValue) through kinko."
      )
    }

    let store = self.store
    let clock = self.clock
    let task = Task<OAuthTokenState, any Error> {
      let rotated = try await exchange.refresh(state, client: client, now: clock.now)
      // The new record is committed before the old one is discarded; if
      // persistence fails, the process does not claim a successful refresh.
      let key = CredentialRecordKey(clientID: client.clientID, host: rotated.host)
      try await store.replace(rotated, for: key)
      return rotated
    }
    refreshInFlight = task
    defer { refreshInFlight = nil }

    let rotated = try await task.value
    cachedState = rotated
    return rotated
  }

  private func credential(from state: OAuthTokenState) throws -> ResolvedCredential {
    ResolvedCredential(
      mode: .oauth2,
      token: state.accessToken,
      baseURL: try hostPolicy.baseURL(forOAuthHost: state.host),
      grantedScopes: state.grantedScopes,
      expiresAt: state.expiresAt
    )
  }

  /// Builds the safe `auth status` report without reading token values into
  /// any formatted output.
  public func status(hasCallbackIdentity: Bool) async -> AuthStatusReport {
    let hasClient = OAuthClientConfiguration.resolve(from: environment) != nil
    if environment.nonEmptyValue(for: .accessToken) != nil {
      let host = (try? permanentTokenCredential())?.baseURL.host
      return AuthStatusReport(
        mode: .permanentToken,
        host: host,
        scopes: [],
        expiresAt: nil,
        isExpired: false,
        hasRefreshState: false,
        hasClientConfiguration: hasClient,
        hasCallbackTLSIdentity: hasCallbackIdentity
      )
    }
    let state = try? await loadState()
    return AuthStatusReport(
      mode: state == nil ? nil : .oauth2,
      host: state?.host,
      scopes: state?.grantedScopes ?? [],
      expiresAt: state?.expiresAt,
      isExpired: state.map { $0.expiresAt <= clock.now } ?? false,
      hasRefreshState: state != nil,
      hasClientConfiguration: hasClient,
      hasCallbackTLSIdentity: hasCallbackIdentity
    )
  }

  /// Deletes local OAuth token state only. It never revokes a permanent token
  /// and never calls a Wrike resource DELETE endpoint.
  public func logout() async throws -> Bool {
    guard let client = OAuthClientConfiguration.resolve(from: environment) else { return false }
    var removed = false
    for host in WrikeHostPolicy.approvedAPIHosts {
      let key = CredentialRecordKey(clientID: client.clientID, host: host)
      if try await store.delete(key) { removed = true }
    }
    cachedState = nil
    return removed
  }

  /// Commits a newly authorized record.
  public func commit(_ state: OAuthTokenState) async throws {
    let key = CredentialRecordKey(clientID: state.clientID, host: state.host)
    try await store.replace(state, for: key)
    cachedState = state
  }
}
