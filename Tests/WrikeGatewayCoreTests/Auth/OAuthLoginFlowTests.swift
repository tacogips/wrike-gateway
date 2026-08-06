import Foundation
import Testing
import WrikeGatewayCore
import WrikeGatewayTestSupport

/// Builds a login flow from injected seams so every callback path is exercised
/// without live credentials and without opening a browser.
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
    port: Int = WrikeOAuthEndpoints.defaultCallbackPort,
    path: String = WrikeOAuthEndpoints.callbackPath
  ) -> OAuthCallbackRequest {
    var items = [WrikeQueryItem(name: "state", value: state)]
    if let code { items.append(WrikeQueryItem(name: "code", value: code)) }
    if let error { items.append(WrikeQueryItem(name: "error", value: error)) }
    return OAuthCallbackRequest(host: host, port: port, path: path, queryItems: items)
  }

  func flow(
    listener: StubCallbackListener.Behavior,
    browserFails: Bool = false,
    capture: SecretCapture = SecretCapture(),
    callbackPort: Int = WrikeOAuthEndpoints.defaultCallbackPort,
    boundPorts: PortRecorder = PortRecorder()
  ) throws -> OAuthLoginFlow {
    OAuthLoginFlow(
      client: Self.client,
      listener: StubCallbackListener(listener, started: listenerStarts, boundPorts: boundPorts),
      browser: StubBrowserOpener(opened: browserOpens, shouldFail: browserFails, capture: capture),
      exchange: try OAuthTokenExchange(
        transport: transport,
        tokenURL: URL(string: WrikeOAuthEndpoints.tokenURL),
        hostPolicy: .production
      ),
      stateGenerator: FixedStateGenerator(),
      clock: clock,
      requestedScopes: ["wsReadOnly"],
      callbackPort: callbackPort
    )
  }
}

@Suite("OAuth loopback callback validation")
struct OAuthLoopbackCallbackTests {
  @Test("A valid callback exchanges the code and returns rotated token state")
  func completesFlow() async throws {
    let harness = FlowHarness()
    let flow = try harness.flow(listener: .callback(FlowHarness.callback()))

    let (state, trace) = try await flow.authorize()
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

  @Test("The listener binds before the browser opens")
  func listenerPrecedesBrowser() async throws {
    // A redirect can only be received by a port already being served, so the
    // browser must never open ahead of the listener.
    let harness = FlowHarness()
    let flow = try harness.flow(listener: .callback(FlowHarness.callback()), browserFails: true)

    await #expect(throws: GatewayError.self) {
      _ = try await flow.authorize()
    }
    #expect(harness.listenerStarts.count == 1)
  }

  @Test("A mismatched callback state is rejected")
  func rejectsStateMismatch() async throws {
    let harness = FlowHarness()
    let flow = try harness.flow(
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
    ("empty state", FlowHarness.callback(state: "")),
    ("oauth error", FlowHarness.callback(error: "access_denied"))
  ]

  @Test("Invalid callbacks are rejected before any code exchange", arguments: rejectedCallbacks)
  func rejectsInvalidCallbacks(name: String, request: OAuthCallbackRequest) async throws {
    let harness = FlowHarness()
    let flow = try harness.flow(listener: .callback(request))

    await #expect(throws: GatewayError.self) {
      _ = try await flow.authorize()
    }
    #expect(await harness.transport.requestCount == 0, "\(name) must not reach the token endpoint")
  }

  @Test("Callback rejection messages disclose no state, code, or client id")
  func rejectionMessagesAreSafe() async throws {
    for (name, request) in Self.rejectedCallbacks {
      let harness = FlowHarness()
      let flow = try harness.flow(listener: .callback(request))
      do {
        _ = try await flow.authorize()
        Issue.record("Expected \(name) to be rejected")
      } catch let error as GatewayError {
        let combined = error.message + (error.recoveryGuidance ?? "") + error.description
        #expect(!combined.contains("fake-oauth-state-value"), "\(name)")
        #expect(!combined.contains("fake-authorization-code"), "\(name)")
        #expect(!combined.contains("fake-client-id"), "\(name)")
        #expect(!combined.contains(WrikeOAuthEndpoints.authorizationURL), "\(name)")
      }
    }
  }

  @Test("An elapsed callback timeout fails without exchanging a code")
  func timeoutFails() async throws {
    let harness = FlowHarness()
    let flow = try harness.flow(listener: .timeout)

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
      listener: .callback(FlowHarness.callback()),
      capture: capture
    )
    _ = try await flow.authorize()

    let url = try #require(capture.revealed())
    #expect(url.hasPrefix(WrikeOAuthEndpoints.authorizationURL))

    // The redirect the browser is sent to is exactly the loopback URI, checked
    // by decoding the query rather than by substring, so a different scheme or
    // host cannot satisfy this assertion.
    let items = try #require(URLComponents(string: url)?.queryItems)
    let redirect = try #require(items.first { $0.name == "redirect_uri" }?.value)
    #expect(redirect == "http://localhost:8765/callback")
    #expect(items.first { $0.name == "response_type" }?.value == "code")

