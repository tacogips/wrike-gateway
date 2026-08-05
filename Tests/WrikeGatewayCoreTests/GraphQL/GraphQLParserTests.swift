import Foundation
import Testing
import WrikeGatewayCore
import WrikeGatewayTestSupport

@Suite("GraphQL parser scope")
struct GraphQLParserScopeTests {
  private let parser = GraphQLParser()

  @Test("A single named query with variables parses")
  func parsesQuery() throws {
    let document = try parser.parse("""
      query Widget($id: ID!) { widget(id: $id) { id title } }
      """)
    #expect(document.operation.type == .query)
    #expect(document.operation.name == "Widget")
    #expect(document.operation.variableDefinitions.map(\.name) == ["id"])
    #expect(document.operation.selections.first?.name == "widget")
    #expect(document.operation.selections.first?.selections.map(\.name) == ["id", "title"])
  }

  @Test("An anonymous shorthand selection set parses as a query")
  func parsesShorthand() throws {
    let document = try parser.parse("{ account { id name } }")
    #expect(document.operation.type == .query)
    #expect(document.operation.name == nil)
  }

  @Test("Enum values stay distinct from strings")
  func parsesEnumValues() throws {
    let document = try parser.parse("{ tasks(status: Completed) { nodes { id } } }")
    let argument = document.operation.selections.first?.arguments["status"]
    #expect(argument == .enumeration("Completed"))
    #expect(argument != .string("Completed"))
  }

  /// Wrike titles and comments carry real text, so a string argument has to
  /// survive escaping intact. A character outside the basic multilingual plane
  /// is expressed as a surrogate pair, which is only meaningful when both
  /// halves are read together.
  @Test("String escapes decode, including a surrogate pair")
  func decodesStringEscapes() throws {
    // A raw Swift literal, so every backslash below reaches the lexer as the
    // escape the GraphQL document actually contains rather than one Swift has
    // already decoded.
    let document = try parser.parse(
      #"{ task(id: "a\tb\"c\\d\u0041\u00E9\uD83D\uDE00z") { id } }"#
    )
    let argument = document.operation.selections.first?.arguments["id"]
    // The last two escapes are one surrogate pair and must decode to the single
    // scalar they name, not to two unpaired halves.
    #expect(argument == .string("a\tb\"c\\dA\u{E9}\u{1F600}z"))
  }

  struct MalformedEscape: Sendable, CustomTestStringConvertible {
    let name: String
    let document: String
    var testDescription: String { name }
  }

