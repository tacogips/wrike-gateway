import Foundation
import GatewaySDKKit
import Testing
@testable import WrikeGatewayCore
import WrikeGatewayRead
import WrikeGatewayTestSupport

@Suite("ReaderSDKTests")
struct ReaderSDKTests {
  @Test("Public reader constructor is available from the reader product")
  func publicConstructor() throws {
    let sdk = try WrikeGatewaySDK.reader()
    #expect(sdk.tier == CapabilityTier.reader.rawValue)
    #expect(sdk.catalog.validate().isEmpty)
  }

  @Test("Reader catalog and runtime expose identical schema names")
  func schemaParity() throws {
    let runtime = try makeRuntime(transport: RecordingTransport())
    let sdk = try makeSDK(runtime: runtime)
    #expect(SchemaNameSets.parse(runtime.printedSchema()) == SchemaNameSets.parse(sdk.schemaSDL()))
    #expect(sdk.catalog.validate().isEmpty)
  }

  @Test("Named reader invocation uses the linked runtime while tier denials diverge")
  func invocationAndTierEnforcement() async throws {
    let transport = RecordingTransport.succeeding(
      json: WrikeFixtures.envelope(kind: "tasks", data: WrikeFixtures.task)
    )
    let runtime = try makeRuntime(transport: transport)
    let sdk = try makeSDK(runtime: runtime)
    let invoked = await sdk.invoke(
      GatewayOperationRequest(operation: "task", variables: ["id": .string("IEAAAAAAKQAB5FNY")]),
      environment: [:]
    )
    #expect(invoked.exitCode == 0)
    #expect(try await transport.firstRequest().path == "/api/v4/tasks/IEAAAAAAKQAB5FNY")

    let denied = await sdk.execute(
      document: "mutation { createTask(input: {folderId: \"IEAAAAAAI4AB5FNY\", title: \"x\"}) { task { id } } }",
      variables: [:],
      environment: [:]
    )
    #expect(denied.errors.first?.code == GatewayErrorCode.capabilityDenied.rawValue)
    let requestCount = await transport.requestCount
    let unknown = await sdk.invoke(
      GatewayOperationRequest(operation: "createTask"),
      environment: [:]
    )
    #expect(unknown.exitCode == 2)
    #expect(await transport.requestCount == requestCount)
  }

  @Test("Facade uses caller-scoped environment and preserves raw CLI envelopes")
  func environmentAndRawOutputParity() async throws {
    let transport = RecordingTransport.succeeding(
      json: WrikeFixtures.envelope(kind: "tasks", data: WrikeFixtures.task)
    )
    let runtime = try makeRuntime(transport: transport)
    let captured = EnvironmentCapture()
    let sdk = try WrikeGatewaySDK(
      role: .reader,
      definitions: ReadCapabilities.all,
      makeRuntime: { environment in
        captured.record(environment.value(for: .accessToken))
        return runtime
      }
    )
    let document = "query T($id: ID!) { task(id: $id) { id title } }"
    let variables: [String: GatewayJSONValue] = ["id": .string("IEAAAAAAKQAB5FNY")]
    let facade = await sdk.execute(
      document: document,
      variables: variables,
      environment: [GatewayEnvironmentKey.accessToken.rawValue: "caller-token"]
    )
    #expect(captured.value == "caller-token")

    let environment = StaticEnvironmentReader()
    let frame = CommandFrame(
      role: .reader,
      runtime: runtime,
      authCommands: AuthCommands(
        resolver: CredentialResolver(environment: environment, store: InMemoryCredentialStore()),
        environment: environment,
        makeLoginFlow: { _, _ in nil }
      )
    )
    let command = await frame.run(arguments: [
      "graphql", "query", document, "--variables", "{\"id\":\"IEAAAAAAKQAB5FNY\"}"
    ])
    #expect(facade.exitCode == command.exitCode.rawValue)
    #expect(facade.rawOutput + "\n" == command.standardOutput)
  }

  @Test("Facade composition selects the isolated credential-store boundary")
  func facadeCompositionUsesIsolatedCredentialStore() throws {
    let captured = CredentialStoreContextCapture()
    _ = try GatewayComposition.makeFacadeRuntime(
      role: .reader,
      definitions: ReadCapabilities.all,
      environment: StaticEnvironmentReader(),
      makeCredentialStore: { context in
        captured.record(context)
        return InMemoryCredentialStore()
      }
    )
    #expect(captured.value == .facade)
  }

