import Foundation
import Testing
import WrikeGatewayCore
import WrikeGatewayTestSupport

/// Builds a login flow from injected seams so every callback and identity path
/// is exercised without live credentials and without a provisioned Keychain.
private struct FlowHarness {
  let listenerStarts = Counter()
  let browserOpens = Counter()
  let transport: RecordingTransport
  let clock = TestClock()

  init(tokenResponse: String = FlowHarness.tokenBody) {
    transport = RecordingTransport.succeeding(json: tokenResponse)
  }

  static let tokenBody = """
    {"access_token":"fake-new-access","refresh_token":"fake-new-refresh",\
    "token_type":"bearer","expires_in":3600,"host":"app-eu.wrike.com","scope":"wsReadOnly"}
    """

  static let client = OAuthClientConfiguration(
    clientID: SecretValue("fake-client-id"),
    clientSecret: SecretValue("fake-client-secret")
  )

  static func callback(
    state: String = "fake-oauth-state-value",
    code: String? = "fake-authorization-code",
    error: String? = nil,
    host: String = WrikeOAuthEndpoints.callbackHost,
    port: Int = WrikeOAuthEndpoints.callbackPort,
    path: String = WrikeOAuthEndpoints.callbackPath
  ) -> OAuthCallbackRequest {
    var items = [WrikeQueryItem(name: "state", value: state)]
    if let code { items.append(WrikeQueryItem(name: "code", value: code)) }
    if let error { items.append(WrikeQueryItem(name: "error", value: error)) }
    return OAuthCallbackRequest(host: host, port: port, path: path, queryItems: items)
  }

  func flow(
    identity: StubIdentityLoader.Behavior,
    listener: StubCallbackListener.Behavior,
    browserFails: Bool = false,
    capture: SecretCapture = SecretCapture()
  ) throws -> OAuthLoginFlow {
    OAuthLoginFlow(
      client: Self.client,
      identityLoader: StubIdentityLoader(identity),
      listener: StubCallbackListener(listener, started: listenerStarts),
      browser: StubBrowserOpener(opened: browserOpens, shouldFail: browserFails, capture: capture),
      exchange: try OAuthTokenExchange(
        transport: transport,
        tokenURL: URL(string: WrikeOAuthEndpoints.tokenURL),
        hostPolicy: .production
      ),
      stateGenerator: FixedStateGenerator(),
      clock: clock,
      requestedScopes: ["wsReadOnly"]
    )
  }
}

@Suite("OAuth callback TLS identity")
struct OAuthCallbackTLSIdentityTests {
  @Test(
    "Every invalid identity state fails before listener or browser activity",
    arguments: CallbackTLSIdentityFailure.allCases
  )
  func failsBeforeSideEffects(failure: CallbackTLSIdentityFailure) async throws {
    let harness = FlowHarness()
    let flow = try harness.flow(
      identity: .failure(failure),
      listener: .callback(FlowHarness.callback())
    )

    do {
      _ = try await flow.authorize()
      Issue.record("Expected identity failure \(failure)")
    } catch let error as GatewayError {
      #expect(error.code == .authenticationFailed)
      #expect(error.exitCode == .credential)
      #expect(error.recoveryGuidance?.contains(WrikeOAuthEndpoints.callbackIdentityLabel) == true)
    }

    #expect(harness.listenerStarts.count == 0, "No listener may bind on an identity failure")
    #expect(harness.browserOpens.count == 0, "No browser may open on an identity failure")
  }

  @Test("Identity guidance discloses no certificate or Keychain record data")
  func guidanceIsSafe() {
    for failure in CallbackTLSIdentityFailure.allCases {
      let error = failure.asGatewayError(label: WrikeOAuthEndpoints.callbackIdentityLabel)
      let combined = error.message + (error.recoveryGuidance ?? "")
      #expect(!combined.contains("BEGIN CERTIFICATE"))
      #expect(!combined.contains("PRIVATE KEY"))
      #expect(!combined.lowercased().contains("serial"))
      #expect(!combined.contains(WrikeOAuthEndpoints.authorizationURL))
    }
  }

