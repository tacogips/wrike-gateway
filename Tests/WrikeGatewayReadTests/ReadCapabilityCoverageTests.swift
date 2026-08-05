import Foundation
import Testing
import WrikeGatewayCore
import WrikeGatewayRead
import WrikeGatewayTestSupport

/// One canonical exercise per reader capability: the arguments to send, the
/// GraphQL document that must produce the identical plan, and the upstream
/// method and path the adapter must select.
struct ReaderCase: Sendable, CustomTestStringConvertible {
  let definition: CapabilityDefinition
  let arguments: [String: WrikeValue]
  let document: String
  let expectedPath: String
  let expectedQuery: [String: String]
  let responseKind: String
  let responseData: String

  init(
    _ definition: CapabilityDefinition,
    arguments: [String: WrikeValue] = [:],
    document: String,
    expectedPath: String,
    expectedQuery: [String: String] = [:],
    responseKind: String,
    responseData: String
  ) {
    self.definition = definition
    self.arguments = arguments
    self.document = document
    self.expectedPath = expectedPath
    self.expectedQuery = expectedQuery
    self.responseKind = responseKind
    self.responseData = responseData
  }

  var name: String { definition.id.rawValue }

  /// Keeps parameterized-test output readable; the full definition is noise.
  var testDescription: String { name }
}

enum ReaderCases {
  static let contact = WrikeFixtures.contact
  static let folder = WrikeFixtures.folder
  static let task = WrikeFixtures.task