  /// A half-formed surrogate is still malformed. Accepting one would put an
  /// unpaired scalar into an upstream request.
  @Test(
    "A malformed unicode escape is rejected",
    arguments: [
      MalformedEscape(name: "lone high surrogate", document: #"{ task(id: "\uD83D") { id } }"#),
      MalformedEscape(name: "lone low surrogate", document: #"{ task(id: "\uDE00") { id } }"#),
      MalformedEscape(
        name: "high surrogate followed by a plain escape",
        document: #"{ task(id: "\uD83D\n") { id } }"#
      ),
      MalformedEscape(
        name: "high surrogate followed by a non-surrogate",
        document: #"{ task(id: "\uD83DA") { id } }"#
      ),
      MalformedEscape(name: "truncated escape", document: #"{ task(id: "\u12") { id } }"#),
      MalformedEscape(name: "non-hex escape", document: #"{ task(id: "\uZZZZ") { id } }"#)
    ]
  )
  func rejectsMalformedUnicodeEscape(testCase: MalformedEscape) throws {
    #expect(throws: GatewayError.self, "\(testCase.name) must be rejected") {
      _ = try self.parser.parse(testCase.document)
    }
  }

  /// A document using syntax outside the constrained subset.
  struct UnsupportedDocument: Sendable, CustomTestStringConvertible {
    let name: String
    let document: String

    var testDescription: String { name }
  }

  static let unsupportedDocuments: [UnsupportedDocument] = [
    .init(
      name: "fragment definition",
      document: "fragment F on Task { id } query { task(id: \"1\") { ...F } }"
    ),
    .init(name: "fragment spread", document: "{ task(id: \"1\") { ...Fields } }"),
    .init(name: "directive", document: "{ task(id: \"1\") @include(if: true) { id } }"),
    .init(name: "alias", document: "{ renamed: task(id: \"1\") { id } }"),
    .init(name: "subscription", document: "subscription { task(id: \"1\") { id } }"),
    .init(name: "two operations", document: "query A { account { id } } query B { account { id } }"),
    .init(name: "empty document", document: "   "),
    .init(name: "unterminated selection", document: "{ task(id: \"1\") { id "),
    .init(name: "duplicate field", document: "{ account { id id } }"),
    .init(name: "duplicate argument", document: "{ task(id: \"1\", id: \"2\") { id } }"),
    .init(name: "default variable value", document: "query Q($a: ID! = \"x\") { task(id: $a) { id } }"),
    .init(name: "block string", document: "{ task(id: \"\"\"x\"\"\") { id } }")
  ]

  @Test("Unsupported syntax is rejected", arguments: unsupportedDocuments)
  func rejectsUnsupportedSyntax(testCase: UnsupportedDocument) throws {
    #expect(throws: GatewayError.self, "\(testCase.name) must be rejected") {
      _ = try self.parser.parse(testCase.document)
    }
  }

  @Test("A mutation document must contain exactly one top-level field")
  func mutationsAreSingleField() throws {
    #expect(throws: GatewayError.self) {
      _ = try self.parser.parse("""
        mutation { createWidget(input: {title: "A"}) { widget { id } }
                   createWidget2(input: {title: "B"}) { widget { id } } }
        """)
    }
  }

  @Test("Selection depth and top-level field count are bounded")
  func boundedDocuments() throws {
    let deep = String(repeating: "{ a ", count: 12) + String(repeating: "}", count: 12)
    #expect(throws: GatewayError.self) { _ = try self.parser.parse(deep) }

    let wide = "{ " + (1...12).map { "f\($0) { id }" }.joined(separator: " ") + " }"
    #expect(throws: GatewayError.self) { _ = try self.parser.parse(wide) }
  }

  @Test("An oversized document is rejected on length alone")
  func rejectsOversizedDocument() throws {
    let padding = String(repeating: " ", count: GraphQLParser.maximumDocumentLength + 1)
    #expect(throws: GatewayError.self) {
      _ = try self.parser.parse("{ account { id } }" + padding)
    }
  }
}

@Suite("GraphQL local validation happens before network access")
struct GraphQLPreNetworkValidationTests {
  private func runtime(transport: RecordingTransport) throws -> GraphQLRuntime {
    let registry = try CapabilityRegistry(
      tier: .writer,
      definitions: [
        TransportTestCapabilities.get,
        TransportTestCapabilities.list,
        TransportTestCapabilities.create
      ]
    )
    return GraphQLRuntime(
      executor: CapabilityExecutor(
        planner: CapabilityPlanner(registry: registry),
        transport: transport,
        credentials: StubCredentialProvider(),
        requestIDFactory: { "fixed" }
      ),
      requestIDFactory: { "fixed-request-id" }
    )
  }

  /// A document that must be rejected locally, with the code it must produce.
  struct RejectedDocument: Sendable, CustomTestStringConvertible {
    let name: String
    let document: String
    let code: GatewayErrorCode

    var testDescription: String { name }
  }

  static let rejectedDocuments: [RejectedDocument] = [
    .init(name: "unknown field", document: "{ notAField { id } }", code: .validationError),
    .init(
      name: "unknown argument",
      document: "{ widget(id: \"1\", bogus: 1) { id } }",
      code: .validationError
    ),
    .init(name: "missing required argument", document: "{ widget { id } }", code: .validationError),
    .init(
      name: "unknown selection",
      document: "{ widget(id: \"1\") { id nope } }",
      code: .validationError
    ),
    .init(
      name: "scalar with selection",
      document: "{ widget(id: \"1\") { id { x } } }",
      code: .validationError
    ),
    .init(name: "missing selection set", document: "{ widget(id: \"1\") }", code: .validationError),
    .init(name: "wrong argument type", document: "{ widget(id: 42) { id } }", code: .validationError),
    .init(
      name: "undeclared variable",
      document: "{ widget(id: $missing) { id } }",
      code: .validationError
    ),
    .init(name: "empty identifier", document: "{ widget(id: \"\") { id } }", code: .validationError),
    .init(
      name: "unsupported page field",
      document: "{ widgets(page: {limit: 1}) { nodes { id } } }",
      code: .validationError
    )
  ]

