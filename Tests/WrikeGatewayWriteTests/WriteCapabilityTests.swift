import Foundation
import Testing
import WrikeGatewayCore
import WrikeGatewayRead
import WrikeGatewayTestSupport
import WrikeGatewayWrite

struct WriterCase: Sendable, CustomTestStringConvertible {
  let definition: CapabilityDefinition
  let arguments: [String: WrikeValue]
  let document: String
  let expectedMethod: HTTPMethod
  let expectedPath: String
  let responseKind: String
  let responseData: String

  var name: String { definition.id.rawValue }

  /// Keeps parameterized-test output readable; the full definition is noise.
  var testDescription: String { name }
}

enum WriterCases {
  /// A writable file fixture for the upload capabilities. The path is never
  /// opened by these tests; only the planner's validation seam sees it.
  static let uploadPath = "/tmp/wrike-gateway-fake-brief.pdf"

  static let all: [WriterCase] = [
    WriterCase(
      definition: PeopleMutations.updateContact,
      arguments: ["input": .object(["contactId": .string("KUAAAAAA"), "title": .string("Lead")])],
      document: """
        mutation { updateContact(input: {contactId: "KUAAAAAA", title: "Lead"}) \
        { contact { id firstName } } }
        """,
      expectedMethod: .put,
      expectedPath: "/api/v4/contacts/KUAAAAAA",
      responseKind: "contacts",
      responseData: WrikeFixtures.contact
    ),
    WriterCase(
      definition: PeopleMutations.updateUser,
      arguments: ["input": .object(["userId": .string("KUAAAAAA"), "external": .bool(false)])],
      document: """
        mutation { updateUser(input: {userId: "KUAAAAAA", external: false}) { user { id } } }
        """,
      expectedMethod: .put,
      expectedPath: "/api/v4/users/KUAAAAAA",
      responseKind: "users",
      responseData: "{\"id\":\"KUAAAAAA\",\"firstName\":\"Alex\"}"
    ),
    WriterCase(
      definition: PeopleMutations.createGroup,
      arguments: ["input": .object(["title": .string("Design")])],
      document: "mutation { createGroup(input: {title: \"Design\"}) { group { id title } } }",
      expectedMethod: .post,
      expectedPath: "/api/v4/groups",
      responseKind: "groups",
      responseData: "{\"id\":\"KX1\",\"title\":\"Design\"}"
    ),
    WriterCase(
      definition: PeopleMutations.updateGroup,
      arguments: ["input": .object([
        "groupId": .string("KX1"),
        "addMemberIds": .array([.string("KUAAAAAA")])
      ])],
      document: """
        mutation { updateGroup(input: {groupId: "KX1", addMemberIds: ["KUAAAAAA"]}) \
        { group { id memberIds } } }
        """,
      expectedMethod: .put,
      expectedPath: "/api/v4/groups/KX1",
      responseKind: "groups",
      responseData: "{\"id\":\"KX1\",\"title\":\"Design\",\"memberIds\":[\"KUAAAAAA\"]}"
    ),
    WriterCase(
      definition: PeopleMutations.updateAccount,
      arguments: ["input": .object(["metadata": .string("x")])],
      document: "mutation { updateAccount(input: {metadata: \"x\"}) { account { id } } }",
      expectedMethod: .put,
      expectedPath: "/api/v4/account",
      responseKind: "accounts",
      responseData: "{\"id\":\"IEAAAAAA\",\"name\":\"Example\"}"
    ),
    WriterCase(
      definition: WorkHierarchyMutations.createSpace,
      arguments: ["input": .object(["title": .string("Marketing")])],
      document: "mutation { createSpace(input: {title: \"Marketing\"}) { space { id title } } }",
      expectedMethod: .post,
      expectedPath: "/api/v4/spaces",
      responseKind: "spaces",
      responseData: "{\"id\":\"IEAG\",\"title\":\"Marketing\"}"
    ),
    WriterCase(
      definition: WorkHierarchyMutations.updateSpace,
      arguments: ["input": .object(["spaceId": .string("IEAG"), "archived": .bool(true)])],
      document: """
        mutation { updateSpace(input: {spaceId: "IEAG", archived: true}) { space { id archived } } }
        """,
      expectedMethod: .put,
      expectedPath: "/api/v4/spaces/IEAG",
      responseKind: "spaces",
      responseData: "{\"id\":\"IEAG\",\"title\":\"Marketing\",\"archived\":true}"
    ),
    WriterCase(
      definition: WorkHierarchyMutations.createFolder,
      arguments: ["input": .object([
        "parentFolderId": .string("IEAAAAAAI4"),
        "title": .string("Launch")
      ])],
      document: """
        mutation { createFolder(input: {parentFolderId: "IEAAAAAAI4", title: "Launch"}) \
        { folder { id title } } }
        """,
      expectedMethod: .post,
      expectedPath: "/api/v4/folders/IEAAAAAAI4/folders",
      responseKind: "folders",
      responseData: WrikeFixtures.folder
    ),
    WriterCase(
      definition: WorkHierarchyMutations.updateFolder,
      arguments: ["input": .object([
        "folderId": .string("IEAAAAAAI4AB5FNY"),
        "title": .string("Renamed")
      ])],
      document: """
        mutation { updateFolder(input: {folderId: "IEAAAAAAI4AB5FNY", title: "Renamed"}) \
        { folder { id title } } }
        """,
      expectedMethod: .put,
      expectedPath: "/api/v4/folders/IEAAAAAAI4AB5FNY",
      responseKind: "folders",
      responseData: WrikeFixtures.folder
    ),
    WriterCase(
      definition: WorkHierarchyMutations.copyFolder,
      arguments: ["input": .object([
        "folderId": .string("IEAAAAAAI4AB5FNY"),
        "parentId": .string("IEAAAAAAI4"),
        "title": .string("Copy")
      ])],
      document: """
        mutation { copyFolder(input: {folderId: "IEAAAAAAI4AB5FNY", parentId: "IEAAAAAAI4", \
        title: "Copy"}) { folder { id title } } }
        """,
      expectedMethod: .post,
      expectedPath: "/api/v4/copy_folder/IEAAAAAAI4AB5FNY",
      responseKind: "folders",
      responseData: WrikeFixtures.folder
    ),
    WriterCase(
      definition: WorkHierarchyMutations.createProject,
      arguments: ["input": .object([
        "parentFolderId": .string("IEAAAAAAI4"),
        "title": .string("Launch")
      ])],
      document: """
        mutation { createProject(input: {parentFolderId: "IEAAAAAAI4", title: "Launch"}) \
        { project { id title } } }
        """,
      expectedMethod: .post,
      expectedPath: "/api/v4/folders/IEAAAAAAI4/folders",
      responseKind: "folders",
      responseData: WrikeFixtures.folder
    ),
    WriterCase(
      definition: WorkHierarchyMutations.updateProject,
      arguments: ["input": .object([
        "projectId": .string("IEAAAAAAI4AB5FNY"),
        "title": .string("Renamed")
      ])],
      document: """
        mutation { updateProject(input: {projectId: "IEAAAAAAI4AB5FNY", title: "Renamed"}) \
        { project { id title } } }
        """,
      expectedMethod: .put,
      expectedPath: "/api/v4/folders/IEAAAAAAI4AB5FNY",
      responseKind: "folders",
      responseData: WrikeFixtures.folder
    ),
    WriterCase(
      definition: WorkHierarchyMutations.createTask,
      arguments: ["input": .object([
        "folderId": .string("IEAAAAAAI4AB5FNY"),
        "title": .string("Prepare launch")
      ])],
      document: """
        mutation { createTask(input: {folderId: "IEAAAAAAI4AB5FNY", title: "Prepare launch"}) \
        { task { id title } } }
        """,
      expectedMethod: .post,
      expectedPath: "/api/v4/folders/IEAAAAAAI4AB5FNY/tasks",
      responseKind: "tasks",
      responseData: WrikeFixtures.task
    ),
    WriterCase(
      definition: WorkHierarchyMutations.updateTask,
      arguments: ["input": .object([
        "taskId": .string("IEAAAAAAKQAB5FNY"),
        "status": .string("Completed")
      ])],
      document: """
        mutation { updateTask(input: {taskId: "IEAAAAAAKQAB5FNY", status: Completed}) \
        { task { id status } } }
        """,
      expectedMethod: .put,
      expectedPath: "/api/v4/tasks/IEAAAAAAKQAB5FNY",
      responseKind: "tasks",
      responseData: WrikeFixtures.task
    ),
    WriterCase(
      definition: CollaborationMutations.createComment,
      arguments: [
        "scope": .object(["taskId": .string("IEAAAAAAKQAB5FNY")]),
        "input": .object(["text": .string("Looks good")])
      ],
      document: """
        mutation { createComment(scope: {taskId: "IEAAAAAAKQAB5FNY"}, input: {text: "Looks good"}) \
        { comment { id text } } }
        """,
      expectedMethod: .post,
      expectedPath: "/api/v4/tasks/IEAAAAAAKQAB5FNY/comments",
      responseKind: "comments",
      responseData: WrikeFixtures.comment
    ),
    WriterCase(
      definition: CollaborationMutations.updateComment,
      arguments: ["input": .object([
        "commentId": .string("IEAAAAAAIMAAAAAB"),
        "text": .string("Updated")
      ])],
      document: """
        mutation { updateComment(input: {commentId: "IEAAAAAAIMAAAAAB", text: "Updated"}) \
        { comment { id text } } }
        """,
      expectedMethod: .put,
      expectedPath: "/api/v4/comments/IEAAAAAAIMAAAAAB",
      responseKind: "comments",
      responseData: WrikeFixtures.comment
    ),
    WriterCase(
      definition: CollaborationMutations.uploadTaskAttachment,
      arguments: ["input": .object([
        "taskId": .string("IEAAAAAAKQAB5FNY"),
        "filePath": .string(uploadPath)
      ])],
      document: """
        mutation { uploadTaskAttachment(input: {taskId: "IEAAAAAAKQAB5FNY", \
        filePath: "\(uploadPath)"}) { attachment { id name } } }
        """,
      expectedMethod: .post,
      expectedPath: "/api/v4/tasks/IEAAAAAAKQAB5FNY/attachments",
      responseKind: "attachments",
      responseData: WrikeFixtures.attachment
    ),
    WriterCase(
      definition: CollaborationMutations.uploadFolderAttachment,
      arguments: ["input": .object([
        "folderId": .string("IEAAAAAAI4AB5FNY"),
        "filePath": .string(uploadPath)
      ])],
      document: """
        mutation { uploadFolderAttachment(input: {folderId: "IEAAAAAAI4AB5FNY", \
        filePath: "\(uploadPath)"}) { attachment { id name } } }
        """,
      expectedMethod: .post,
      expectedPath: "/api/v4/folders/IEAAAAAAI4AB5FNY/attachments",
      responseKind: "attachments",
      responseData: WrikeFixtures.attachment
    ),
    WriterCase(
      definition: CollaborationMutations.updateAttachment,
      arguments: ["input": .object([
        "attachmentId": .string("IEAAAAAAIYAAAAAB"),
        "filePath": .string(uploadPath)
      ])],
      document: """
        mutation { updateAttachment(input: {attachmentId: "IEAAAAAAIYAAAAAB", \
        filePath: "\(uploadPath)"}) { attachment { id version } } }
        """,
      expectedMethod: .put,
      expectedPath: "/api/v4/attachments/IEAAAAAAIYAAAAAB",
      responseKind: "attachments",
      responseData: WrikeFixtures.attachment
    ),
    WriterCase(
      definition: CollaborationMutations.createTimelog,
      arguments: ["input": .object([
        "taskId": .string("IEAAAAAAKQAB5FNY"),
        "hours": .double(1.5)
      ])],
      document: """
        mutation { createTimelog(input: {taskId: "IEAAAAAAKQAB5FNY", hours: 1.5}) \
        { timelog { id hours } } }
        """,
      expectedMethod: .post,
      expectedPath: "/api/v4/tasks/IEAAAAAAKQAB5FNY/timelogs",
      responseKind: "timelogs",
      responseData: WrikeFixtures.timelog
    ),
    WriterCase(
      definition: CollaborationMutations.updateTimelog,
      arguments: ["input": .object([
        "timelogId": .string("IEAAAAAAJAAAAAAB"),
        "hours": .double(2)
      ])],
      document: """
        mutation { updateTimelog(input: {timelogId: "IEAAAAAAJAAAAAAB", hours: 2.0}) \
        { timelog { id hours } } }
        """,
      expectedMethod: .put,
      expectedPath: "/api/v4/timelogs/IEAAAAAAJAAAAAAB",
      responseKind: "timelogs",
      responseData: WrikeFixtures.timelog
    ),
    WriterCase(
      definition: CollaborationMutations.createCustomField,
      arguments: ["input": .object([
        "title": .string("Budget"),
        "type": .string("Numeric")
      ])],
      document: """
        mutation { createCustomField(input: {title: "Budget", type: "Numeric"}) \
        { customField { id title } } }
        """,
      expectedMethod: .post,
      expectedPath: "/api/v4/customfields",
      responseKind: "customfields",
      responseData: "{\"id\":\"CF1\",\"title\":\"Budget\",\"type\":\"Numeric\"}"
    ),
    WriterCase(
      definition: CollaborationMutations.updateCustomField,
      arguments: ["input": .object([
        "customFieldId": .string("CF1"),
        "title": .string("Cost")
      ])],
      document: """
        mutation { updateCustomField(input: {customFieldId: "CF1", title: "Cost"}) \
        { customField { id title } } }
        """,
      expectedMethod: .put,
      expectedPath: "/api/v4/customfields/CF1",
      responseKind: "customfields",
      responseData: "{\"id\":\"CF1\",\"title\":\"Cost\",\"type\":\"Numeric\"}"
    ),
    WriterCase(
      definition: CollaborationMutations.createWorkflow,
      arguments: ["input": .object(["name": .string("Review")])],
      document: "mutation { createWorkflow(input: {name: \"Review\"}) { workflow { id name } } }",
      expectedMethod: .post,
      expectedPath: "/api/v4/workflows",
      responseKind: "workflows",
      responseData: "{\"id\":\"WF2\",\"name\":\"Review\"}"
    ),
    WriterCase(
      definition: CollaborationMutations.updateWorkflow,
      arguments: ["input": .object([
        "workflowId": .string("WF2"),
        "hidden": .bool(true)
      ])],
      document: """
        mutation { updateWorkflow(input: {workflowId: "WF2", hidden: true}) { workflow { id } } }
        """,
      expectedMethod: .put,
      expectedPath: "/api/v4/workflows/WF2",
      responseKind: "workflows",
      responseData: "{\"id\":\"WF2\",\"name\":\"Review\",\"hidden\":true}"
    ),
    WriterCase(
      definition: CollaborationMutations.createWebhook,
      arguments: ["input": .object(["hookUrl": .string("https://example.test/hook")])],
      document: """
        mutation { createWebhook(input: {hookUrl: "https://example.test/hook"}) \
        { webhook { id status } } }
        """,
      expectedMethod: .post,
      expectedPath: "/api/v4/webhooks",
      responseKind: "webhooks",
      responseData: WrikeFixtures.webhook
    ),
    WriterCase(
      definition: CollaborationMutations.updateWebhookStatus,
      arguments: ["input": .object([
        "webhookId": .string("IEAAAAAAJEAAAAAB"),
        "status": .string("Suspended")
      ])],
      document: """
        mutation { updateWebhookStatus(input: {webhookId: "IEAAAAAAJEAAAAAB", status: Suspended}) \
        { webhook { id status } } }
        """,
      expectedMethod: .put,
      expectedPath: "/api/v4/webhooks/IEAAAAAAJEAAAAAB",
      responseKind: "webhooks",
      responseData: WrikeFixtures.webhook
    )
  ]