  static let all: [ReaderCase] = [
    ReaderCase(
      ContactCapabilities.list,
      arguments: ["types": .array([.string("Person")])],
      document: "{ contacts(types: [\"Person\"]) { id firstName } }",
      expectedPath: "/api/v4/contacts",
      expectedQuery: ["types": "[\"Person\"]"],
      responseKind: "contacts",
      responseData: contact
    ),
    ReaderCase(
      ContactCapabilities.get,
      arguments: ["id": .string("KUAAAAAA")],
      document: "{ contact(id: \"KUAAAAAA\") { id firstName lastName } }",
      expectedPath: "/api/v4/contacts/KUAAAAAA",
      responseKind: "contacts",
      responseData: contact
    ),
    ReaderCase(
      UserCapabilities.get,
      arguments: ["id": .string("KUAAAAAA")],
      document: "{ user(id: \"KUAAAAAA\") { id firstName } }",
      expectedPath: "/api/v4/users/KUAAAAAA",
      responseKind: "users",
      responseData: "{\"id\":\"KUAAAAAA\",\"firstName\":\"Alex\",\"type\":\"Person\"}"
    ),
    ReaderCase(
      UserCapabilities.types,
      document: "{ userTypes { id title } }",
      expectedPath: "/api/v4/user_types",
      responseKind: "userTypes",
      responseData: "{\"id\":\"UT1\",\"title\":\"Regular\",\"licenseType\":\"Full\"}"
    ),
    ReaderCase(
      GroupCapabilities.list,
      document: "{ groups { id title } }",
      expectedPath: "/api/v4/groups",
      responseKind: "groups",
      responseData: "{\"id\":\"KX1\",\"title\":\"Design\",\"memberIds\":[\"KUAAAAAA\"]}"
    ),
    ReaderCase(
      GroupCapabilities.get,
      arguments: ["id": .string("KX1")],
      document: "{ group(id: \"KX1\") { id title memberIds } }",
      expectedPath: "/api/v4/groups/KX1",
      responseKind: "groups",
      responseData: "{\"id\":\"KX1\",\"title\":\"Design\",\"memberIds\":[\"KUAAAAAA\"]}"
    ),
    ReaderCase(
      AccountCapabilities.get,
      document: "{ account { id name rootFolderId } }",
      expectedPath: "/api/v4/account",
      responseKind: "accounts",
      responseData: "{\"id\":\"IEAAAAAA\",\"name\":\"Example\",\"rootFolderId\":\"IEAAAAAAI4\"}"
    ),
    ReaderCase(
      AccountCapabilities.accessRoles,
      document: "{ accessRoles { id title } }",
      expectedPath: "/api/v4/access_roles",
      responseKind: "accessRoles",
      responseData: "{\"id\":\"AR1\",\"title\":\"Editor\"}"
    ),
    ReaderCase(
      SpaceCapabilities.list,
      arguments: ["withArchived": .bool(false)],
      document: "{ spaces(withArchived: false) { id title } }",
      expectedPath: "/api/v4/spaces",
      expectedQuery: ["withArchived": "false"],
      responseKind: "spaces",
      responseData: "{\"id\":\"IEAG\",\"title\":\"Marketing\",\"accessType\":\"Public\"}"
    ),
    ReaderCase(
      SpaceCapabilities.get,
      arguments: ["id": .string("IEAG")],
      document: "{ space(id: \"IEAG\") { id title accessType } }",
      expectedPath: "/api/v4/spaces/IEAG",
      responseKind: "spaces",
      responseData: "{\"id\":\"IEAG\",\"title\":\"Marketing\",\"accessType\":\"Public\"}"
    ),
    ReaderCase(
      FolderCapabilities.list,
      arguments: ["scope": .object(["spaceId": .string("IEAG")])],
      document: "{ folders(scope: {spaceId: \"IEAG\"}) { id title } }",
      expectedPath: "/api/v4/spaces/IEAG/folders",
      responseKind: "folders",
      responseData: folder
    ),
    ReaderCase(
      FolderCapabilities.get,
      arguments: ["id": .string("IEAAAAAAI4AB5FNY")],
      document: "{ folder(id: \"IEAAAAAAI4AB5FNY\") { id title childIds } }",
      expectedPath: "/api/v4/folders/IEAAAAAAI4AB5FNY",
      responseKind: "folders",
      responseData: folder
    ),
    ReaderCase(
      ProjectCapabilities.list,
      arguments: ["scope": .object(["folderId": .string("IEAAAAAAI4AB5FNY")]), "project": .bool(true)],
      document: "{ projects(scope: {folderId: \"IEAAAAAAI4AB5FNY\"}, project: true) { id title } }",
      expectedPath: "/api/v4/folders/IEAAAAAAI4AB5FNY/folders",
      expectedQuery: ["project": "true"],
      responseKind: "folders",
      responseData: folder
    ),
    ReaderCase(
      ProjectCapabilities.get,
      arguments: ["id": .string("IEAAAAAAI4AB5FNY")],
      document: "{ project(id: \"IEAAAAAAI4AB5FNY\") { id title project { ownerIds } } }",
      expectedPath: "/api/v4/folders/IEAAAAAAI4AB5FNY",
      responseKind: "folders",
      responseData: folder
    ),
    ReaderCase(
      TaskCapabilities.list,
      arguments: [
        "scope": .object(["folderId": .string("IEAAAAAAI4AB5FNY")]),
        "page": .object(["pageSize": .int(100)])
      ],
      document: """
        { tasks(scope: {folderId: "IEAAAAAAI4AB5FNY"}, page: {pageSize: 100}) \
        { nodes { id title } pageInfo { resultCount nextPageToken } } }
        """,
      expectedPath: "/api/v4/folders/IEAAAAAAI4AB5FNY/tasks",
      expectedQuery: ["pageSize": "100"],
      responseKind: "tasks",
      responseData: task
    ),
    ReaderCase(
      TaskCapabilities.get,
      arguments: ["id": .string("IEAAAAAAKQAB5FNY")],
      document: "{ task(id: \"IEAAAAAAKQAB5FNY\") { id title status responsibleIds } }",
      expectedPath: "/api/v4/tasks/IEAAAAAAKQAB5FNY",
      responseKind: "tasks",
      responseData: task
    ),
    ReaderCase(
      CommentCapabilities.list,
      arguments: ["scope": .object(["taskId": .string("IEAAAAAAKQAB5FNY")])],
      document: "{ comments(scope: {taskId: \"IEAAAAAAKQAB5FNY\"}) { id text } }",
      expectedPath: "/api/v4/tasks/IEAAAAAAKQAB5FNY/comments",
      responseKind: "comments",
      responseData: WrikeFixtures.comment
    ),
    ReaderCase(
      CommentCapabilities.get,
      arguments: ["id": .string("IEAAAAAAIMAAAAAB")],
      document: "{ comment(id: \"IEAAAAAAIMAAAAAB\") { id text authorId } }",
      expectedPath: "/api/v4/comments/IEAAAAAAIMAAAAAB",
      responseKind: "comments",
      responseData: WrikeFixtures.comment
    ),
    ReaderCase(
      AttachmentCapabilities.list,
      arguments: [
        "scope": .object(["taskId": .string("IEAAAAAAKQAB5FNY")]),
        "withUrls": .bool(true)
      ],
      document: "{ attachments(scope: {taskId: \"IEAAAAAAKQAB5FNY\"}, withUrls: true) { id name } }",
      expectedPath: "/api/v4/tasks/IEAAAAAAKQAB5FNY/attachments",
      expectedQuery: ["withUrls": "true"],
      responseKind: "attachments",
      responseData: WrikeFixtures.attachment
    ),
    ReaderCase(
      AttachmentCapabilities.get,
      arguments: ["id": .string("IEAAAAAAIYAAAAAB")],
      document: "{ attachment(id: \"IEAAAAAAIYAAAAAB\") { id name size contentType } }",
      expectedPath: "/api/v4/attachments/IEAAAAAAIYAAAAAB",
      responseKind: "attachments",
      responseData: WrikeFixtures.attachment
    ),
    ReaderCase(
      AttachmentCapabilities.url,
      arguments: ["id": .string("IEAAAAAAIYAAAAAB")],
      document: "{ attachmentDownloadUrl(id: \"IEAAAAAAIYAAAAAB\") { id url } }",
      expectedPath: "/api/v4/attachments/IEAAAAAAIYAAAAAB/url",
      responseKind: "attachments",
      responseData: "{\"id\":\"IEAAAAAAIYAAAAAB\",\"url\":\"https://example.test/d\",\"name\":\"brief.pdf\"}"
    ),
    ReaderCase(
      TimelogCapabilities.list,
      arguments: ["scope": .object(["taskId": .string("IEAAAAAAKQAB5FNY")])],
      document: """
        { timelogs(scope: {taskId: "IEAAAAAAKQAB5FNY"}) \
        { nodes { id hours } pageInfo { resultCount } } }
        """,
      expectedPath: "/api/v4/tasks/IEAAAAAAKQAB5FNY/timelogs",
      responseKind: "timelogs",
      responseData: WrikeFixtures.timelog
    ),
    ReaderCase(
      TimelogCapabilities.get,
      arguments: ["id": .string("IEAAAAAAJAAAAAAB")],
      document: "{ timelog(id: \"IEAAAAAAJAAAAAAB\") { id hours trackedDate } }",
      expectedPath: "/api/v4/timelogs/IEAAAAAAJAAAAAAB",
      responseKind: "timelogs",
      responseData: WrikeFixtures.timelog
    ),
    ReaderCase(
      CustomFieldCapabilities.list,
      arguments: ["scope": .object(["spaceId": .string("IEAG")])],
      document: "{ customFields(scope: {spaceId: \"IEAG\"}) { id title type } }",
      expectedPath: "/api/v4/spaces/IEAG/customfields",
      responseKind: "customfields",
      responseData: "{\"id\":\"CF1\",\"title\":\"Budget\",\"type\":\"Numeric\"}"
    ),
    ReaderCase(
      CustomFieldCapabilities.get,
      arguments: ["id": .string("CF1")],
      document: "{ customField(id: \"CF1\") { id title } }",
      expectedPath: "/api/v4/customfields/CF1",
      responseKind: "customfields",
      responseData: "{\"id\":\"CF1\",\"title\":\"Budget\",\"type\":\"Numeric\"}"
    ),
    ReaderCase(
      WorkflowCapabilities.list,
      document: "{ workflows { id name customStatuses { id name } } }",
      expectedPath: "/api/v4/workflows",
      responseKind: "workflows",
      responseData: """
        {"id":"WF1","name":"Default","standard":true,\
        "customStatuses":[{"id":"CS1","name":"New","group":"Active"}]}
        """
    ),
    ReaderCase(
      WebhookCapabilities.list,
      document: "{ webhooks { id hookUrl status } }",
      expectedPath: "/api/v4/webhooks",
      responseKind: "webhooks",
      responseData: WrikeFixtures.webhook
    ),
    ReaderCase(
      WebhookCapabilities.get,
      arguments: ["id": .string("IEAAAAAAJEAAAAAB")],
      document: "{ webhook(id: \"IEAAAAAAJEAAAAAB\") { id status events } }",
      expectedPath: "/api/v4/webhooks/IEAAAAAAJEAAAAAB",
      responseKind: "webhooks",
      responseData: WrikeFixtures.webhook
    )
  ]

