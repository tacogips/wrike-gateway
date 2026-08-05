import Foundation
import Testing
import WrikeGatewayCore
import WrikeGatewayTestSupport

@Suite("Authentication precedence and base URL validation")
struct AuthenticationPrecedenceTests {
  private func resolver(
    _ environment: StaticEnvironmentReader,
    store: any CredentialStore = InMemoryCredentialStore(),
    clock: TestClock = TestClock()
  ) -> CredentialResolver {
    CredentialResolver(environment: environment, store: store, clock: clock)
  }

  @Test("A permanent token wins over OAuth client configuration")
  func permanentTokenWins() async throws {
    let environment = StaticEnvironmentReader([
      .accessToken: "fake-permanent-token",
      .apiBaseURL: "https://app-eu.wrike.com/api/v4",
      .clientID: "fake-client-id",
      .clientSecret: "fake-client-secret"
    ])
    let credential = try await resolver(environment).credential()
    #expect(credential.mode == .permanentToken)
    #expect(credential.baseURL.host == "app-eu.wrike.com")
    // A permanent token exposes no scope metadata, so no local scope pre-check
    // is performed and Wrike stays authoritative.
    #expect(credential.grantedScopes.isEmpty)
  }

  @Test("Permanent-token mode fails locally without a base URL")
  func requiresBaseURL() async throws {
    let environment = StaticEnvironmentReader([.accessToken: "fake-permanent-token"])
    do {
      _ = try await resolver(environment).credential()
      Issue.record("Expected a local authentication failure")
    } catch let error as GatewayError {
      #expect(error.code == .authenticationFailed)
      #expect(error.message.contains("WRIKE_GATEWAY_API_BASE_URL"))
      #expect(error.exitCode == .credential)
    }
  }

  @Test("An exported-but-empty token does not select permanent-token mode")
  func emptyValuesAreAbsent() async throws {
    let environment = StaticEnvironmentReader([
      .accessToken: "   ",
      .apiBaseURL: "https://www.wrike.com/api/v4"
    ])
    do {
      _ = try await resolver(environment).credential()
      Issue.record("Expected no usable credential")
    } catch let error as GatewayError {
      #expect(error.code == .authenticationFailed)
      #expect(error.message.contains("No Wrike credential is available"))
    }
  }

  static let rejectedBaseURLs = [
    "http://www.wrike.com/api/v4",
    "https://evil.example.com/api/v4",
    "https://www.wrike.com",
    "https://www.wrike.com/api/v3",
    "https://user:pass@www.wrike.com/api/v4",
    "https://www.wrike.com/api/v4?token=x",
    "https://www.wrike.com/api/v4#fragment",
    "https://www.wrike.com/api/v4/extra"
  ]

