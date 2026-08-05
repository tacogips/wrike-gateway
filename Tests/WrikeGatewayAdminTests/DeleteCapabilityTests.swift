import Foundation
import Testing
import WrikeGatewayAdmin
import WrikeGatewayCore
import WrikeGatewayRead
import WrikeGatewayTestSupport
import WrikeGatewayWrite

struct AdminCase: Sendable, CustomTestStringConvertible {
  let definition: CapabilityDefinition
  let argument: String
  let identifier: String
  let expectedPath: String

  var name: String { definition.id.rawValue }
  var testDescription: String { name }

  var document: String {
    "mutation { \(definition.field)(input: {\(argument): \"\(identifier)\"}) { deletedId } }"
  }

  var invocation: CapabilityInvocation {
    WrikeAdminClient.invocation(definition, argument, identifier)
  }
}

enum AdminCases {
  static let all: [AdminCase] = [
    AdminCase(
      definition: DeleteCapabilities.deleteGroup,
      argument: "groupId",
      identifier: "KX1",
      expectedPath: "/api/v4/groups/KX1"
    ),
    AdminCase(
      definition: DeleteCapabilities.deleteSpace,
      argument: "spaceId",
      identifier: "IEAG",
      expectedPath: "/api/v4/spaces/IEAG"
    ),
    AdminCase(
      definition: DeleteCapabilities.deleteFolder,
      argument: "folderId",
      identifier: "IEAAAAAAI4AB5FNY",
      expectedPath: "/api/v4/folders/IEAAAAAAI4AB5FNY"
    ),
    AdminCase(
      definition: DeleteCapabilities.deleteProject,
      argument: "projectId",
      identifier: "IEAAAAAAI4AB5FNZ",
      expectedPath: "/api/v4/folders/IEAAAAAAI4AB5FNZ"
    ),
    AdminCase(
      definition: DeleteCapabilities.deleteTask,
      argument: "taskId",
      identifier: "IEAAAAAAKQAB5FNY",
      expectedPath: "/api/v4/tasks/IEAAAAAAKQAB5FNY"
    ),
    AdminCase(
      definition: DeleteCapabilities.deleteComment,
      argument: "commentId",
      identifier: "IEAAAAAAIMAAAAAB",
      expectedPath: "/api/v4/comments/IEAAAAAAIMAAAAAB"
    ),
    AdminCase(
      definition: DeleteCapabilities.deleteAttachment,
      argument: "attachmentId",
      identifier: "IEAAAAAAIYAAAAAB",
      expectedPath: "/api/v4/attachments/IEAAAAAAIYAAAAAB"
    ),
    AdminCase(
      definition: DeleteCapabilities.deleteTimelog,
      argument: "timelogId",
      identifier: "IEAAAAAAJAAAAAAB",
      expectedPath: "/api/v4/timelogs/IEAAAAAAJAAAAAAB"
    ),
    AdminCase(
      definition: DeleteCapabilities.deleteWebhook,
      argument: "webhookId",
      identifier: "IEAAAAAAJEAAAAAB",
      expectedPath: "/api/v4/webhooks/IEAAAAAAJEAAAAAB"
    )
  ]

  static func planner() throws -> CapabilityPlanner {
    CapabilityPlanner(registry: try AdminCapabilities.registry())
  }

  static func runtime(transport: RecordingTransport) throws -> GraphQLRuntime {
    GraphQLRuntime(
      executor: CapabilityExecutor(
        planner: try planner(),
        transport: transport,
        credentials: StubCredentialProvider(),
        clock: TestClock()
      ),
      requestIDFactory: { "fixed-request-id" }
    )
  }

  /// Wrike delete responses return either identifier strings or entities.
  static func deletionEnvelope(kind: String, identifier: String) -> String {
    "{\"kind\":\"\(kind)\",\"data\":[\"\(identifier)\"]}"
  }
}

@Suite("Admin delete contract")
struct AdminDeleteContractTests {
  @Test("Every delete maps to DELETE on its exact upstream path", arguments: AdminCases.all)
  func mapsRoute(testCase: AdminCase) async throws {
    let transport = RecordingTransport.succeeding(
      json: AdminCases.deletionEnvelope(kind: "ids", identifier: testCase.identifier)
    )
    let response = await try AdminCases.runtime(transport: transport)
      .execute(document: testCase.document)

    #expect(response.errors.isEmpty, "\(testCase.name): \(response.errors)")
    let recorded = try await transport.firstRequest()
    #expect(recorded.method == .delete, "\(testCase.name)")
    #expect(recorded.path == testCase.expectedPath, "\(testCase.name)")
    #expect(recorded.query.isEmpty, "\(testCase.name) must send no query parameters")
    #expect(recorded.bodyDescription == "none", "\(testCase.name) must send no body")
  }