  static func planner() throws -> CapabilityPlanner {
    CapabilityPlanner(
      registry: try WriteCapabilities.registry(),
      coercer: ArgumentCoercer(fileAccess: StubFileAccess(readable: [uploadPath]))
    )
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
}

@Suite("Writer capability contract")
struct WriterCapabilityContractTests {
  @Test("Every writer capability maps to its exact upstream route", arguments: WriterCases.all)
  func mapsRoute(testCase: WriterCase) async throws {
    let transport = RecordingTransport.succeeding(
      json: WrikeFixtures.envelope(kind: testCase.responseKind, data: testCase.responseData)
    )
    let response = try await WriterCases.runtime(transport: transport)
      .execute(document: testCase.document)

    #expect(response.errors.isEmpty, "\(testCase.name): \(response.errors)")
    let recorded = try await transport.firstRequest()
    #expect(recorded.method == testCase.expectedMethod, "\(testCase.name)")
    #expect(recorded.path == testCase.expectedPath, "\(testCase.name)")
    #expect(recorded.method != .delete, "\(testCase.name) must never use DELETE")
  }

  @Test("Every writer capability surfaces a mapped failure", arguments: WriterCases.all)
  func mapsFailure(testCase: WriterCase) async throws {
    let transport = RecordingTransport(outcomes: [
      .response(WrikeResponse(statusCode: 400, body: Data(WrikeFixtures.errorBody.utf8)))
    ])
    let response = try await WriterCases.runtime(transport: transport)
      .execute(document: testCase.document)

    let error = try #require(response.errors.first, "\(testCase.name)")
    #expect(error.code == .validationError)
    #expect(error.capabilityID == testCase.definition.id)
  }