  @Test("Facade returns a deterministic envelope when runtime composition fails")
  func runtimeFactoryFailureEnvelope() async throws {
    let failure = GatewayError.validation("Test runtime composition failed.")
    let sdk = try WrikeGatewaySDK(
      role: .reader,
      definitions: ReadCapabilities.all,
      makeRuntime: { _ in throw failure }
    )

    let response = await sdk.execute(document: "{ task { id } }", variables: [:], environment: [:])

    #expect(response.data == nil)
    #expect(response.exitCode == GatewayExitCode.usage.rawValue)
    #expect(response.errors == [
      GatewayEnvelopeError(message: "Test runtime composition failed.", code: GatewayErrorCode.validationError.rawValue)
    ])
    #expect(response.requestId == nil)
    #expect(response.rawOutput.isEmpty)
  }

  @Test("SDK schema search rejects expensive regexes before catalog evaluation")
  func schemaSearchRejectsExpensivePatterns() throws {
    let sdk = try WrikeGatewaySDK.reader()
    let started = Date()

    #expect(throws: GatewayError.self) {
      _ = try sdk.searchSchema("(.+)+Z", options: .init(limit: 1))
    }

    #expect(Date().timeIntervalSince(started) < 1)

    let overlappingStarted = Date()
    #expect(throws: GatewayError.self) {
      _ = try sdk.searchSchema(".*.*.*.*.*.*.*.*Z", options: .init(limit: 1))
    }
    #expect(Date().timeIntervalSince(overlappingStarted) < 1)

    #expect(throws: GatewayError.self) {
      _ = try sdk.searchSchema(String(repeating: "a", count: 257), options: .init(limit: 1))
    }
  }

  @Test("Facade executions that construct separate runtimes share OAuth refresh")
  func facadeRuntimeRefreshCoordination() async throws {
    let clock = TestClock()
    let state = OAuthTokenState(
      accessToken: SecretValue("fake-old-access"),
      refreshToken: SecretValue("fake-old-refresh"),
      expiresAt: clock.now.addingTimeInterval(-60),
      grantedScopes: ["wsReadOnly"],
      host: "www.wrike.com",
      clientID: SecretValue("fake-client-id")
    )
    let key = CredentialRecordKey(clientID: state.clientID, host: state.host)
    let store = InMemoryCredentialStore(seed: [key: state])
    let refreshTransport = RecordingTransport.succeeding(json: """
      {"access_token":"fake-new-access","refresh_token":"fake-new-refresh",\
      "expires_in":3600,"host":"www.wrike.com","scope":"wsReadOnly"}
      """)
    let apiTransport = RecordingTransport.succeeding(
      json: WrikeFixtures.envelope(kind: "tasks", data: WrikeFixtures.task)
    )
    let refreshCoordinator = OAuthRefreshCoordinator()
    let sdk = try WrikeGatewaySDK(
      role: .reader,
      definitions: ReadCapabilities.all,
      makeRuntime: { _ in
        try Self.oauthRuntime(
          apiTransport: apiTransport,
          refreshTransport: refreshTransport,
          store: store,
          clock: clock,
          refreshCoordinator: refreshCoordinator
        )
      }
    )
    let document = "query T($id: ID!) { task(id: $id) { id } }"
    let variables: [String: GatewayJSONValue] = ["id": .string("IEAAAAAAKQAB5FNY")]

    async let first = sdk.execute(document: document, variables: variables, environment: [:])
    async let second = sdk.execute(document: document, variables: variables, environment: [:])
    let responses = await (first, second)

    #expect(responses.0.exitCode == 0)
    #expect(responses.1.exitCode == 0)
    #expect(await refreshTransport.requestCount == 1)
    #expect(await apiTransport.requestCount == 2)
  }

  private func makeSDK(runtime: GraphQLRuntime) throws -> WrikeGatewaySDK {
    try WrikeGatewaySDK(role: .reader, definitions: ReadCapabilities.all, makeRuntime: { _ in runtime })
  }

  private func makeRuntime(transport: RecordingTransport) throws -> GraphQLRuntime {
    GraphQLRuntime(
      executor: CapabilityExecutor(
        planner: CapabilityPlanner(registry: try ReadCapabilities.registry()),
        transport: transport,
        credentials: StubCredentialProvider(),
        clock: TestClock()
      ),
      requestIDFactory: { "reader-sdk-request" }
    )
  }

  private static func oauthRuntime(
    apiTransport: RecordingTransport,
    refreshTransport: RecordingTransport,
    store: InMemoryCredentialStore,
    clock: TestClock,
    refreshCoordinator: OAuthRefreshCoordinator
  ) throws -> GraphQLRuntime {
    let resolver = CredentialResolver(
      environment: StaticEnvironmentReader([
        .clientID: "fake-client-id",
        .clientSecret: "fake-client-secret"
      ]),
      store: store,
      clock: clock,
      exchange: try OAuthTokenExchange(
        transport: refreshTransport,
        tokenURL: URL(string: WrikeOAuthEndpoints.tokenURL)
      ),
      refreshCoordinator: refreshCoordinator
    )
    return GraphQLRuntime(
      executor: CapabilityExecutor(
        planner: CapabilityPlanner(registry: try ReadCapabilities.registry()),
        transport: apiTransport,
        credentials: resolver,
        clock: clock
      ),
      requestIDFactory: { "reader-oauth-sdk-request" }
    )
  }
}

private final class EnvironmentCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: String?

  var value: String? {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }

  func record(_ value: String?) {
    lock.lock()
    stored = value
    lock.unlock()
  }
}

private final class CredentialStoreContextCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: KinkoCredentialStoreExecutionContext?

  var value: KinkoCredentialStoreExecutionContext? {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }

  func record(_ value: KinkoCredentialStoreExecutionContext) {
    lock.lock()
    stored = value
    lock.unlock()
  }
}
