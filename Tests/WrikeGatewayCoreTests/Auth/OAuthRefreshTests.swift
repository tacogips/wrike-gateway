import Foundation
import Testing
@testable import WrikeGatewayCore
import WrikeGatewayTestSupport

@Suite("OAuth refresh")
struct OAuthRefreshTests {
  private actor FailedRefreshPublicationGate {
    private var arrived = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func pauseAfterPublication() async {
      arrived = true
      let waiters = arrivalWaiters
      arrivalWaiters.removeAll()
      for waiter in waiters {
        waiter.resume()
      }
      await withCheckedContinuation { continuation in
        releaseContinuation = continuation
      }
    }

    func waitUntilPaused() async {
      guard !arrived else { return }
      await withCheckedContinuation { continuation in
        arrivalWaiters.append(continuation)
      }
    }

    func release() {
      releaseContinuation?.resume()
      releaseContinuation = nil
    }
  }

  private func makeResolver(
    transport: RecordingTransport,
    store: InMemoryCredentialStore,
    clock: TestClock,
    refreshCoordinator: OAuthRefreshCoordinator = OAuthRefreshCoordinator()
  ) throws -> CredentialResolver {
    CredentialResolver(
      environment: StaticEnvironmentReader([
        .clientID: "fake-client-id",
        .clientSecret: "fake-client-secret"
      ]),
      store: store,
      clock: clock,
      exchange: try OAuthTokenExchange(
        transport: transport,
        tokenURL: URL(string: WrikeOAuthEndpoints.tokenURL)
      ),
      refreshCoordinator: refreshCoordinator
    )
  }

  private func expiredState(clock: TestClock) -> (OAuthTokenState, CredentialRecordKey) {
    let state = OAuthTokenState(
      accessToken: SecretValue("fake-old-access"),
      refreshToken: SecretValue("fake-old-refresh"),
      expiresAt: clock.now.addingTimeInterval(-60),
      grantedScopes: ["wsReadOnly"],
      host: "www.wrike.com",
      clientID: SecretValue("fake-client-id")
    )
    return (state, CredentialRecordKey(clientID: state.clientID, host: state.host))
  }

  @Test("An expired token refreshes once and commits the rotated record atomically")
  func refreshesAndCommits() async throws {
    let clock = TestClock()
    let (state, key) = expiredState(clock: clock)
    let store = InMemoryCredentialStore(seed: [key: state])
    let transport = RecordingTransport.succeeding(json: """
      {"access_token":"fake-new-access","refresh_token":"fake-new-refresh",\
      "expires_in":3600,"host":"www.wrike.com","scope":"wsReadOnly"}
      """)
    let resolver = try makeResolver(transport: transport, store: store, clock: clock)

    let credential = try await resolver.credential()
    #expect(credential.mode == .oauth2)
    #expect(await transport.requestCount == 1)

    let stored = try #require(try await store.load(key))
    #expect(stored.refreshToken == SecretValue("fake-new-refresh"))
    #expect(stored.expiresAt == clock.now.addingTimeInterval(3600))
  }

  @Test("Concurrent requests share one refresh rather than reusing the rotated token")
  func singleFlightRefresh() async throws {
    let clock = TestClock()
    let (state, key) = expiredState(clock: clock)
    let store = InMemoryCredentialStore(seed: [key: state])
    let transport = RecordingTransport.succeeding(json: """
      {"access_token":"fake-new-access","refresh_token":"fake-new-refresh",\
      "expires_in":3600,"host":"www.wrike.com"}
      """)
    let resolver = try makeResolver(transport: transport, store: store, clock: clock)

    async let first = resolver.credential()
    async let second = resolver.credential()
    async let third = resolver.credential()
    _ = try await (first, second, third)

    #expect(await transport.requestCount == 1, "The old refresh token must be submitted once")
  }