  @Test("An invalid base URL is rejected before any request", arguments: rejectedBaseURLs)
  func rejectsInvalidBaseURL(raw: String) async throws {
    let environment = StaticEnvironmentReader([.accessToken: "fake-token", .apiBaseURL: raw])
    await #expect(throws: GatewayError.self) {
      _ = try await self.resolver(environment).credential()
    }
  }

  static let acceptedBaseURLs = [
    "https://www.wrike.com/api/v4",
    "https://app-eu.wrike.com/api/v4",
    "https://app-us2.wrike.com/api/v4",
    "https://www.wrike.com/api/v4/"
  ]

  @Test("Every approved data-center host is accepted", arguments: acceptedBaseURLs)
  func acceptsApprovedHosts(raw: String) throws {
    let url = try WrikeHostPolicy.production.validateBaseURL(raw, source: "test")
    #expect(url.path == "/api/v4")
  }

  @Test("OAuth state is used when no permanent token is present")
  func usesOAuthState() async throws {
    let environment = StaticEnvironmentReader([
      .clientID: "fake-client-id",
      .clientSecret: "fake-client-secret"
    ])
    let clock = TestClock()
    let state = OAuthTokenState(
      accessToken: SecretValue("fake-oauth-access"),
      refreshToken: SecretValue("fake-oauth-refresh"),
      expiresAt: clock.now.addingTimeInterval(3600),
      grantedScopes: ["wsReadOnly"],
      host: "www.wrike.com",
      clientID: SecretValue("fake-client-id")
    )
    let key = CredentialRecordKey(clientID: SecretValue("fake-client-id"), host: "www.wrike.com")
    let store = InMemoryCredentialStore(seed: [key: state])

    let credential = try await resolver(environment, store: store, clock: clock).credential()
    #expect(credential.mode == .oauth2)
    #expect(credential.grantedScopes == ["wsReadOnly"])
    #expect(credential.baseURL.absoluteString == "https://www.wrike.com/api/v4")
  }

  @Test("Clock skew triggers refresh before actual expiry")
  func clockSkewDecision() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let state = OAuthTokenState(
      accessToken: SecretValue("fake"),
      refreshToken: SecretValue("fake"),
      expiresAt: now.addingTimeInterval(60),
      grantedScopes: [],
      host: "www.wrike.com",
      clientID: SecretValue("fake")
    )
    #expect(state.needsRefresh(now: now))
    #expect(!state.needsRefresh(now: now.addingTimeInterval(-600)))
  }

  @Test("Logout removes only the local record and reports the outcome")
  func logoutRemovesLocalRecord() async throws {
    let environment = StaticEnvironmentReader([
      .clientID: "fake-client-id",
      .clientSecret: "fake-client-secret"
    ])
    let key = CredentialRecordKey(clientID: SecretValue("fake-client-id"), host: "www.wrike.com")
    let state = OAuthTokenState(
      accessToken: SecretValue("fake"),
      refreshToken: SecretValue("fake"),
      expiresAt: Date(timeIntervalSince1970: 1_900_000_000),
      grantedScopes: [],
      host: "www.wrike.com",
      clientID: SecretValue("fake-client-id")
    )
    let store = InMemoryCredentialStore(seed: [key: state])
    let subject = resolver(environment, store: store)

    #expect(try await subject.logout())
    #expect(try await store.load(key) == nil)
    #expect(try await subject.logout() == false)
  }

  @Test("Record keys separate accounts and applications")
  func recordKeysAreScoped() {
    let first = CredentialRecordKey(clientID: SecretValue("client-a"), host: "www.wrike.com")
    let second = CredentialRecordKey(clientID: SecretValue("client-b"), host: "www.wrike.com")
    let third = CredentialRecordKey(clientID: SecretValue("client-a"), host: "app-eu.wrike.com")
    #expect(first.storageName != second.storageName)
    #expect(first.storageName != third.storageName)
    // kinko accepts only environment-key names, so the namespace separator is
    // an underscore rather than a dot.
    #expect(first.storageName.hasPrefix("WRIKE_GATEWAY_OAUTH_"))
    // The client id itself is not embedded in the record name.
    #expect(!first.storageName.uppercased().contains("CLIENT_A"))
  }

  @Test("Exactly four environment variables are part of the contract")
  func canonicalEnvironmentVariables() {
    #expect(Set(GatewayEnvironmentKey.allCases.map(\.rawValue)) == [
      "WRIKE_GATEWAY_API_CLIENT_ID",
      "WRIKE_GATEWAY_API_CLIENT_SECRET",
      "WRIKE_GATEWAY_ACCESS_TOKEN",
      "WRIKE_GATEWAY_API_BASE_URL"
    ])
  }
}

@Suite("Scope checks")
struct ScopeCheckTests {
  @Test("A known missing scope fails locally before dispatch")
  func rejectsMissingScope() async throws {
    let transport = RecordingTransport.succeeding(json: "{}")
    let registry = try CapabilityRegistry(
      tier: .reader,
      definitions: [TransportTestCapabilities.get]
    )
    let executor = CapabilityExecutor(
      planner: CapabilityPlanner(registry: registry),
      transport: transport,
      credentials: StubCredentialProvider(grantedScopes: ["amReadOnlyUser"])
    )

    do {
      _ = try await executor.execute(TransportTestCapabilities.invocation())
      Issue.record("Expected a scope rejection")
    } catch let error as GatewayError {
      #expect(error.code == .authorizationFailed)
      #expect(error.recoveryGuidance?.contains("wsReadOnly") == true)
    }
    #expect(await transport.requestCount == 0)
  }

