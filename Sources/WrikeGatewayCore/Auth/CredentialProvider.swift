import Foundation

/// Supplies the bearer credential for each request.
public protocol CredentialProvider: Sendable {
  func credential() async throws -> ResolvedCredential
  /// Refreshes after an upstream 401, returning `nil` when no refresh state
  /// exists. Only one refresh is attempted per request.
  func refreshedCredential(after stale: ResolvedCredential) async throws -> ResolvedCredential?
}

/// Distinguishes a record proven durable from an in-process rotation barrier.
/// Both states are usable for the current process, but only a durable state may
/// retire aliases that still protect a server-invalidated predecessor.
fileprivate enum OAuthStateResolution: Sendable {
  case durable(OAuthTokenState)
  case undurable(OAuthTokenState)

  var state: OAuthTokenState {
    switch self {
    case let .durable(state), let .undurable(state): state
    }
  }

  var isDurable: Bool {
    if case .durable = self { return true }
    return false
  }
}

/// Coordinates refresh-token rotation across independently constructed
/// resolvers that address the same durable credential record.
public actor OAuthRefreshCoordinator {
  private struct UndurableState: Sendable {
    let state: OAuthTokenState
    /// The durable state observed before persistence failed. A later different
    /// durable value proves an operator or another process safely replaced it.
    let predecessor: OAuthTokenState?
  }

  private var inFlight: [CredentialRecordKey: Task<OAuthStateResolution, any Error>] = [:]
  /// A refresh token can be rotated successfully before its durable store
  /// rejects the replacement. Retain that state for the current process so a
  /// fresh facade runtime never resubmits the invalidated predecessor.
  private var undurableStates: [CredentialRecordKey: UndurableState] = [:]

  public init() {}

  fileprivate func refresh(
    key: CredentialRecordKey,
    operation: @escaping @Sendable () async throws -> OAuthStateResolution
  ) async throws -> OAuthStateResolution {
    if let task = inFlight[key] {
      return try await task.value
    }
    let task = Task<OAuthStateResolution, any Error> { try await operation() }
    inFlight[key] = task
    defer { inFlight[key] = nil }
    return try await task.value
  }

  /// Reconciles a process-local rotation barrier against the durable record.
  /// The barrier wins only while the durable record is exactly the predecessor
  /// that upstream may already have invalidated. Any changed durable value is
  /// authoritative and retires the stale in-memory barrier.
  fileprivate func resolvedState(
    for key: CredentialRecordKey,
    durableState: OAuthTokenState?
  ) -> OAuthStateResolution? {
    guard let undurable = undurableStates[key] else {
      return durableState.map(OAuthStateResolution.durable)
    }
    guard durableState == undurable.predecessor else {
      undurableStates.removeValue(forKey: key)
      return durableState.map(OAuthStateResolution.durable)
    }
    return .undurable(undurable.state)
  }

  func rememberUndurable(
    _ state: OAuthTokenState,
    predecessors: [CredentialRecordKey: OAuthTokenState?]
  ) {
    for (key, predecessor) in predecessors {
      undurableStates[key] = UndurableState(state: state, predecessor: predecessor)
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
  let predecessors: [CredentialRecordKey: OAuthTokenState?]
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
      let durableState = try await store.load(key)
      if let resolution = await refreshCoordinator.resolvedState(for: key, durableState: durableState) {
        candidates.append(resolution.state)
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
    let refreshCoordinator = self.refreshCoordinator
    let key = CredentialRecordKey(clientID: client.clientID, host: state.host)
    do {
      let resolution = try await refreshCoordinator.refresh(key: key) {
        let persistedAtSource = try await store.load(key)
        let reconciledAtSource = await refreshCoordinator.resolvedState(
          for: key,
          durableState: persistedAtSource
        )
        if let reconciledAtSource {
          let persisted = reconciledAtSource.state
          if persisted.accessToken != state.accessToken
            || persisted.refreshToken != state.refreshToken
            || persisted.expiresAt > state.expiresAt {
            // RFC 6749 permits a refresh response to omit refresh_token. A newer
            // access token or expiry therefore proves another resolver completed a
            // usable refresh even when the durable refresh token is unchanged.
            return reconciledAtSource
          }
        }
        let rotated = try await exchange.refresh(state, client: client, now: clock.now)
        // The new record is committed before the old one is discarded. If
        // predecessor cleanup fails, replace the predecessor with the same
        // rotated state so every durable key is safe for a fresh resolver to
        // select. A failure to mirror that state becomes an explicit
        // durability barrier rather than silently retaining an invalidated
        // refresh token.
        let destination = CredentialRecordKey(clientID: client.clientID, host: rotated.host)
        let persistedAtDestination = destination == key
          ? persistedAtSource
          : try await store.load(destination)
        do {
          try await store.replace(rotated, for: destination)
        } catch {
          var predecessors: [CredentialRecordKey: OAuthTokenState?] = [key: persistedAtSource]
          predecessors[destination] = persistedAtDestination
          throw RefreshPersistenceFailure(
            state: rotated,
            predecessors: predecessors
          )
        }
        if destination != key {
          do {
            _ = try await store.delete(key)
          } catch {
            do {
              try await store.replace(rotated, for: key)
            } catch {
              throw RefreshPersistenceFailure(
                state: rotated,
                predecessors: [key: persistedAtSource]
              )
            }
          }
        }
        return .durable(rotated)
      }
      let rotated = resolution.state
      // A reused undurable state remains usable by this process, but its
      // predecessor may still be the only durable record. Retire aliases only
      // after a replacement was proven durable; otherwise a stale resolver
      // could erase the recovery barrier without persisting anything.
      if resolution.isDurable {
        await refreshCoordinator.forgetStates(for: recordKeys(for: client.clientID))
      }
      cachedState = rotated
      return rotated
    } catch let failure as RefreshPersistenceFailure {
      await refreshCoordinator.rememberUndurable(
        failure.state,
        predecessors: failure.predecessors
      )
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

  private func recordKeys(for clientID: SecretValue) -> [CredentialRecordKey] {
    WrikeHostPolicy.approvedAPIHosts.map {
      CredentialRecordKey(clientID: clientID, host: $0)
    }
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
    await refreshCoordinator.forgetStates(for: recordKeys(for: client.clientID))
    cachedState = nil
    return removed
  }

  /// Commits a newly authorized record.
  public func commit(_ state: OAuthTokenState) async throws {
    let key = CredentialRecordKey(clientID: state.clientID, host: state.host)
    try await store.replace(state, for: key)
    await refreshCoordinator.forgetStates(for: recordKeys(for: state.clientID))
    cachedState = state
  }
}