  @Test("Every delete returns the confirmed deleted id", arguments: AdminCases.all)
  func returnsConfirmedIdentifier(testCase: AdminCase) async throws {
    let transport = RecordingTransport.succeeding(
      json: AdminCases.deletionEnvelope(kind: "ids", identifier: testCase.identifier)
    )
    let response = await try AdminCases.runtime(transport: transport)
      .execute(document: testCase.document)

    #expect(
      response.data?[testCase.definition.field]?["deletedId"]?.stringValue == testCase.identifier,
      "\(testCase.name)"
    )
  }

  @Test("An entity-shaped delete response is also confirmed", arguments: AdminCases.all)
  func acceptsEntityShapedConfirmation(testCase: AdminCase) async throws {
    let transport = RecordingTransport.succeeding(
      json: "{\"kind\":\"entities\",\"data\":[{\"id\":\"\(testCase.identifier)\"}]}"
    )
    let response = await try AdminCases.runtime(transport: transport)
      .execute(document: testCase.document)

    #expect(
      response.data?[testCase.definition.field]?["deletedId"]?.stringValue == testCase.identifier,
      "\(testCase.name)"
    )
  }

  @Test("An unconfirmed delete is outcome-unknown, never an echo of the request", arguments: AdminCases.all)
  func emptyEnvelopeIsOutcomeUnknown(testCase: AdminCase) async throws {
    let transport = RecordingTransport.succeeding(json: "{\"kind\":\"ids\",\"data\":[]}")
    let response = await try AdminCases.runtime(transport: transport)
      .execute(document: testCase.document)

    let error = try #require(response.errors.first, "\(testCase.name)")
    #expect(error.code == .upstreamResponseInvalid, "\(testCase.name)")
    #expect(error.outcomeUnknown, "\(testCase.name)")
    #expect(
      response.data?[testCase.definition.field]?["deletedId"] == nil,
      "\(testCase.name) must not report the requested id as deleted"
    )
  }

  @Test("A delete never retries and never infers success", arguments: AdminCases.all)
  func neverRetriesOrInfersSuccess(testCase: AdminCase) async throws {
    let transport = RecordingTransport(outcomes: [.failure(.connectivity("dropped"))])
    let response = await try AdminCases.runtime(transport: transport)
      .execute(document: testCase.document)

    let error = try #require(response.errors.first, "\(testCase.name)")
    #expect(error.code == .transportFailed, "\(testCase.name)")
    #expect(error.outcomeUnknown, "\(testCase.name) must report an unknown outcome")
    #expect(response.data == nil, "\(testCase.name) must not claim a deletion")
    #expect(await transport.requestCount == 1, "\(testCase.name) must not replay a delete")
  }

  @Test("A 5xx on delete does not retry and stays outcome-unknown", arguments: AdminCases.all)
  func serverErrorIsUnknown(testCase: AdminCase) async throws {
    let transport = RecordingTransport(outcomes: [
      .response(WrikeResponse(statusCode: 500, body: Data("{}".utf8)))
    ])
    let response = await try AdminCases.runtime(transport: transport)
      .execute(document: testCase.document)

    let error = try #require(response.errors.first, "\(testCase.name)")
    #expect(error.code == .upstreamUnavailable)
    #expect(error.outcomeUnknown)
    #expect(await transport.requestCount == 1)
  }

  @Test("A delete requires its explicit identifier", arguments: AdminCases.all)
  func requiresIdentifier(testCase: AdminCase) async throws {
    let transport = RecordingTransport.succeeding(json: "{}")
    let response = await try AdminCases.runtime(transport: transport)
      .execute(document: "mutation { \(testCase.definition.field)(input: {}) { deletedId } }")

    #expect(response.errors.first?.code == .validationError, "\(testCase.name)")
    #expect(await transport.requestCount == 0, "\(testCase.name)")
  }

  @Test(
    "The typed SDK and GraphQL select the same plan for every delete",
    arguments: AdminCases.all
  )
  func sdkGraphQLParity(testCase: AdminCase) throws {
    let comparison = try ParityHarness.compare(
      planner: try AdminCases.planner(),
      invocation: testCase.invocation,
      document: testCase.document
    )
    #expect(comparison.isEquivalent, "\(testCase.name): \(comparison.summary)")
    #expect(comparison.sdkPlan?.request.method == .delete)
  }
}