  @Test("A granted accepted scope permits dispatch")
  func acceptsGrantedScope() async throws {
    let transport = RecordingTransport.succeeding(
      json: WrikeFixtures.envelope(kind: "widgets", data: "{\"id\":\"W1\"}")
    )
    let registry = try CapabilityRegistry(
      tier: .reader,
      definitions: [TransportTestCapabilities.get]
    )
    let executor = CapabilityExecutor(
      planner: CapabilityPlanner(registry: registry),
      transport: transport,
      credentials: StubCredentialProvider(grantedScopes: ["wsReadOnly"])
    )
    _ = try await executor.execute(TransportTestCapabilities.invocation("W1"))
    #expect(await transport.requestCount == 1)
  }
}

@Suite("Credential store")
struct CredentialStoreTests {
  @Test("The kinko store writes the record over stdin and never echoes it")
  func writesThroughKinko() async throws {
    let runner = StubProcessRunner(results: [
      ProcessResult(exitCode: 0, standardOutput: Data(), standardError: Data())
    ])
    let store = KinkoCredentialStore(runner: runner, executablePath: "/usr/bin/true")
    let state = OAuthTokenState(
      accessToken: SecretValue("fake-access"),
      refreshToken: SecretValue("fake-refresh"),
      expiresAt: Date(timeIntervalSince1970: 1_900_000_000),
      grantedScopes: ["wsReadOnly"],
      host: "www.wrike.com",
      clientID: SecretValue("fake-client")
    )
    let key = CredentialRecordKey(clientID: state.clientID, host: state.host)
    try await store.replace(state, for: key)

    let invocations = await runner.invocations
    #expect(invocations.count == 1)
    #expect(invocations[0].arguments.first == "set-key")
    #expect(invocations[0].hadStandardInput)
    // The record is never passed as an argument, where it would be visible in
    // the process listing.
    #expect(!invocations[0].arguments.contains { $0.contains("fake-access") })
  }

  @Test("A rejected write surfaces as a local resource failure")
  func rejectedWrite() async throws {
    let runner = StubProcessRunner(results: [
      ProcessResult(exitCode: 3, standardOutput: Data(), standardError: Data("vault locked".utf8))
    ])
    let store = KinkoCredentialStore(runner: runner, executablePath: "/usr/bin/true")
    let state = OAuthTokenState(
      accessToken: SecretValue("fake"),
      refreshToken: SecretValue("fake"),
      expiresAt: Date(timeIntervalSince1970: 1_900_000_000),
      grantedScopes: [],
      host: "www.wrike.com",
      clientID: SecretValue("fake")
    )

    do {
      try await store.replace(
        state,
        for: CredentialRecordKey(clientID: state.clientID, host: state.host)
      )
      Issue.record("Expected the write to fail")
    } catch let error as GatewayError {
      #expect(error.code == .fileOperationFailed)
      #expect(error.exitCode == .localResource)
      // kinko's stderr is not echoed, because it may quote record content.
      #expect(!error.message.contains("vault locked"))
    }
  }

  @Test("An atomic store failure prevents the record from being committed")
  func atomicFailure() async throws {
    let store = InMemoryCredentialStore()
    await store.failNextWrite()
    let state = OAuthTokenState(
      accessToken: SecretValue("fake"),
      refreshToken: SecretValue("fake"),
      expiresAt: Date(timeIntervalSince1970: 1_900_000_000),
      grantedScopes: [],
      host: "www.wrike.com",
      clientID: SecretValue("fake")
    )
    let key = CredentialRecordKey(clientID: state.clientID, host: state.host)

    await #expect(throws: GatewayError.self) {
      try await store.replace(state, for: key)
    }
    #expect(try await store.load(key) == nil)
  }
}