  static func runtime(transport: RecordingTransport) throws -> GraphQLRuntime {
    GraphQLRuntime(
      executor: CapabilityExecutor(
        planner: CapabilityPlanner(registry: try ReadCapabilities.registry()),
        transport: transport,
        credentials: StubCredentialProvider(),
        clock: TestClock(),
        retryPolicy: RetryPolicy(jitterFraction: 0)
      ),
      requestIDFactory: { "fixed-request-id" }
    )
  }
}

@Suite("Reader capability contract")
struct ReaderCapabilityContractTests {
  @Test("Every reader capability maps to its exact upstream route", arguments: ReaderCases.all)
  func mapsRoute(testCase: ReaderCase) async throws {
    let transport = RecordingTransport.succeeding(
      json: WrikeFixtures.envelope(kind: testCase.responseKind, data: testCase.responseData)
    )
    let runtime = try ReaderCases.runtime(transport: transport)
    let response = await runtime.execute(document: testCase.document)

    #expect(response.errors.isEmpty, "\(testCase.name): \(response.errors)")
    let recorded = try await transport.firstRequest()
    #expect(recorded.method == .get, "\(testCase.name) must use GET")
    #expect(recorded.path == testCase.expectedPath, "\(testCase.name)")
    for (name, value) in testCase.expectedQuery {
      #expect(recorded.query[name] == value, "\(testCase.name) query \(name)")
    }
    #expect(recorded.capabilityID == testCase.definition.id)
  }