@Suite("Destructive operation safety")
struct DestructiveOperationSafetyTests {
  @Test("Exactly the nine reviewed deletes are registered")
  func exactDeleteInventory() throws {
    let fields = Set(DeleteCapabilities.all.map(\.field))
    #expect(fields == Set(CapabilityCatalog.adminMutationFields))
    #expect(fields == [
      "deleteGroup", "deleteSpace", "deleteFolder", "deleteProject", "deleteTask",
      "deleteComment", "deleteAttachment", "deleteTimelog", "deleteWebhook"
    ])
    #expect(DeleteCapabilities.all.count == 9)
  }

  @Test("Every delete is admin-tier and DELETE-backed")
  func allDeletesAreAdmin() throws {
    for definition in DeleteCapabilities.all {
      #expect(definition.tier == .admin, "\(definition.id)")
      #expect(definition.method == .delete, "\(definition.id)")
      #expect(definition.operationClass == .delete, "\(definition.id)")
      #expect(definition.isDestructive, "\(definition.id)")
      #expect(definition.result == .deletion, "\(definition.id)")
    }
  }

  @Test("Every delete accepts exactly one required opaque identifier")
  func singleIdentifierInput() throws {
    for definition in DeleteCapabilities.all {
      #expect(definition.arguments.count == 1, "\(definition.id)")
      guard case .inputObject(let shape)? = definition.argument(named: "input")?.type else {
        Issue.record("\(definition.id) has no input object")
        continue
      }
      #expect(shape.fields.count == 1, "\(definition.id) must take one identifier only")
      let field = try #require(shape.fields.first)
      #expect(field.isRequired, "\(definition.id)")
      #expect(field.type == .identifier, "\(definition.id)")
    }
  }

  @Test("No delete exposes a force, recursive, wildcard, or bulk form")
  func noUnboundedDeletion() throws {
    let forbidden = ["force", "recursive", "descendant", "all", "wildcard", "bulk", "ids", "cascade"]
    for definition in DeleteCapabilities.all {
      guard case .inputObject(let shape)? = definition.argument(named: "input")?.type else {
        continue
      }
      for field in shape.fields {
        let lowered = field.name.lowercased()
        for term in forbidden {
          #expect(!lowered.contains(term), "\(definition.id).\(field.name) suggests \(term)")
        }
        // A list-valued identifier would permit an unbounded bulk delete.
        #expect(field.type != .identifierList, "\(definition.id).\(field.name)")
      }
    }
  }

  @Test("deleteFolder and deleteProject remain distinct capabilities")
  func folderProjectDeletesAreDistinct() throws {
    let folder = DeleteCapabilities.deleteFolder
    let project = DeleteCapabilities.deleteProject
    #expect(folder.id == CapabilityID("folders.delete"))
    #expect(project.id == CapabilityID("projects.delete"))
    #expect(folder.field != project.field)
    // They share the upstream family without exposing the shared raw path.
    #expect(folder.pathTemplate == "/folders/{folderId}")
    #expect(project.pathTemplate == "/folders/{projectId}")
  }

  @Test("The admin schema labels every delete as destructive")
  func schemaLabelsDeletes() throws {
    let schema = GraphQLSchemaPrinter(registry: try AdminCapabilities.registry()).print()
    for field in CapabilityCatalog.adminMutationFields {
      #expect(schema.contains("\(field)(input:"), "Missing \(field)")
    }
    #expect(schema.contains("DESTRUCTIVE."))
    #expect(schema.contains("type DeletionPayload {"))
  }

  @Test("The admin registry is cumulative with reader and writer")
  func cumulative() throws {
    let admin = try AdminCapabilities.registry()
    for definition in try WriteCapabilities.registry().definitions {
      #expect(admin.definition(for: definition.id) != nil, "Missing \(definition.id)")
    }
    #expect(admin.coherenceProblems().isEmpty)
    #expect(
      admin.mutationDefinitions.count
        == CapabilityCatalog.writerMutationFields.count + CapabilityCatalog.adminMutationFields.count
    )
  }

  @Test("A registry that places a delete below admin is rejected")
  func rejectsMisplacedDelete() throws {
    let misplaced = CapabilityDefinition(
      id: CapabilityID("tasks.deleteAsWriter"),
      field: "deleteTaskAsWriter",
      tier: .writer,
      operationClass: .delete,
      method: .delete,
      pathTemplate: "/tasks/{taskId}",
      arguments: [
        ArgumentDefinition(
          "input",
          .inputObject(InputObjectShape(
            typeName: "BadInput",
            fields: [ArgumentDefinition("taskId", .identifier, .path("taskId"), required: true)]
          )),
          .container,
          required: true
        )
      ],
      result: .deletion,
      scopes: .workspaceReadWrite,
      summary: "Should never be registrable."
    )
    #expect(throws: GatewayError.self) {
      _ = try CapabilityRegistry(tier: .writer, definitions: [misplaced])
    }
    #expect(throws: GatewayError.self) {
      _ = try CapabilityRegistry(tier: .admin, definitions: [misplaced])
    }
  }
}