  @Test("A stale resolver reuses a committed refresh that keeps the refresh token")
  func staggeredResolversReuseUnrotatedRefresh() async throws {
    let clock = TestClock()
    let (state, key) = expiredState(clock: clock)
    let store = InMemoryCredentialStore(seed: [key: state])
    let transport = RecordingTransport.succeeding(json: """
      {"access_token":"fake-new-access","expires_in":3600,"host":"www.wrike.com"}
      """)
    let coordinator = OAuthRefreshCoordinator()
    let leader = try makeResolver(
      transport: transport,
      store: store,
      clock: clock,
      refreshCoordinator: coordinator
    )
    let follower = try makeResolver(
      transport: transport,
      store: store,
      clock: clock,
      refreshCoordinator: coordinator
    )

    // Cache the old state in a separate facade-created resolver before the
    // leader commits an RFC 6749-valid response without refresh_token.
    _ = try await follower.status()
    _ = try await leader.credential()
    let reused = try await follower.credential()

    #expect(reused.token == SecretValue("fake-new-access"))
    #expect(await transport.requestCount == 1)
  }

  @Test("A rotated refresh-store failure is outcome-unknown and never reuses the invalidated predecessor")
  func failedPersistence() async throws {
    let clock = TestClock()
    let (state, key) = expiredState(clock: clock)
    let store = InMemoryCredentialStore(seed: [key: state])
    await store.failNextWrite()
    let transport = RecordingTransport.succeeding(json: """
      {"access_token":"fake-new-access","refresh_token":"fake-new-refresh",\
      "expires_in":3600,"host":"www.wrike.com"}
      """)
    let coordinator = OAuthRefreshCoordinator()
    let resolver = try makeResolver(
      transport: transport,
      store: store,
      clock: clock,
      refreshCoordinator: coordinator
    )

    do {
      _ = try await resolver.credential()
      Issue.record("Expected the durability barrier to surface")
    } catch let error as GatewayError {
      #expect(error.code == .authenticationFailed)
      #expect(error.outcomeUnknown)
      #expect(error.recoveryGuidance?.contains("auth oauth2") == true)
    }
    // The old record is still the committed one.
    let stored = try #require(try await store.load(key))
    #expect(stored.refreshToken == SecretValue("fake-old-refresh"))

    // A fresh facade-created resolver shares the in-process recovery barrier
    // and therefore never resubmits the server-invalidated old refresh token.
    let freshResolver = try makeResolver(
      transport: transport,
      store: store,
      clock: clock,
      refreshCoordinator: coordinator
    )
    let recovered = try await freshResolver.credential()
    #expect(recovered.token == SecretValue("fake-new-access"))
    #expect(await transport.requestCount == 1)
  }