  @Test("No writer mutation retries after a transport failure", arguments: WriterCases.all)
  func neverRetries(testCase: WriterCase) async throws {
    let transport = RecordingTransport(outcomes: [.failure(.timedOut)])
    let response = try await WriterCases.runtime(transport: transport)
      .execute(document: testCase.document)

    let error = try #require(response.errors.first, "\(testCase.name)")
    #expect(error.code == .transportFailed)
    #expect(error.outcomeUnknown, "\(testCase.name) must report an unknown outcome")
    #expect(await transport.requestCount == 1, "\(testCase.name) must not replay")
  }

  @Test(
    "The typed SDK and GraphQL select the same plan for every writer capability",
    arguments: WriterCases.all
  )
  func sdkGraphQLParity(testCase: WriterCase) throws {
    let comparison = try ParityHarness.compare(
      planner: try WriterCases.planner(),
      invocation: CapabilityInvocation(
        capabilityID: testCase.definition.id,
        arguments: testCase.arguments
      ),
      document: testCase.document
    )
    #expect(comparison.isEquivalent, "\(testCase.name): \(comparison.summary)")
  }
}

@Suite("Writer boundary")
struct WriterBoundaryTests {
  @Test("The writer module registers no destructive capability")
  func noDestructiveCapability() throws {
    #expect(throws: Never.self) {
      try WriteCapabilities.assertNoDestructiveCapability()
    }
    for definition in WriteCapabilities.mutations {
      #expect(definition.method != .delete, "\(definition.id)")
      #expect(definition.operationClass != .delete, "\(definition.id)")
      #expect(definition.tier == .writer, "\(definition.id)")
      #expect(!definition.field.hasPrefix("delete"), "\(definition.id)")
    }
  }