  @Test("Every reader capability surfaces a mapped failure", arguments: ReaderCases.all)
  func mapsFailure(testCase: ReaderCase) async throws {
    let transport = RecordingTransport(outcomes: [
      .response(WrikeResponse(statusCode: 403, body: Data(WrikeFixtures.errorBody.utf8)))
    ])
    let runtime = try ReaderCases.runtime(transport: transport)
    let response = await runtime.execute(document: testCase.document)

    let error = try #require(response.errors.first, "\(testCase.name)")
    #expect(error.code == .authorizationFailed, "\(testCase.name)")
    #expect(error.capabilityID == testCase.definition.id)
    #expect(error.exitCode == .credential)
  }

  @Test("Every reader capability rejects a malformed envelope", arguments: ReaderCases.all)
  func rejectsMalformedEnvelope(testCase: ReaderCase) async throws {
    let transport = RecordingTransport.succeeding(json: "{\"kind\":\"\(testCase.responseKind)\"}")
    let runtime = try ReaderCases.runtime(transport: transport)
    let response = await runtime.execute(document: testCase.document)

    let error = try #require(response.errors.first, "\(testCase.name)")
    #expect(error.code == .upstreamResponseInvalid, "\(testCase.name)")
  }

  @Test(
    "The typed SDK and GraphQL select the same plan for every reader capability",
    arguments: ReaderCases.all
  )
  func sdkGraphQLParity(testCase: ReaderCase) throws {
    let planner = CapabilityPlanner(registry: try ReadCapabilities.registry())
    let comparison = try ParityHarness.compare(
      planner: planner,
      invocation: CapabilityInvocation(
        capabilityID: testCase.definition.id,
        arguments: testCase.arguments
      ),
      document: testCase.document
    )
    #expect(comparison.isEquivalent, "\(testCase.name): \(comparison.summary)")
    #expect(comparison.sdkPlan?.request.method == .get)
  }
}

@Suite("Reader registry coherence")
struct ReaderRegistryCoherenceTests {
  @Test("Every registered field resolves back to its capability id")
  func bidirectionalCoherence() throws {
    let registry = try ReadCapabilities.registry()
    #expect(registry.coherenceProblems().isEmpty)
  }

  @Test("The reader registry contains only GET-backed read capabilities")
  func readOnly() throws {
    let registry = try ReadCapabilities.registry()
    #expect(!registry.definitions.isEmpty)
    for definition in registry.definitions {
      #expect(definition.method == .get, "\(definition.id) must use GET")
      #expect(definition.operationClass == .read, "\(definition.id) must be a read")
      #expect(definition.tier == .reader, "\(definition.id) must be reader tier")
      #expect(!definition.isDestructive)
    }
    #expect(registry.mutationDefinitions.isEmpty)
  }

  @Test("All twelve reviewed resource areas are covered")
  func coversResourceAreas() throws {
    let registry = try ReadCapabilities.registry()
    let namespaces = Set(registry.definitions.map(\.id.namespace))
    #expect(namespaces == ReadCapabilities.resourceNamespaces)
  }

  @Test("Folder and project intents remain distinct capabilities")
  func folderProjectDistinction() throws {
    let registry = try ReadCapabilities.registry()
    let folder = try #require(registry.definition(for: CapabilityID("folders.get")))
    let project = try #require(registry.definition(for: CapabilityID("projects.get")))

    #expect(folder.field == "folder")
    #expect(project.field == "project")
    #expect(folder.id != project.id)
    // They intentionally share the upstream family without exposing it.
    #expect(folder.pathTemplate == "/folders/{folderId}")
    #expect(project.pathTemplate == "/folders/{projectId}")
  }