    // As a `SecretValue`, the URL renders as the redaction placeholder.
    let secret = SecretValue(url)
    #expect("\(secret)" == SecretValue.placeholder)
  }

  @Test("The redirect URI scheme, host, and path are fixed, and only the port is configurable")
  func redirectURIShape() throws {
    let defaultURI = WrikeOAuthEndpoints.redirectURI(
      port: WrikeOAuthEndpoints.defaultCallbackPort
    )
    #expect(defaultURI == "http://localhost:8765/callback")

    let components = try #require(WrikeOAuthEndpoints.components(ofRedirectURI: defaultURI))
    #expect(components.host == "localhost")
    #expect(components.port == 8765)
    #expect(components.path == "/callback")

    // A configured port changes only the port. The host stays loopback, so no
    // configuration can send an authorization code off this machine.
    let configured = try #require(
      WrikeOAuthEndpoints.components(ofRedirectURI: WrikeOAuthEndpoints.redirectURI(port: 49152))
    )
    #expect(configured.host == "localhost")
    #expect(configured.port == 49152)
    #expect(configured.path == "/callback")

    // The port is the only callback-shaped variable in the contract.
    let names = Set(GatewayEnvironmentKey.allCases.map(\.rawValue))
    #expect(!names.contains { $0.contains("REDIRECT") })
    #expect(
      names.filter { $0.contains("CALLBACK") } == [
        GatewayEnvironmentKey.oauthCallbackPort.rawValue
      ]
    )

    // Every override-shaped flag is rejected by the shared parser.
    for flag in CommandParser.forbiddenFlags {
      #expect(throws: GatewayError.self) {
        _ = try CommandParser.parse(["graphql", "schema", flag, "value"])
      }
    }
  }

  @Test("The redirect validator accepts only the loopback http URI")
  func redirectValidatorRejectsOtherSchemes() {
    // An https redirect is no longer part of the contract: nothing in this
    // product can serve it, so it must not parse as a valid redirect.
    #expect(WrikeOAuthEndpoints.components(ofRedirectURI: "https://localhost:8765/callback") == nil)
    #expect(WrikeOAuthEndpoints.components(ofRedirectURI: "wrike://callback") == nil)
    #expect(WrikeOAuthEndpoints.components(ofRedirectURI: "not a url at all") == nil)

    // A non-loopback http URI parses, but its host is not the fixed callback
    // host, which is what the callback validator rejects.
    let foreign = WrikeOAuthEndpoints.components(ofRedirectURI: "http://attacker.example/callback")
    #expect(foreign?.host == "attacker.example")
    #expect(foreign?.host != WrikeOAuthEndpoints.callbackHost)
  }

  @Test("The configured port reaches the callback service and the token exchange")
  func configuredPortReachesTheFlow() async throws {
    let harness = FlowHarness()
    let boundPorts = PortRecorder()
    let flow = try harness.flow(
      listener: .callback(FlowHarness.callback(port: 49152)),
      callbackPort: 49152,
      boundPorts: boundPorts
    )

    _ = try await flow.authorize()

    #expect(boundPorts.ports == [49152], "The service must bind the configured port")
    let exchange = try #require(await harness.transport.requests.last)
    #expect(
      exchange.bodyDescription.contains("49152"),
      "The token exchange must reuse the redirect URI the authorization used"
    )
    #expect(!exchange.bodyDescription.contains("8765"))
  }

  @Test("A callback arriving on a port other than the configured one is refused")
  func callbackOnAnotherPortIsRefused() async throws {
    let harness = FlowHarness()
    // The service is configured for 49152; the callback claims the old default.
    let flow = try harness.flow(
      listener: .callback(FlowHarness.callback(port: 8765)),
      callbackPort: 49152
    )

    await #expect(throws: GatewayError.self) {
      _ = try await flow.authorize()
    }
  }

  @Test("A token response naming an unapproved host is rejected")
  func rejectsUnapprovedTokenHost() async throws {
    let harness = FlowHarness(tokenResponse: """
      {"access_token":"fake","refresh_token":"fake","expires_in":3600,"host":"attacker.example"}
      """)
    let flow = try harness.flow(listener: .callback(FlowHarness.callback()))

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

  @Test("The state generator is unguessable and every near-miss state is refused")
  func stateGenerationAndComparison() throws {
    // A repeated or short state would make the comparison meaningless.
    let generated = Set((0..<64).map { _ in RandomStateGenerator().makeState().reveal() })
    #expect(generated.count == 64, "Every generated state must be distinct")
    for value in generated {
      #expect(value.count >= 32)
    }

    // The comparison is exercised through the public validator: a state that
    // differs only in its last byte, only in its first byte, or only in length
    // is refused just as a wholly different one is.
    let expected = "fake-oauth-state-value"
    func request(state: String) -> OAuthCallbackRequest {
      FlowHarness.callback(state: state)
    }
    #expect(throws: Never.self) {
      _ = try OAuthCallbackValidator.validate(
        request(state: expected),
        expectedState: SecretValue(expected)
      )
    }
    for near in ["fake-oauth-state-valuf", "gake-oauth-state-value", "fake-oauth-state-valu"] {
      #expect(throws: GatewayError.self) {
        _ = try OAuthCallbackValidator.validate(
          request(state: near),
          expectedState: SecretValue(expected)
        )
      }
    }
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