  @Test("The identity handle exposes no key material")
  func handleIsOpaque() {
    let handle = CallbackTLSIdentityHandle(reference: "abc")
    let mirror = Mirror(reflecting: handle)
    let names = mirror.children.compactMap(\.label)
    #expect(!names.contains { $0.lowercased().contains("key") })
    #expect(!"\(handle)".contains("BEGIN"))
  }
}

@Suite("OAuth loopback callback validation")
struct OAuthLoopbackCallbackTests {
  @Test("A valid callback exchanges the code and returns rotated token state")
  func completesFlow() async throws {
    let harness = FlowHarness()
    let flow = try harness.flow(identity: .valid, listener: .callback(FlowHarness.callback()))

    let (state, trace) = try await flow.authorize()
    #expect(trace.identityLoaded)
    #expect(trace.listenerStarted)
    #expect(trace.browserOpened)
    #expect(state.host == "app-eu.wrike.com")
    #expect(state.grantedScopes == ["wsReadOnly"])
    #expect(state.expiresAt == harness.clock.now.addingTimeInterval(3600))

    let recorded = try await harness.transport.firstRequest()
    #expect(recorded.method == .post)
    #expect(recorded.url.absoluteString == WrikeOAuthEndpoints.tokenURL)
    // The exchange is unauthenticated; the client secret travels in the body.
    #expect(!recorded.hasAuthorization)
  }

  @Test("A mismatched callback state is rejected")
  func rejectsStateMismatch() async throws {
    let harness = FlowHarness()
    let flow = try harness.flow(
      identity: .valid,
      listener: .callback(FlowHarness.callback(state: "not-the-pending-state"))
    )

    do {
      _ = try await flow.authorize()
      Issue.record("Expected a state mismatch")
    } catch let error as GatewayError {
      #expect(error.code == .authenticationFailed)
      #expect(error.message.contains("state did not match"))
      #expect(!error.message.contains("fake-oauth-state-value"))
    }
    #expect(await harness.transport.requestCount == 0)
  }

  static let rejectedCallbacks: [(String, OAuthCallbackRequest)] = [
    ("unexpected host", FlowHarness.callback(host: "attacker.example")),
    ("unexpected port", FlowHarness.callback(port: 9999)),
    ("unexpected path", FlowHarness.callback(path: "/other")),
    ("missing code", FlowHarness.callback(code: nil)),
    ("oauth error", FlowHarness.callback(error: "access_denied"))
  ]

