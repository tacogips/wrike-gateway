import GatewaySDKKit
import Testing
@testable import WrikeGatewayCore
import WrikeGatewayRead
import WrikeGatewayTestSupport
import WrikeGatewayWrite

@Suite("WriterSDKTests")
struct WriterSDKTests {
  @Test("Public writer constructor is available from the writer product")
  func publicConstructor() throws {
    let sdk = try WrikeGatewaySDK.writer()
    #expect(sdk.tier == CapabilityTier.writer.rawValue)
    #expect(sdk.catalog.validate().isEmpty)
  }

  @Test("Writer catalog matches runtime and invokes query and mutation documents")
  func parityAndInvocations() async throws {
    let transport = RecordingTransport.succeeding(
      json: WrikeFixtures.envelope(kind: "tasks", data: WrikeFixtures.task)
    )
    let runtime = GraphQLRuntime(
      executor: CapabilityExecutor(
        planner: CapabilityPlanner(registry: try WriteCapabilities.registry()),
        transport: transport,
        credentials: StubCredentialProvider(),
        clock: TestClock()
      ),
      requestIDFactory: { "writer-sdk-request" }
    )
    let sdk = try WrikeGatewaySDK(role: .writer, definitions: WriteCapabilities.all, makeRuntime: { _ in runtime })
    #expect(SchemaNameSets.parse(runtime.printedSchema()) == SchemaNameSets.parse(sdk.schemaSDL()))
    #expect(sdk.catalog.validate().isEmpty)

    let query = GatewayOperationRequest(operation: "task", variables: ["id": .string("IEAAAAAAKQAB5FNY")])
    #expect(try GatewayDocumentBuilder(catalog: sdk.catalog).build(query).document.contains("$id: ID!"))
    #expect((await sdk.invoke(query, environment: [:])).exitCode == 0)

    let mutation = GatewayOperationRequest(operation: "createTask", variables: [
      "input": .object(["folderId": .string("IEAAAAAAI4AB5FNY"), "title": .string("Launch")])
    ])
    #expect(try GatewayDocumentBuilder(catalog: sdk.catalog).build(mutation).document.contains("$input: CreateTaskInput!"))
    #expect((await sdk.invoke(mutation, environment: [:])).exitCode == 0)

    let requests = await transport.requests
    #expect(requests.count == 2)
    #expect(requests[0].method == .get)
    #expect(requests[0].path == "/api/v4/tasks/IEAAAAAAKQAB5FNY")
    #expect(requests[0].query.isEmpty)
    #expect(requests[1].method == .post)
    #expect(requests[1].path == "/api/v4/folders/IEAAAAAAI4AB5FNY/tasks")
    #expect(requests[1].bodyDescription.contains("title=Launch"))
  }

  @Test("Writer facade marks an unconfirmed mutation transport failure as outcome unknown")
  func mutationTransportFailurePreservesRecoveryMetadata() async throws {
    let transport = RecordingTransport(outcomes: [.failure(.connectivity("test connection lost"))])
    let runtime = GraphQLRuntime(
      executor: CapabilityExecutor(
        planner: CapabilityPlanner(registry: try WriteCapabilities.registry()),
        transport: transport,
        credentials: StubCredentialProvider(),
        clock: TestClock()
      ),
      requestIDFactory: { "writer-sdk-request" }
    )
    let sdk = try WrikeGatewaySDK(role: .writer, definitions: WriteCapabilities.all, makeRuntime: { _ in runtime })

    let response = await sdk.invoke(
      GatewayOperationRequest(operation: "createTask", variables: [
        "input": .object(["folderId": .string("IEAAAAAAI4AB5FNY"), "title": .string("Launch")])
      ]),
      environment: [:]
    )

    let error = try #require(response.errors.first)
    #expect(error.code == "TRANSPORT_FAILED_OUTCOME_UNKNOWN")
    #expect(error.message.contains("Confirm the current state in Wrike before retrying."))
    #expect(response.rawOutput.contains("\"outcomeUnknown\":true"))
    #expect(response.rawOutput.contains("\"capabilityId\":\"tasks.create\""))
    #expect(response.requestId == "writer-sdk-request")
    #expect(await transport.requestCount == 1)
  }
}