  @Test("Invalid documents fail with no transport request", arguments: rejectedDocuments)
  func failsBeforeTransport(testCase: RejectedDocument) async throws {
    let name = testCase.name
    let transport = RecordingTransport.succeeding(json: "{}")
    let response = try await runtime(transport: transport).execute(document: testCase.document)

    #expect(response.errors.first?.code == testCase.code, "\(name)")
    #expect(response.data == nil)
    #expect(await transport.requestCount == 0, "\(name) must not reach the network")
  }

  /// A credential provider that fails the way an unconfigured machine does.
  private struct UnconfiguredCredentials: CredentialProvider {
    let attempts: Counter

    func credential() async throws -> ResolvedCredential {
      attempts.increment()
      throw GatewayError.authentication("No Wrike credential is available.")
    }

    func refreshedCredential(after stale: ResolvedCredential) async throws -> ResolvedCredential? {
      nil
    }
  }

  @Test(
    "Argument validation fails before any credential is resolved",
    arguments: [
      "{ widget(id: \"\") { id } }",
      "{ widget(id: 42) { id } }",
      "{ widgets(page: {pageSize: 100000}) { nodes { id } } }",
      "{ widget(id: \"1\", bogus: 1) { id } }"
    ]
  )
  func validationPrecedesCredentialResolution(document: String) async throws {
    let attempts = Counter()
    let transport = RecordingTransport.succeeding(json: "{}")
    let registry = try CapabilityRegistry(
      tier: .writer,
      definitions: [
        TransportTestCapabilities.get,
        TransportTestCapabilities.list,
        TransportTestCapabilities.create
      ]
    )
    let runtime = GraphQLRuntime(
      executor: CapabilityExecutor(
        planner: CapabilityPlanner(registry: registry),
        transport: transport,
        credentials: UnconfiguredCredentials(attempts: attempts)
      )
    )

    let response = await runtime.execute(document: document)
    let error = try #require(response.errors.first)
    #expect(
      error.code == .validationError,
      "Expected VALIDATION_ERROR, not \(error.code.rawValue), for \(document)"
    )
    #expect(error.exitCode == .usage)
    #expect(attempts.count == 0, "No credential may be resolved for an invalid argument")
    #expect(await transport.requestCount == 0)
  }

  @Test("A scope mismatch is still reported once a credential exists")
  func scopeCheckStillRuns() async throws {
    let transport = RecordingTransport.succeeding(json: "{}")
    let registry = try CapabilityRegistry(
      tier: .reader,
      definitions: [TransportTestCapabilities.get]
    )
    let runtime = GraphQLRuntime(
      executor: CapabilityExecutor(
        planner: CapabilityPlanner(registry: registry),
        transport: transport,
        credentials: StubCredentialProvider(grantedScopes: ["amReadOnlyUser"])
      )
    )

    let response = await runtime.execute(document: "{ widget(id: \"W1\") { id } }")
    #expect(response.errors.first?.code == .authorizationFailed)
    #expect(await transport.requestCount == 0)
  }

  @Test("A declared but unused variable is rejected")
  func rejectsUnusedVariable() async throws {
    let transport = RecordingTransport.succeeding(json: "{}")
    let response = try await runtime(transport: transport)
      .execute(document: "query Q($unused: ID!) { account { id } }", variables: ["unused": .string("x")])
    #expect(response.errors.first?.code == .validationError)
    #expect(await transport.requestCount == 0)
  }

  @Test("A supplied but undeclared variable is rejected")
  func rejectsUndeclaredVariable() async throws {
    let transport = RecordingTransport.succeeding(json: "{}")
    let response = try await runtime(transport: transport)
      .execute(document: "{ widget(id: \"1\") { id } }", variables: ["extra": .string("x")])
    #expect(response.errors.first?.code == .validationError)
    #expect(await transport.requestCount == 0)
  }

  /// The same rejected document must produce the same message every run. The
  /// offending names are collected in a set, whose iteration order varies
  /// between processes, so the report is sorted before one name is chosen.
  @Test("A document with several offending variables always names the same one")
  func variableRejectionIsDeterministic() async throws {
    let transport = RecordingTransport.succeeding(json: "{}")
    let executed = try runtime(transport: transport)
    for _ in 0..<8 {
      let response = await executed.execute(
        document: "query Q($zeta: ID!, $alpha: ID!, $mid: ID!) { account { id } }",
        variables: ["zeta": .string("z"), "alpha": .string("a"), "mid": .string("m")]
      )
      let error = try #require(response.errors.first)
      #expect(error.code == .validationError)
      #expect(error.message.contains("$alpha"), "the first name in sorted order must be reported")
    }
    #expect(await transport.requestCount == 0)
  }

  @Test("A missing required variable is rejected")
  func rejectsMissingRequiredVariable() async throws {
    let transport = RecordingTransport.succeeding(json: "{}")
    let response = try await runtime(transport: transport)
      .execute(document: "query Q($id: ID!) { widget(id: $id) { id } }")
    #expect(response.errors.first?.code == .validationError)
    #expect(await transport.requestCount == 0)
  }

  @Test("A mutation field is denied in a reader registry with the required tier named")
  func deniesMutationInReader() async throws {
    let transport = RecordingTransport.succeeding(json: "{}")
    let registry = try CapabilityRegistry(tier: .reader, definitions: [TransportTestCapabilities.get])
    let runtime = GraphQLRuntime(
      executor: CapabilityExecutor(
        planner: CapabilityPlanner(registry: registry),
        transport: transport,
        credentials: StubCredentialProvider()
      )
    )

    let response = await runtime.execute(
      document: "mutation { deleteTask(input: {taskId: \"1\"}) { deletedId } }"
    )
    let error = try #require(response.errors.first)
    #expect(error.code == .capabilityDenied)
    #expect(error.requiredTier == .admin)
    #expect(error.exitCode == .usage)
    #expect(await transport.requestCount == 0)
  }
}