  @Test("The writer schema contains no delete field and no deletion payload")
  func schemaHasNoDeleteField() throws {
    let schema = GraphQLSchemaPrinter(registry: try WriteCapabilities.registry()).print()
    #expect(schema.contains("type Mutation {"))
    #expect(!schema.contains("DeletionPayload"))
    #expect(!schema.contains("DESTRUCTIVE"))
    for field in CapabilityCatalog.adminMutationFields {
      #expect(!schema.contains("\(field)("), "Writer schema must not expose \(field)")
    }
  }

  @Test("A delete mutation is denied by the writer registry, naming the admin tier")
  func deniesDeleteMutation() async throws {
    let transport = RecordingTransport.succeeding(json: "{}")
    let response = try await WriterCases.runtime(transport: transport).execute(
      document: "mutation { deleteTask(input: {taskId: \"IEAAAAAAKQAB5FNY\"}) { deletedId } }"
    )

    let error = try #require(response.errors.first)
    #expect(error.code == .capabilityDenied)
    #expect(error.requiredTier == .admin)
    #expect(await transport.requestCount == 0)
  }

  @Test("The writer registry is cumulative with the reader registry")
  func cumulativeWithReader() throws {
    let writer = try WriteCapabilities.registry()
    for definition in try ReadCapabilities.registry().definitions {
      #expect(writer.definition(for: definition.id) != nil, "Missing \(definition.id)")
    }
    #expect(writer.mutationDefinitions.count == CapabilityCatalog.writerMutationFields.count)
  }