  @Test("A failed-persistence handoff publishes its barrier before a fresh resolver can refresh")
  func failedPersistencePublicationPreventsConcurrentSecondExchange() async throws {
    let clock = TestClock()
    let (state, key) = expiredState(clock: clock)
    let store = InMemoryCredentialStore(seed: [key: state])
    await store.failNextWrite()
    let transport = RecordingTransport.succeeding(json: """
      {"access_token":"fake-new-access","refresh_token":"fake-new-refresh",\
      "expires_in":3600,"host":"www.wrike.com"}
      """)
    let handoff = FailedRefreshPublicationGate()
    let coordinator = OAuthRefreshCoordinator(
      failedPersistencePublicationObserver: {
        await handoff.pauseAfterPublication()
      }
    )
    let failingResolver = try makeResolver(
      transport: transport,
      store: store,
      clock: clock,
      refreshCoordinator: coordinator
    )

    let failingRequest = Task {
      try await failingResolver.credential()
    }
    await handoff.waitUntilPaused()

    // The coordinator is paused after it records the rotated state but before
    // it clears its in-flight task. A newly constructed resolver must reuse
    // that state rather than submit the invalidated durable predecessor.
    let freshResolver = try makeResolver(
      transport: transport,
      store: store,
      clock: clock,
      refreshCoordinator: coordinator
    )
    let recovered = try await freshResolver.credential()
    #expect(recovered.token == SecretValue("fake-new-access"))
    #expect(await transport.requestCount == 1)

    await handoff.release()
    await #expect(throws: GatewayError.self) {
      _ = try await failingRequest.value
    }
  }

  @Test("A recovered durable refresh retires an older undurable rotation")
  func recoveredPersistenceDoesNotShadowLaterDurableState() async throws {
    let clock = TestClock()
    let (state, key) = expiredState(clock: clock)
    let store = InMemoryCredentialStore(seed: [key: state])
    await store.failNextWrite()
    let transport = RecordingTransport(
      outcomes: [
        .response(WrikeResponse(statusCode: 200, body: Data("""
          {"access_token":"fake-undurable-access","refresh_token":"fake-undurable-refresh",\
          "expires_in":60,"host":"www.wrike.com"}
          """.utf8))),
        .response(WrikeResponse(statusCode: 200, body: Data("""
          {"access_token":"fake-recovered-access","refresh_token":"fake-recovered-refresh",\
          "expires_in":3600,"host":"www.wrike.com"}
          """.utf8))),
        .response(WrikeResponse(statusCode: 200, body: Data("""
          {"access_token":"fake-latest-access","refresh_token":"fake-latest-refresh",\
          "expires_in":3600,"host":"www.wrike.com"}
          """.utf8)))
      ],
      repeatsFinalOutcome: false
    )
    let coordinator = OAuthRefreshCoordinator()
    let failingResolver = try makeResolver(
      transport: transport,
      store: store,
      clock: clock,
      refreshCoordinator: coordinator
    )

    await #expect(throws: GatewayError.self) {
      _ = try await failingResolver.credential()
    }

    let recoveryResolver = try makeResolver(
      transport: transport,
      store: store,
      clock: clock,
      refreshCoordinator: coordinator
    )
    let recovered = try await recoveryResolver.credential()
    #expect(recovered.token == SecretValue("fake-recovered-access"))

    clock.advance(by: 3_600)
    let freshResolver = try makeResolver(
      transport: transport,
      store: store,
      clock: clock,
      refreshCoordinator: coordinator
    )
    let latest = try await freshResolver.credential()
    #expect(latest.token == SecretValue("fake-latest-access"))
    #expect(await transport.requestCount == 3)
  }

  @Test("A recovered host migration retires every undurable source alias")
  func recoveredMigratedStateDoesNotShadowDurableDestination() async throws {
    let clock = TestClock()
    let (state, key) = expiredState(clock: clock)
    let store = InMemoryCredentialStore(seed: [key: state])
    await store.failNextWrite()
    let transport = RecordingTransport(
      outcomes: [
        .response(WrikeResponse(statusCode: 200, body: Data("""
          {"access_token":"fake-undurable-access","refresh_token":"fake-undurable-refresh",\
          "expires_in":7200,"host":"app-eu.wrike.com"}
          """.utf8))),
        .response(WrikeResponse(statusCode: 200, body: Data("""
          {"access_token":"fake-recovered-access","refresh_token":"fake-recovered-refresh",\
          "expires_in":3600,"host":"app-eu.wrike.com"}
          """.utf8)))
      ],
      repeatsFinalOutcome: false
    )
    let coordinator = OAuthRefreshCoordinator()
    let failingResolver = try makeResolver(
      transport: transport,
      store: store,
      clock: clock,
      refreshCoordinator: coordinator
    )

    await #expect(throws: GatewayError.self) {
      _ = try await failingResolver.credential()
    }

    let recoveryResolver = try makeResolver(
      transport: transport,
      store: store,
      clock: clock,
      refreshCoordinator: coordinator
    )
    let stale = ResolvedCredential(
      mode: .oauth2,
      token: SecretValue("fake-undurable-access"),
      baseURL: try #require(URL(string: "https://app-eu.wrike.com/api/v4")),
      grantedScopes: ["wsReadOnly"],
      expiresAt: clock.now.addingTimeInterval(7_200)
    )
    let recovered = try #require(try await recoveryResolver.refreshedCredential(after: stale))
    #expect(recovered.token == SecretValue("fake-recovered-access"))

    // The old www alias has a later expiry than the recovered EU record. A
    // new resolver must nevertheless select the durable replacement rather
    // than the process-local state whose refresh token was invalidated.
    let freshResolver = try makeResolver(
      transport: transport,
      store: store,
      clock: clock,
      refreshCoordinator: coordinator
    )
    let fresh = try await freshResolver.credential()
    #expect(fresh.token == SecretValue("fake-recovered-access"))
    #expect(fresh.baseURL.host == "app-eu.wrike.com")
    #expect(await transport.requestCount == 2)
  }

  @Test("External reauthorization retires every cross-host undurable alias")
  func externalReauthorizationDoesNotLeaveMigrationBarrier() async throws {
    let clock = TestClock()
    let (state, key) = expiredState(clock: clock)
    let store = InMemoryCredentialStore(seed: [key: state])
    await store.failNextWrite()
    let transport = RecordingTransport.succeeding(json: """
      {"access_token":"fake-undurable-access","refresh_token":"fake-undurable-refresh",\
      "expires_in":7200,"host":"app-eu.wrike.com"}
      """)
    let coordinator = OAuthRefreshCoordinator()
    let failingResolver = try makeResolver(
      transport: transport,
      store: store,
      clock: clock,
      refreshCoordinator: coordinator
    )

    await #expect(throws: GatewayError.self) {
      _ = try await failingResolver.credential()
    }

    // A separate process completes a new authorization at www. Its shorter
    // lifetime must still replace the longer-lived undurable EU migration
    // barrier in a newly constructed resolver.
    let reauthorized = OAuthTokenState(
      accessToken: SecretValue("fake-reauthorized-access"),
      refreshToken: SecretValue("fake-reauthorized-refresh"),
      expiresAt: clock.now.addingTimeInterval(3600),
      grantedScopes: ["wsReadOnly"],
      host: "www.wrike.com",
      clientID: SecretValue("fake-client-id")
    )
    try await store.replace(reauthorized, for: key)

    let freshResolver = try makeResolver(
      transport: transport,
      store: store,
      clock: clock,
      refreshCoordinator: coordinator
    )
    let fresh = try await freshResolver.credential()
    #expect(fresh.token == SecretValue("fake-reauthorized-access"))
    #expect(fresh.baseURL.host == "www.wrike.com")
    #expect(await transport.requestCount == 1)
  }

  @Test("Destination reauthorization retires a partial migration barrier")
  func destinationReauthorizationRetiresPartialMigrationBarrier() async throws {
    let clock = TestClock()
    let (state, key) = expiredState(clock: clock)
    let store = InMemoryCredentialStore(seed: [key: state])
    // The EU destination is written, then www cleanup and its mirror fail.
    await store.failNextDelete()
    await store.failWrite(after: 1)
    let transport = RecordingTransport.succeeding(json: """
      {"access_token":"fake-rotated-access","refresh_token":"fake-rotated-refresh",\
      "expires_in":7200,"host":"app-eu.wrike.com"}
      """)
    let coordinator = OAuthRefreshCoordinator()
    let failingResolver = try makeResolver(
      transport: transport,
      store: store,
      clock: clock,
      refreshCoordinator: coordinator
    )

    await #expect(throws: GatewayError.self) {
      _ = try await failingResolver.credential()
    }

    let destination = CredentialRecordKey(
      clientID: SecretValue("fake-client-id"),
      host: "app-eu.wrike.com"
    )
    let reauthorized = OAuthTokenState(
      accessToken: SecretValue("fake-reauthorized-access"),
      refreshToken: SecretValue("fake-reauthorized-refresh"),
      expiresAt: clock.now.addingTimeInterval(3600),
      grantedScopes: ["wsReadOnly"],
      host: "app-eu.wrike.com",
      clientID: SecretValue("fake-client-id")
    )
    try await store.replace(reauthorized, for: destination)

    let freshResolver = try makeResolver(
      transport: transport,
      store: store,
      clock: clock,
      refreshCoordinator: coordinator
    )
    let fresh = try await freshResolver.credential()
    #expect(fresh.token == SecretValue("fake-reauthorized-access"))
    #expect(fresh.baseURL.host == "app-eu.wrike.com")
    #expect(await transport.requestCount == 1)
  }

  @Test("An undurable reuse by a stale resolver preserves its recovery barrier")
  func staleResolverCannotRetireUndurableBarrierWithoutPersistence() async throws {
    let clock = TestClock()
    let (state, key) = expiredState(clock: clock)
    let store = InMemoryCredentialStore(seed: [key: state])
    await store.failNextWrite()
    let transport = RecordingTransport.succeeding(json: """
      {"access_token":"fake-undurable-access","refresh_token":"fake-undurable-refresh",\
      "expires_in":3600,"host":"www.wrike.com"}
      """)
    let coordinator = OAuthRefreshCoordinator()
    let staleResolver = try makeResolver(
      transport: transport,
      store: store,
      clock: clock,
      refreshCoordinator: coordinator
    )
    // Cache the durable predecessor before another resolver rotates it.
    _ = try await staleResolver.status()

    let failingResolver = try makeResolver(
      transport: transport,
      store: store,
      clock: clock,
      refreshCoordinator: coordinator
    )
    await #expect(throws: GatewayError.self) {
      _ = try await failingResolver.credential()
    }

    // This resolver reuses the in-process state. It must not clear the barrier
    // because no credential-store write happened on this path.
    let reused = try await staleResolver.credential()
    #expect(reused.token == SecretValue("fake-undurable-access"))

    let freshResolver = try makeResolver(
      transport: transport,
      store: store,
      clock: clock,
      refreshCoordinator: coordinator
    )
    let fresh = try await freshResolver.credential()
    #expect(fresh.token == SecretValue("fake-undurable-access"))
    #expect(await transport.requestCount == 1)
  }

  @Test("A rejected refresh returns AUTHENTICATION_FAILED without a retry loop")
  func rejectedRefresh() async throws {
    let clock = TestClock()
    let (state, key) = expiredState(clock: clock)
    let store = InMemoryCredentialStore(seed: [key: state])
    let transport = RecordingTransport(outcomes: [
      .response(WrikeResponse(statusCode: 400, body: Data("{\"error\":\"invalid_grant\"}".utf8)))
    ])
    let resolver = try makeResolver(transport: transport, store: store, clock: clock)

    do {
      _ = try await resolver.credential()
      Issue.record("Expected the refresh to fail")
    } catch let error as GatewayError {
      #expect(error.code == .authenticationFailed)
    }
    #expect(await transport.requestCount == 1, "Refresh must not retry automatically")
  }

  /// A refresh response that omits a field RFC 6749 lets the server omit must
  /// leave the stored value in place rather than clear it. Only a live refresh
  /// would show which fields Wrike actually repeats, so each optional field is
  /// covered here through the injected transport.
  @Test("A refresh response keeps the stored scopes, refresh token, and host when it omits them")
  func refreshPreservesOmittedFields() async throws {
    let clock = TestClock()
    let (state, key) = expiredState(clock: clock)
    let store = InMemoryCredentialStore(seed: [key: state])
    // Only the access token and its lifetime are reported, which is the
    // minimum RFC 6749 section 5.1 requires of a refresh response.
    let transport = RecordingTransport.succeeding(json: """
      {"access_token":"fake-new-access","expires_in":3600}
      """)
    let resolver = try makeResolver(transport: transport, store: store, clock: clock)

    let credential = try await resolver.credential()
    #expect(credential.grantedScopes == ["wsReadOnly"], "An omitted scope must not empty the grant")
    #expect(credential.baseURL.absoluteString == "https://www.wrike.com/api/v4")

    let stored = try #require(try await store.load(key))
    #expect(stored.accessToken == SecretValue("fake-new-access"))
    #expect(
      stored.refreshToken == SecretValue("fake-old-refresh"),
      "An unrotated refresh token stays usable rather than forcing a new authorization"
    )
    #expect(stored.grantedScopes == ["wsReadOnly"])
    #expect(stored.host == "www.wrike.com")
  }

  @Test("A refresh response that reports its own values still replaces them")
  func refreshAppliesReportedFields() async throws {
    let clock = TestClock()
    let (state, key) = expiredState(clock: clock)
    let store = InMemoryCredentialStore(seed: [key: state])
    let transport = RecordingTransport.succeeding(json: """
      {"access_token":"fake-new-access","refresh_token":"fake-new-refresh",\
      "expires_in":3600,"host":"app-eu.wrike.com","scope":"wsReadOnly,wsReadWrite"}
      """)
    let resolver = try makeResolver(transport: transport, store: store, clock: clock)

    _ = try await resolver.credential()
    let rotatedKey = CredentialRecordKey(clientID: state.clientID, host: "app-eu.wrike.com")
    let stored = try #require(try await store.load(rotatedKey))
    #expect(stored.refreshToken == SecretValue("fake-new-refresh"))
    #expect(stored.grantedScopes == ["wsReadOnly", "wsReadWrite"])
    #expect(stored.host == "app-eu.wrike.com")
  }

  @Test("A fresh resolver selects the migrated host record rather than a stale predecessor")
  func migratedHostIsReusedByFreshResolver() async throws {
    let clock = TestClock()
    let (state, key) = expiredState(clock: clock)
    let store = InMemoryCredentialStore(seed: [key: state])
    let transport = RecordingTransport.succeeding(json: """
      {"access_token":"fake-new-access","refresh_token":"fake-new-refresh",\
      "expires_in":3600,"host":"app-eu.wrike.com"}
      """)
    let coordinator = OAuthRefreshCoordinator()
    let leader = try makeResolver(
      transport: transport,
      store: store,
      clock: clock,
      refreshCoordinator: coordinator
    )
    _ = try await leader.credential()

    let migratedKey = CredentialRecordKey(clientID: state.clientID, host: "app-eu.wrike.com")
    #expect(try await store.load(key) == nil)
    #expect(try await store.load(migratedKey)?.refreshToken == SecretValue("fake-new-refresh"))

    let follower = try makeResolver(
      transport: transport,
      store: store,
      clock: clock,
      refreshCoordinator: coordinator
    )
    let reused = try await follower.credential()
    #expect(reused.baseURL.host == "app-eu.wrike.com")
    #expect(reused.token == SecretValue("fake-new-access"))
    #expect(await transport.requestCount == 1)
  }

  @Test("A failed host-predecessor delete mirrors the rotated state for fresh resolvers")
  func failedMigratedHostCleanupKeepsEveryRecordSafe() async throws {
    let clock = TestClock()
    let (state, key) = expiredState(clock: clock)
    let store = InMemoryCredentialStore(seed: [key: state])
    await store.failNextDelete()
    let transport = RecordingTransport.succeeding(json: """
      {"access_token":"fake-new-access","refresh_token":"fake-new-refresh",\
      "expires_in":3600,"host":"app-eu.wrike.com"}
      """)
    let coordinator = OAuthRefreshCoordinator()
    let leader = try makeResolver(
      transport: transport,
      store: store,
      clock: clock,
      refreshCoordinator: coordinator
    )
    _ = try await leader.credential()

    let migratedKey = CredentialRecordKey(clientID: state.clientID, host: "app-eu.wrike.com")
    #expect(try await store.load(key)?.refreshToken == SecretValue("fake-new-refresh"))
    #expect(try await store.load(migratedKey)?.refreshToken == SecretValue("fake-new-refresh"))

    let follower = try makeResolver(
      transport: transport,
      store: store,
      clock: clock,
      refreshCoordinator: coordinator
    )
    let report = try await follower.status()
    #expect(report.host == "app-eu.wrike.com")
    #expect(await transport.requestCount == 1)
  }

  @Test("An empty scope string is treated as omitted rather than as a grant of nothing")
  func refreshIgnoresEmptyScope() async throws {
    let clock = TestClock()
    let (state, key) = expiredState(clock: clock)
    let store = InMemoryCredentialStore(seed: [key: state])
    let transport = RecordingTransport.succeeding(json: """
      {"access_token":"fake-new-access","expires_in":3600,"scope":""}
      """)
    let resolver = try makeResolver(transport: transport, store: store, clock: clock)

    _ = try await resolver.credential()
    let stored = try #require(try await store.load(key))
    #expect(stored.grantedScopes == ["wsReadOnly"])
  }

  /// The authorization-code exchange has no prior record to fall back on, so
  /// the required fields stay required there.
  @Test("An authorization-code exchange still requires a refresh token and a host")
  func codeExchangeStillRequiresIssuedFields() async throws {
    let bodies = [
      "{\"access_token\":\"fake\",\"expires_in\":3600,\"host\":\"www.wrike.com\"}",
      "{\"access_token\":\"fake\",\"refresh_token\":\"fake\",\"expires_in\":3600}"
    ]
    for body in bodies {
      let exchange = try OAuthTokenExchange(
        transport: RecordingTransport.succeeding(json: body),
        tokenURL: URL(string: WrikeOAuthEndpoints.tokenURL)
      )
      await #expect(throws: GatewayError.self) {
        _ = try await exchange.exchangeAuthorizationCode(
          SecretValue("fake-code"),
          client: OAuthClientConfiguration(
            clientID: SecretValue("fake-client-id"),
            clientSecret: SecretValue("fake-client-secret")
          ),
          redirectURI: WrikeOAuthEndpoints.redirectURI(
            port: WrikeOAuthEndpoints.defaultCallbackPort
          ),
          now: Date(timeIntervalSince1970: 1_800_000_000)
        )
      }
    }
  }

  @Test("A 401 permits exactly one refresh attempt per request")
  func singleRefreshAfterUnauthorized() async throws {
    let apiTransport = RecordingTransport(outcomes: [
      .response(WrikeResponse(statusCode: 401, body: Data(WrikeFixtures.errorBody.utf8)))
    ])
    let registry = try CapabilityRegistry(
      tier: .reader,
      definitions: [TransportTestCapabilities.get]
    )
    let refreshed = ResolvedCredential(
      mode: .oauth2,
      token: SecretValue("fake-refreshed"),
      // The base URL is a fixed valid fixture.
      // swiftlint:disable:next force_unwrapping
      baseURL: URL(string: "https://www.wrike.com/api/v4")!,
      grantedScopes: [],
      expiresAt: nil
    )
    let executor = CapabilityExecutor(
      planner: CapabilityPlanner(registry: registry),
      transport: apiTransport,
      credentials: StubCredentialProvider(refreshed: refreshed),
      retryPolicy: .disabled
    )

    do {
      _ = try await executor.execute(TransportTestCapabilities.invocation())
      Issue.record("Expected the second 401 to surface")
    } catch let error as GatewayError {
      #expect(error.code == .authenticationFailed)
    }
    #expect(await apiTransport.requestCount == 2, "One original attempt plus one refreshed attempt")
  }
}