@Suite("GraphQL execution and projection")
struct GraphQLExecutionTests {
  private func runtime(transport: RecordingTransport) throws -> GraphQLRuntime {
    let registry = try CapabilityRegistry(
      tier: .writer,
      definitions: [
        TransportTestCapabilities.get,
        TransportTestCapabilities.list,
        TransportTestCapabilities.create
      ]
    )
    return GraphQLRuntime(
      executor: CapabilityExecutor(
        planner: CapabilityPlanner(registry: registry),
        transport: transport,
        credentials: StubCredentialProvider()
      ),
      requestIDFactory: { "fixed-request-id" }
    )
  }

  @Test("The response contains only the selected fields")
  func projectsSelection() async throws {
    let transport = RecordingTransport.succeeding(
      json: WrikeFixtures.envelope(kind: "widgets", data: "{\"id\":\"W1\",\"title\":\"One\"}")
    )
    let response = try await runtime(transport: transport)
      .execute(document: "{ widget(id: \"W1\") { id } }")

    let widget = try #require(response.data?["widget"]?.objectValue)
    #expect(widget["id"] == .string("W1"))
    #expect(widget["title"] == nil, "An unselected field must not be returned")
    #expect(response.exitCode == .success)
  }

  @Test("The envelope always carries a request id")
  func envelopeShape() async throws {
    let transport = RecordingTransport.succeeding(
      json: WrikeFixtures.envelope(kind: "widgets", data: "{\"id\":\"W1\"}")
    )
    let response = try await runtime(transport: transport)
      .execute(document: "{ widget(id: \"W1\") { id } }")
    let rendered = response.rendered(pretty: false)
    #expect(rendered.contains("\"requestId\":\"fixed-request-id\""))
    #expect(rendered.contains("\"data\":"))
  }