  @Test("The writer field catalog matches the registered writer mutations")
  func catalogMatchesRegistrations() throws {
    let registered = Set(try WriteCapabilities.registry().mutationDefinitions.map(\.field))
    #expect(registered == Set(CapabilityCatalog.writerMutationFields))
  }

  @Test("Every writer capability is covered by a contract case")
  func everyCapabilityHasACase() throws {
    let registered = Set(WriteCapabilities.mutations.map(\.id))
    let covered = Set(WriterCases.all.map(\.definition.id))
    #expect(registered == covered, "Uncovered: \(registered.subtracting(covered).map(\.rawValue))")
  }

  @Test("An upload streams from a validated file and never buffers its bytes")
  func uploadStreamsFromFile() async throws {
    let transport = RecordingTransport.succeeding(
      json: WrikeFixtures.envelope(kind: "attachments", data: WrikeFixtures.attachment)
    )
    let response = try await WriterCases.runtime(transport: transport).execute(document: """
      mutation { uploadTaskAttachment(input: {taskId: "IEAAAAAAKQAB5FNY", \
      filePath: "\(WriterCases.uploadPath)"}) { attachment { id name } } }
      """)

    #expect(response.errors.isEmpty)
    let recorded = try await transport.firstRequest()
    #expect(recorded.bodyDescription.hasPrefix("file:"))
    #expect(recorded.bodyDescription.contains("wrike-gateway-fake-brief.pdf"))
  }