  @Test("No public users collection alias is registered")
  func noUsersCollection() throws {
    let registry = try ReadCapabilities.registry()
    #expect(registry.definition(field: "users", isMutation: false) == nil)
    #expect(registry.definition(for: CapabilityID("users.list")) == nil)
    // Account people remain reachable through filtered contacts.
    #expect(registry.definition(field: "contacts", isMutation: false) != nil)
  }

  @Test("workflows.get is not registered because no upstream GET exists")
  func workflowsGetIsUnsupported() throws {
    let registry = try ReadCapabilities.registry()
    #expect(registry.definition(for: CapabilityID("workflows.get")) == nil)
    #expect(registry.definition(field: "workflow", isMutation: false) == nil)
    #expect(registry.definition(for: CapabilityID("workflows.list")) != nil)
  }

  @Test("Only capabilities with a documented page limit are connections")
  func paginationIsExplicit() throws {
    let registry = try ReadCapabilities.registry()
    for definition in registry.definitions {
      if case .connection = definition.result {
        #expect(definition.maximumPageSize != nil, "\(definition.id)")
      }
    }
    #expect(TaskCapabilities.list.maximumPageSize == 1000)
    #expect(TimelogCapabilities.list.maximumPageSize == 1000)
    // Wrike documents no pagination on GET /contacts, so it is a plain list.
    #expect(ContactCapabilities.list.maximumPageSize == nil)
  }

  @Test("Every reader capability declares a recommended scope it accepts")
  func scopeMetadata() throws {
    for definition in try ReadCapabilities.registry().definitions {
      #expect(definition.scopes.accepted.contains(definition.scopes.recommended))
      #expect(!definition.scopes.accepted.isEmpty)
    }
  }

  @Test("Every reader capability is covered by a contract case")
  func everyCapabilityHasACase() throws {
    let registered = Set(try ReadCapabilities.registry().definitions.map(\.id))
    let covered = Set(ReaderCases.all.map(\.definition.id))
    #expect(registered == covered, "Uncovered: \(registered.subtracting(covered).map(\.rawValue))")
  }
}

@Suite("Reader scope handling")
struct ReaderScopeTests {
  @Test("An unsupported scope relation is rejected before transport")
  func rejectsUnsupportedScope() async throws {
    let transport = RecordingTransport.succeeding(json: "{}")
    let runtime = try ReaderCases.runtime(transport: transport)
    let response = await runtime.execute(
      document: "{ customFields(scope: {taskId: \"IEAAAAAAKQAB5FNY\"}) { id } }"
    )

    #expect(response.errors.first?.code == .validationError)
    #expect(await transport.requestCount == 0)
  }

  @Test("A scope selecting more than one relation is rejected")
  func rejectsAmbiguousScope() async throws {
    let transport = RecordingTransport.succeeding(json: "{}")
    let runtime = try ReaderCases.runtime(transport: transport)
    let response = await runtime.execute(
      document: "{ tasks(scope: {folderId: \"A\", spaceId: \"B\"}) { nodes { id } } }"
    )

    #expect(response.errors.first?.code == .validationError)
    #expect(await transport.requestCount == 0)
  }

  @Test("A task list scoped by space uses the space route")
  func scopesBySpace() async throws {
    let transport = RecordingTransport.succeeding(
      json: WrikeFixtures.envelope(kind: "tasks", data: WrikeFixtures.task)
    )
    let runtime = try ReaderCases.runtime(transport: transport)
    _ = await runtime.execute(document: "{ tasks(scope: {spaceId: \"IEAG\"}) { nodes { id } } }")

    #expect(try await transport.firstRequest().path == "/api/v4/spaces/IEAG/tasks")
  }

  @Test("An unscoped task list uses the account route")
  func defaultsToAccountScope() async throws {
    let transport = RecordingTransport.succeeding(
      json: WrikeFixtures.envelope(kind: "tasks", data: WrikeFixtures.task)
    )
    let runtime = try ReaderCases.runtime(transport: transport)
    _ = await runtime.execute(document: "{ tasks { nodes { id } } }")

    #expect(try await transport.firstRequest().path == "/api/v4/tasks")
  }

  @Test("An identifier over the supported length is rejected")
  func rejectsOversizedIdentifier() async throws {
    let transport = RecordingTransport.succeeding(json: "{}")
    let runtime = try ReaderCases.runtime(transport: transport)
    let oversized = String(repeating: "A", count: WrikeIdentifier.maximumLength + 1)
    let response = await runtime.execute(document: "{ task(id: \"\(oversized)\") { id } }")

    #expect(response.errors.first?.code == .validationError)
    #expect(await transport.requestCount == 0)
  }
}