  @Test("Independent top-level query fields may produce partial data")
  func partialData() async throws {
    let transport = RecordingTransport(
      outcomes: [
        .response(WrikeResponse(
          statusCode: 200,
          body: Data(WrikeFixtures.envelope(kind: "widgets", data: "{\"id\":\"W1\"}").utf8)
        )),
        .response(WrikeResponse(statusCode: 404, body: Data(WrikeFixtures.errorBody.utf8)))
      ],
      repeatsFinalOutcome: false
    )
    let response = try await runtime(transport: transport).execute(
      document: "{ widget(id: \"W1\") { id } widgets { nodes { id } } }"
    )

    #expect(response.data?["widget"]?["id"]?.stringValue == "W1")
    #expect(response.data?["widgets"] == .null)
    #expect(response.errors.count == 1)
    #expect(response.errors.first?.code == .notFound)
    #expect(response.exitCode == .rejectedRequest)
  }

  @Test("Variables supply argument values")
  func resolvesVariables() async throws {
    let transport = RecordingTransport.succeeding(
      json: WrikeFixtures.envelope(kind: "widgets", data: "{\"id\":\"W9\"}")
    )
    let response = try await runtime(transport: transport).execute(
      document: "query Q($id: ID!) { widget(id: $id) { id } }",
      variables: ["id": .string("W9")]
    )
    #expect(response.data?["widget"]?["id"]?.stringValue == "W9")
    #expect(try await transport.firstRequest().path.hasSuffix("/widgets/W9"))
  }

  @Test("Pretty output changes whitespace only")
  func prettyChangesWhitespaceOnly() async throws {
    let transport = RecordingTransport.succeeding(
      json: WrikeFixtures.envelope(kind: "widgets", data: "{\"id\":\"W1\",\"title\":\"One\"}")
    )
    let runtime = try runtime(transport: transport)
    let compact = await runtime.execute(document: "{ widget(id: \"W1\") { id title } }")
      .rendered(pretty: false)
    let pretty = await runtime.execute(document: "{ widget(id: \"W1\") { id title } }")
      .rendered(pretty: true)

    #expect(pretty.contains("\n"))
    #expect(pretty.filter { !$0.isWhitespace } == compact.filter { !$0.isWhitespace })
  }
}

@Suite("Schema printing")
struct SchemaPrintingTests {
  @Test("The printed schema is derived from the linked registry")
  func printsLinkedFieldsOnly() throws {
    let readerOnly = try CapabilityRegistry(
      tier: .reader,
      definitions: [TransportTestCapabilities.get, TransportTestCapabilities.list]
    )
    let schema = GraphQLSchemaPrinter(registry: readerOnly).print()

    #expect(schema.contains("type Query {"))
    #expect(!schema.contains("type Mutation {"))
    #expect(schema.contains("widget(id: ID!): Widget"))
    #expect(schema.contains("type WidgetConnection {"))
    #expect(schema.contains("Capability: widgets.get"))
    #expect(!schema.contains("createWidget"))
  }

  @Test("A destructive field is labelled in the schema")
  func labelsDestructiveFields() throws {
    let delete = CapabilityDefinition(
      id: CapabilityID("widgets.delete"),
      field: "deleteWidget",
      tier: .admin,
      operationClass: .delete,
      method: .delete,
      pathTemplate: "/widgets/{widgetId}",
      arguments: [
        ArgumentDefinition(
          "input",
          .inputObject(InputObjectShape(
            typeName: "DeleteWidgetInput",
            fields: [ArgumentDefinition("widgetId", .identifier, .path("widgetId"), required: true)]
          )),
          .container,
          required: true
        )
      ],
      result: .deletion,
      scopes: .workspaceReadWrite,
      summary: "Deletes one widget."
    )
    let registry = try CapabilityRegistry(tier: .admin, definitions: [delete])
    let schema = GraphQLSchemaPrinter(registry: registry).print()

    #expect(schema.contains("DESTRUCTIVE."))
    #expect(schema.contains("type DeletionPayload {"))
    #expect(schema.contains("deleteWidget(input: DeleteWidgetInput!): DeletionPayload"))
  }
}