  @Test("An upload naming an unreadable file fails locally")
  func rejectsUnreadableUpload() async throws {
    let transport = RecordingTransport.succeeding(json: "{}")
    let response = try await WriterCases.runtime(transport: transport).execute(document: """
      mutation { uploadTaskAttachment(input: {taskId: "IEAAAAAAKQAB5FNY", \
      filePath: "/tmp/definitely-not-present"}) { attachment { id } } }
      """)

    let error = try #require(response.errors.first)
    #expect(error.code == .fileOperationFailed)
    #expect(error.exitCode == .localResource)
    #expect(await transport.requestCount == 0)
  }

  @Test("Membership updates name each member and offer no wildcard form")
  func membershipIsExplicit() throws {
    let inputs = [
      PeopleMutations.updateGroup,
      WorkHierarchyMutations.updateSpace,
      WorkHierarchyMutations.updateFolder,
      CollaborationMutations.updateCustomField
    ]
    for definition in inputs {
      guard case .inputObject(let shape)? = definition.argument(named: "input")?.type else {
        Issue.record("\(definition.id) has no input object")
        continue
      }
      let names = shape.fields.map(\.name)
      #expect(!names.contains { $0.lowercased().contains("all") }, "\(definition.id)")
      #expect(!names.contains { $0.lowercased().contains("recursive") }, "\(definition.id)")
      #expect(!names.contains { $0.lowercased().contains("wildcard") }, "\(definition.id)")
      #expect(names.contains { $0.hasPrefix("add") || $0.hasPrefix("remove") }, "\(definition.id)")
    }
  }

  @Test("A comment creation without a scope is rejected before transport")
  func commentRequiresScope() async throws {
    let transport = RecordingTransport.succeeding(json: "{}")
    let response = try await WriterCases.runtime(transport: transport)
      .execute(document: "mutation { createComment(input: {text: \"Hi\"}) { comment { id } } }")

    #expect(response.errors.first?.code == .validationError)
    #expect(await transport.requestCount == 0)
  }
}