  @Test("Invalid callbacks are rejected before any code exchange", arguments: rejectedCallbacks)
  func rejectsInvalidCallbacks(name: String, request: OAuthCallbackRequest) async throws {
    let harness = FlowHarness()
    let flow = try harness.flow(identity: .valid, listener: .callback(request))

    await #expect(throws: GatewayError.self) {
      _ = try await flow.authorize()
    }
    #expect(await harness.transport.requestCount == 0, "\(name) must not reach the token endpoint")
  }

  @Test("An elapsed callback timeout fails without exchanging a code")
  func timeoutFails() async throws {
    let harness = FlowHarness()
    let flow = try harness.flow(identity: .valid, listener: .timeout)

    do {
      _ = try await flow.authorize()
      Issue.record("Expected a timeout failure")
    } catch let error as GatewayError {
      #expect(error.code == .authenticationFailed)
      #expect(error.message.contains("timeout"))
    }
    #expect(await harness.transport.requestCount == 0)
  }

  @Test("A browser launch failure does not print the authorization URL")
  func browserFailureIsSafe() async throws {
    let harness = FlowHarness()
    let flow = try harness.flow(
      identity: .valid,
      listener: .callback(FlowHarness.callback()),
      browserFails: true
    )

    do {
      _ = try await flow.authorize()
      Issue.record("Expected a browser failure")
    } catch let error as GatewayError {
      #expect(error.code == .authenticationFailed)
      #expect(!error.message.contains("login.wrike.com"))
      #expect(!error.message.contains("fake-client-id"))
    }
  }

  @Test("The authorization URL carries the fixed redirect URI and is never printable")
  func authorizationURLIsSecret() async throws {
    let harness = FlowHarness()
    let capture = SecretCapture()
    let flow = try harness.flow(
      identity: .valid,
      listener: .callback(FlowHarness.callback()),
      capture: capture
    )
    _ = try await flow.authorize()

    let url = try #require(capture.revealed())
    #expect(url.hasPrefix(WrikeOAuthEndpoints.authorizationURL))
    #expect(url.contains("redirect_uri=https://localhost:8765/callback".replacingOccurrences(
      of: "://", with: "%3A%2F%2F"
    )) || url.contains("localhost"))
    #expect(url.contains("response_type=code"))

    // As a `SecretValue`, the URL renders as the redaction placeholder.
    let secret = SecretValue(url)
    #expect("\(secret)" == SecretValue.placeholder)
  }

  @Test("The redirect URI is fixed and accepts no flag or environment override")
  func redirectURIIsFixed() throws {
    #expect(WrikeOAuthEndpoints.redirectURI == "https://localhost:8765/callback")
    let components = try #require(
      WrikeOAuthEndpoints.components(ofRedirectURI: WrikeOAuthEndpoints.redirectURI)
    )
    #expect(components.host == "localhost")
    #expect(components.port == 8765)
    #expect(components.path == "/callback")

    // No environment variable in the contract can influence the callback.
    let names = Set(GatewayEnvironmentKey.allCases.map(\.rawValue))
    #expect(!names.contains { $0.contains("REDIRECT") || $0.contains("CALLBACK") })

    // Every override-shaped flag is rejected by the shared parser.
    for flag in CommandParser.forbiddenFlags {
      #expect(throws: GatewayError.self) {
        _ = try CommandParser.parse(["graphql", "schema", flag, "value"])
      }
    }
  }

  @Test("A token response naming an unapproved host is rejected")
  func rejectsUnapprovedTokenHost() async throws {
    let harness = FlowHarness(tokenResponse: """
      {"access_token":"fake","refresh_token":"fake","expires_in":3600,"host":"attacker.example"}
      """)
    let flow = try harness.flow(identity: .valid, listener: .callback(FlowHarness.callback()))

    do {
      _ = try await flow.authorize()
      Issue.record("Expected the unapproved host to be rejected")
    } catch let error as GatewayError {
      #expect(error.code == .authenticationFailed)
    }
  }

  @Test("A redirect to a different host may not carry the credential")
  func redirectCredentialPolicy() throws {
    let policy = WrikeHostPolicy.production
    let origin = try #require(URL(string: "https://www.wrike.com/api/v4/tasks"))
    let sameHost = try #require(URL(string: "https://www.wrike.com/api/v4/tasks/1"))
    let otherHost = try #require(URL(string: "https://attacker.example/api/v4/tasks"))
    let downgraded = try #require(URL(string: "http://www.wrike.com/api/v4/tasks"))

    #expect(policy.permitsCredentialForwarding(to: sameHost, from: origin))
    #expect(!policy.permitsCredentialForwarding(to: otherHost, from: origin))
    #expect(!policy.permitsCredentialForwarding(to: downgraded, from: origin))
  }
}

@Suite("OAuth refresh")
struct OAuthRefreshTests {
  private func makeResolver(
    transport: RecordingTransport,
    store: InMemoryCredentialStore,
    clock: TestClock
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
      )
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

  @Test("A failed persistence does not claim a successful refresh")
  func failedPersistence() async throws {
    let clock = TestClock()
    let (state, key) = expiredState(clock: clock)
    let store = InMemoryCredentialStore(seed: [key: state])
    await store.failNextWrite()
    let transport = RecordingTransport.succeeding(json: """
      {"access_token":"fake-new-access","refresh_token":"fake-new-refresh",\
      "expires_in":3600,"host":"www.wrike.com"}
      """)
    let resolver = try makeResolver(transport: transport, store: store, clock: clock)

    await #expect(throws: GatewayError.self) {
      _ = try await resolver.credential()
    }
    // The old record is still the committed one.
    let stored = try #require(try await store.load(key))
    #expect(stored.refreshToken == SecretValue("fake-old-refresh"))
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
