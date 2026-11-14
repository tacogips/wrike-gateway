import Foundation
import GatewaySDKKit
import Testing
@testable import WrikeGatewayCore
import WrikeGatewayAdmin
import WrikeGatewayRead
import WrikeGatewayTestSupport
import WrikeGatewayWrite

@Suite("AdminSDKTests")
struct AdminSDKTests {
  @Test("Public admin constructor is available from the admin product")
  func publicConstructor() throws {
    let sdk = try WrikeGatewaySDK.admin()
    #expect(sdk.tier == CapabilityTier.admin.rawValue)
    #expect(sdk.catalog.validate().isEmpty)
  }

  @Test("Admin catalog matches runtime and invokes query and delete documents")
  func parityAndInvocations() async throws {
    let transport = RecordingTransport(outcomes: [
      .response(WrikeResponse(
        statusCode: 200,
        headers: [:],
        body: Data(WrikeFixtures.envelope(kind: "tasks", data: WrikeFixtures.task).utf8)
      )),
      .response(WrikeResponse(
        statusCode: 200,
        headers: [:],
        body: Data("{\"kind\":\"ids\",\"data\":[\"IEAAAAAAKQAB5FNY\"]}".utf8)
      ))
    ])
    let runtime = GraphQLRuntime(
      executor: CapabilityExecutor(
        planner: CapabilityPlanner(registry: try AdminCapabilities.registry()),
        transport: transport,
        credentials: StubCredentialProvider(),
        clock: TestClock()
      ),
      requestIDFactory: { "admin-sdk-request" }
    )
    let sdk = try WrikeGatewaySDK(role: .admin, definitions: AdminCapabilities.all, makeRuntime: { _ in runtime })
    #expect(SchemaNameSets.parse(runtime.printedSchema()) == SchemaNameSets.parse(sdk.schemaSDL()))
    #expect(sdk.catalog.validate().isEmpty)

    let query = GatewayOperationRequest(operation: "task", variables: ["id": .string("IEAAAAAAKQAB5FNY")])
    #expect(try GatewayDocumentBuilder(catalog: sdk.catalog).build(query).document.contains("$id: ID!"))
    #expect((await sdk.invoke(query, environment: [:])).exitCode == 0)

    let mutation = GatewayOperationRequest(operation: "deleteTask", variables: [
      "input": .object(["taskId": .string("IEAAAAAAKQAB5FNY")])
    ])
    #expect(try GatewayDocumentBuilder(catalog: sdk.catalog).build(mutation).document.contains("$input: DeleteTaskInput!"))
    #expect((await sdk.invoke(mutation, environment: [:])).exitCode == 0)

    let requests = await transport.requests
    #expect(requests.count == 2)
    #expect(requests[0].method == .get)
    #expect(requests[0].path == "/api/v4/tasks/IEAAAAAAKQAB5FNY")
    #expect(requests[0].query.isEmpty)
    #expect(requests[1].method == .delete)
    #expect(requests[1].path == "/api/v4/tasks/IEAAAAAAKQAB5FNY")
    #expect(requests[1].query.isEmpty)
  }

  @Test("Admin facade preserves the recovery warning for an unconfirmed delete")
  func deleteTransportFailurePreservesRecoveryMetadata() async throws {
    let transport = RecordingTransport(outcomes: [.failure(.connectivity("test connection lost"))])
    let runtime = GraphQLRuntime(
      executor: CapabilityExecutor(
        planner: CapabilityPlanner(registry: try AdminCapabilities.registry()),
        transport: transport,
        credentials: StubCredentialProvider(),
        clock: TestClock()
      ),
      requestIDFactory: { "admin-sdk-request" }
    )
    let sdk = try WrikeGatewaySDK(role: .admin, definitions: AdminCapabilities.all, makeRuntime: { _ in runtime })

    let response = await sdk.invoke(
      GatewayOperationRequest(operation: "deleteTask", variables: [
        "input": .object(["taskId": .string("IEAAAAAAKQAB5FNY")])
      ]),
      environment: [:]
    )

    let error = try #require(response.errors.first)
    #expect(error.code == "TRANSPORT_FAILED_OUTCOME_UNKNOWN")
    #expect(error.message.contains("Confirm the current state in Wrike before retrying."))
    #expect(response.rawOutput.contains("\"outcomeUnknown\":true"))
    #expect(response.rawOutput.contains("\"capabilityId\":\"tasks.delete\""))
    #expect(response.requestId == "admin-sdk-request")
    #expect(await transport.requestCount == 1)
  }

  @Test("Admin facade marks a cancelled delete as outcome unknown")
  func deleteCancellationPreservesRecoveryMetadata() async throws {
    let transport = RecordingTransport(outcomes: [.failure(.cancelled)])
    let runtime = GraphQLRuntime(
      executor: CapabilityExecutor(
        planner: CapabilityPlanner(registry: try AdminCapabilities.registry()),
        transport: transport,
        credentials: StubCredentialProvider(),
        clock: TestClock()
      ),
      requestIDFactory: { "admin-sdk-request" }
    )
    let sdk = try WrikeGatewaySDK(role: .admin, definitions: AdminCapabilities.all, makeRuntime: { _ in runtime })

    let response = await sdk.invoke(
      GatewayOperationRequest(operation: "deleteTask", variables: [
        "input": .object(["taskId": .string("IEAAAAAAKQAB5FNY")])
      ]),
      environment: [:]
    )

    let error = try #require(response.errors.first)
    #expect(error.code == "TRANSPORT_FAILED_OUTCOME_UNKNOWN")
    #expect(error.message.contains("Confirm the current state in Wrike before retrying."))
    #expect(response.rawOutput.contains("\"outcomeUnknown\":true"))
    #expect(await transport.requestCount == 1)
  }
}
