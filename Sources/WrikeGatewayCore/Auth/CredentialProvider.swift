import Foundation

/// Supplies the bearer credential for each request.
public protocol CredentialProvider: Sendable {
  func credential() async throws -> ResolvedCredential
  /// Refreshes after an upstream 401, returning `nil` when no refresh state
  /// exists. Only one refresh is attempted per request.
  func refreshedCredential(after stale: ResolvedCredential) async throws -> ResolvedCredential?
}

/// Coordinates refresh-token rotation across independently constructed
/// resolvers that address the same durable credential record.
public actor OAuthRefreshCoordinator {
  private var inFlight: [CredentialRecordKey: Task<OAuthTokenState, any Error>] = [:]
  /// A refresh token can be rotated successfully before its durable store
  /// rejects the replacement. Retain that state for the current process so a
  /// fresh facade runtime never resubmits the invalidated predecessor.
  private var undurableStates: [CredentialRecordKey: OAuthTokenState] = [:]

  public init() {}

  func refresh(
    key: CredentialRecordKey,
    operation: @escaping @Sendable () async throws -> OAuthTokenState
  ) async throws -> OAuthTokenState {
    if let task = inFlight[key] {
      return try await task.value
    }
    let task = Task<OAuthTokenState, any Error> { try await operation() }
    inFlight[key] = task
    defer { inFlight[key] = nil }
    return try await task.value
  }

  func undurableState(for key: CredentialRecordKey) -> OAuthTokenState? {
    undurableStates[key]
  }

  func rememberUndurable(_ state: OAuthTokenState, for keys: [CredentialRecordKey]) {
    for key in keys {
      undurableStates[key] = state
    }
  }

  func forgetStates(for keys: [CredentialRecordKey]) {
    for key in keys {
      undurableStates.removeValue(forKey: key)
    }
  }
}

/// A deliberately private transport for a newly issued secret state. It is
/// never rendered; `CredentialResolver` immediately records the safe retry
/// barrier and converts it to a redacted authentication error.
private struct RefreshPersistenceFailure: Error, Sendable {
  let state: OAuthTokenState
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
  private let refreshCoordinator: OAuthRefreshCoordinator
  private var cachedState: OAuthTokenState?

  public init(
    environment: any EnvironmentReader,
    store: any CredentialStore,
    clock: any GatewayClock = SystemClock(),
    hostPolicy: WrikeHostPolicy = .production,
    exchange: OAuthTokenExchange? = nil,
    refreshCoordinator: OAuthRefreshCoordinator = OAuthRefreshCoordinator()
  ) {
    self.environment = environment
    self.store = store
    self.clock = clock
    self.hostPolicy = hostPolicy
    self.exchange = exchange
    self.refreshCoordinator = refreshCoordinator
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
    var candidates: [OAuthTokenState] = []
    for host in WrikeHostPolicy.approvedAPIHosts {
      let key = CredentialRecordKey(clientID: client.clientID, host: host)
      if let state = await refreshCoordinator.undurableState(for: key) {
        candidates.append(state)
      } else if let state = try await store.load(key) {
        candidates.append(state)
      }
    }
    // Host migration may briefly leave an old and a replacement key. Choose
    // the newest credential deterministically rather than relying on host
    // enumeration order, which could otherwise resubmit an invalidated token.
    let state = candidates.max { lhs, rhs in
      if lhs.expiresAt == rhs.expiresAt { return lhs.host < rhs.host }
      return lhs.expiresAt < rhs.expiresAt
    }
    cachedState = state
    return state
  }

  /// Single-flight refresh. Concurrent callers await one committed result.
  private func refreshState(from state: OAuthTokenState) async throws -> OAuthTokenState {
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
    let key = CredentialRecordKey(clientID: client.clientID, host: state.host)
    do {
      let rotated = try await refreshCoordinator.refresh(key: key) {
        if let persisted = try await store.load(key),
           persisted.accessToken != state.accessToken || persisted.expiresAt > state.expiresAt {
          // RFC 6749 permits a refresh response to omit refresh_token. A newer
          // access token or expiry therefore proves another resolver completed a
          // usable refresh even when the durable refresh token is unchanged.
          return persisted
        }
        let rotated = try await exchange.refresh(state, client: client, now: clock.now)
        // The new record is committed before the old one is discarded. A
        // successful host migration removes its predecessor only after that
        // commit; if cleanup fails, `loadState` still chooses the newest state.
        let destination = CredentialRecordKey(clientID: client.clientID, host: rotated.host)
        do {
          try await store.replace(rotated, for: destination)
        } catch {
          throw RefreshPersistenceFailure(state: rotated)
        }
        if destination != key {
          _ = try? await store.delete(key)
        }
        return rotated
      }
      cachedState = rotated
      return rotated
    } catch let failure as RefreshPersistenceFailure {
      let destination = CredentialRecordKey(clientID: client.clientID, host: failure.state.host)
      await refreshCoordinator.rememberUndurable(failure.state, for: [key, destination])
      cachedState = failure.state
      throw GatewayError(
        code: .authenticationFailed,
        message: "The refreshed OAuth credential could not be saved safely.",
        outcomeUnknown: true,
        recoveryGuidance: "Run `auth oauth2` again before retrying authentication."
      )
    }
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
  ///
  /// A thrown error and a `nil` mode mean different things and must not be
  /// collapsed into one another. `nil` means the process holds no credential:
  /// no access token, no client configuration, or a store that answered and had
  /// no record. A throw means the answer is unknown, because the credential
  /// store could not be read or the permanent-token configuration is invalid.
  /// Reporting the second case as the first tells an operator to re-authorize a
  /// vault that already holds a valid refresh token, so both failures propagate.
  public func status() async throws -> AuthStatusReport {
    let hasClient = OAuthClientConfiguration.resolve(from: environment) != nil
    if environment.nonEmptyValue(for: .accessToken) != nil {
      // A rejected or missing base URL is a real misconfiguration; permanent
      // token mode has no host default to fall back on, so it is reported
      // rather than flattened into `host: null`.
      let host = try permanentTokenCredential()?.baseURL.host
      return AuthStatusReport(
        mode: .permanentToken,
        host: host,
        scopes: [],
        expiresAt: nil,
        isExpired: false,
        hasRefreshState: false,
        hasClientConfiguration: hasClient
      )
    }
    let state = try await loadState()
    return AuthStatusReport(
      mode: state == nil ? nil : .oauth2,
      host: state?.host,
      scopes: state?.grantedScopes ?? [],
      expiresAt: state?.expiresAt,
      isExpired: state.map { $0.expiresAt <= clock.now } ?? false,
      hasRefreshState: state != nil,
      hasClientConfiguration: hasClient
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
    let keys = WrikeHostPolicy.approvedAPIHosts.map {
      CredentialRecordKey(clientID: client.clientID, host: $0)
    }
    await refreshCoordinator.forgetStates(for: keys)
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
