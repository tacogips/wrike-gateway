import Foundation
import Testing
import WrikeGatewayAdmin
import WrikeGatewayCore
import WrikeGatewayRead
import WrikeGatewayTestSupport
import WrikeGatewayWrite

/// Drives the shared command frame with injected seams, covering the argument
/// grammar, file inputs, JSON envelopes, and exit codes without spawning a
/// process. `BinaryBoundaryTests` covers the real binaries.
private enum FrameHarness {
  static func make(
    role: RoleDescriptor,
    definitions: [CapabilityDefinition],
    transport: RecordingTransport,
    files: [String: String] = [:],
    store: any CredentialStore = InMemoryCredentialStore(),
    environment: StaticEnvironmentReader = StaticEnvironmentReader()
  ) throws -> CommandFrame {
    let registry = try CapabilityRegistry(tier: role.tier, definitions: definitions)
    let resolver = CredentialResolver(
      environment: environment,
      store: store,
      clock: TestClock()
    )
    let runtime = GraphQLRuntime(
      executor: CapabilityExecutor(
        planner: CapabilityPlanner(registry: registry),
        transport: transport,
        credentials: StubCredentialProvider(),
        clock: TestClock()
      ),
      requestIDFactory: { "fixed-request-id" }
    )
    let auth = AuthCommands(
      resolver: resolver,
      environment: environment,
      makeLoginFlow: { _, _ in nil }
    )
    return CommandFrame(
      role: role,
      runtime: runtime,
      authCommands: auth,
      readFile: { path in
        guard let contents = files[path] else {
          throw GatewayError(
            code: .fileOperationFailed,
            message: "The file at the supplied path could not be read."
          )
        }
        return Data(contents.utf8)
      }
    )
  }

  static func reader(
    transport: RecordingTransport,
    files: [String: String] = [:],
    store: any CredentialStore = InMemoryCredentialStore(),
    environment: StaticEnvironmentReader = StaticEnvironmentReader()
  ) throws -> CommandFrame {
    try make(
      role: .reader,
      definitions: ReadCapabilities.all,
      transport: transport,
      files: files,
      store: store,
      environment: environment
    )
  }
}

/// A credential store whose backend is unavailable, standing in for a kinko
/// vault that cannot be opened or answers in a way the store does not
/// recognise.
private struct UnavailableCredentialStore: CredentialStore {
  static let failure = GatewayError(
    code: .fileOperationFailed,
    message: "The credential store could not be opened.",
    recoveryGuidance: "Run `kinko unlock` (or `kinko init` if no vault exists yet), then retry."
  )

  func load(_ key: CredentialRecordKey) async throws -> OAuthTokenState? { throw Self.failure }
  func replace(_ state: OAuthTokenState, for key: CredentialRecordKey) async throws { throw Self.failure }
  func delete(_ key: CredentialRecordKey) async throws -> Bool { throw Self.failure }
  func hasRecord(_ key: CredentialRecordKey) async throws -> Bool { throw Self.failure }
}

@Suite("Reader command end to end")
struct ReaderCommandEndToEndTests {
  private func taskTransport() -> RecordingTransport {
    RecordingTransport.succeeding(
      json: WrikeFixtures.envelope(kind: "tasks", data: WrikeFixtures.task)
    )
  }

  @Test("An inline query returns the documented JSON envelope and exit 0")
  func inlineQuery() async throws {
    let frame = try FrameHarness.reader(transport: taskTransport())
    let outcome = await frame.run(arguments: [
      "graphql", "query", "{ task(id: \"IEAAAAAAKQAB5FNY\") { id title } }"
    ])

    #expect(outcome.exitCode == .success)
    #expect(outcome.standardError.isEmpty)
    #expect(outcome.standardOutput.contains("\"title\":\"Prepare launch\""))
    #expect(outcome.standardOutput.contains("\"requestId\":\"fixed-request-id\""))
    #expect(outcome.standardOutput.hasSuffix("\n"))
  }

  @Test("A query file with a variables file executes the same way")
  func queryFileWithVariables() async throws {
    let frame = try FrameHarness.reader(
      transport: taskTransport(),
      files: [
        "/tmp/query.graphql": "query T($id: ID!) { task(id: $id) { id title } }",
        "/tmp/vars.json": "{\"id\": \"IEAAAAAAKQAB5FNY\"}"
      ]
    )
    let outcome = await frame.run(arguments: [
      "graphql", "query-file", "/tmp/query.graphql", "--variables-file", "/tmp/vars.json"
    ])

    #expect(outcome.exitCode == .success)
    #expect(outcome.standardOutput.contains("\"id\":\"IEAAAAAAKQAB5FNY\""))
  }

  @Test("A missing query file exits 6")
  func missingQueryFile() async throws {
    let frame = try FrameHarness.reader(transport: taskTransport())
    let outcome = await frame.run(arguments: ["graphql", "query-file", "/tmp/absent.graphql"])

    #expect(outcome.exitCode == .localResource)
    #expect(outcome.standardError.contains("FILE_OPERATION_FAILED"))
  }

  @Test("Malformed variables JSON exits 2")
  func malformedVariables() async throws {
    let frame = try FrameHarness.reader(transport: taskTransport())
    let outcome = await frame.run(arguments: [
      "graphql", "query", "{ account { id } }", "--variables", "not-json"
    ])

    #expect(outcome.exitCode == .usage)
    #expect(outcome.standardError.contains("VALIDATION_ERROR"))
  }

  @Test("Pretty output is indented JSON with the same content")
  func prettyOutput() async throws {
    let frame = try FrameHarness.reader(transport: taskTransport())
    let compact = await frame.run(arguments: [
      "graphql", "query", "{ task(id: \"IEAAAAAAKQAB5FNY\") { id } }"
    ])
    let pretty = await frame.run(arguments: [
      "--pretty", "graphql", "query", "{ task(id: \"IEAAAAAAKQAB5FNY\") { id } }"
    ])

    #expect(pretty.standardOutput.contains("\n  "))
    #expect(
      pretty.standardOutput.filter { !$0.isWhitespace }
        == compact.standardOutput.filter { !$0.isWhitespace }
    )
  }

  @Test("Multiple bounded top-level reads execute in one document")
  func multipleTopLevelReads() async throws {
    let transport = RecordingTransport(
      outcomes: [
        .response(WrikeResponse(
          statusCode: 200,
          body: Data(WrikeFixtures.envelope(kind: "tasks", data: WrikeFixtures.task).utf8)
        )),
        .response(WrikeResponse(
          statusCode: 200,
          body: Data(WrikeFixtures.envelope(kind: "folders", data: WrikeFixtures.folder).utf8)
        ))
      ],
      repeatsFinalOutcome: false
    )
    let frame = try FrameHarness.reader(transport: transport)
    let outcome = await frame.run(arguments: [
      "graphql", "query",
      "{ task(id: \"IEAAAAAAKQAB5FNY\") { id } folder(id: \"IEAAAAAAI4AB5FNY\") { id } }"
    ])

    #expect(outcome.exitCode == .success)
    #expect(outcome.standardOutput.contains("\"task\""))
    #expect(outcome.standardOutput.contains("\"folder\""))
    #expect(await transport.requestCount == 2)
  }

  @Test("An upstream error uses the stable envelope and maps to its exit code")
  func upstreamErrorEnvelope() async throws {
    let transport = RecordingTransport(outcomes: [
      .response(WrikeResponse(statusCode: 404, body: Data(WrikeFixtures.errorBody.utf8)))
    ])
    let frame = try FrameHarness.reader(transport: transport)
    let outcome = await frame.run(arguments: [
      "graphql", "query", "{ task(id: \"IEAAAAAAKQAB5FNY\") { id } }"
    ])

    #expect(outcome.exitCode == .rejectedRequest)
    #expect(outcome.standardOutput.contains("\"code\":\"NOT_FOUND\""))
    #expect(outcome.standardOutput.contains("\"data\":null"))
    #expect(outcome.standardOutput.contains("\"capabilityId\":\"tasks.get\""))
  }

  @Test("graphql schema prints the reader schema and exits 0")
  func schemaCommand() async throws {
    let frame = try FrameHarness.reader(transport: taskTransport())
    let outcome = await frame.run(arguments: ["graphql", "schema"])

    #expect(outcome.exitCode == .success)
    #expect(outcome.standardOutput.contains("type Query {"))
    #expect(!outcome.standardOutput.contains("type Mutation {"))
  }

  @Test("auth status reports no credential without inventing one, and no identity field")
  func authStatusWithoutCredential() async throws {
    let frame = try FrameHarness.reader(transport: taskTransport())
    let outcome = await frame.run(arguments: ["auth", "status"])

    #expect(outcome.exitCode == .success)
    #expect(outcome.standardOutput.contains("\"mode\":null"))
    // Deliberate contract change: the callback is plain HTTP on loopback, so
    // there is no TLS identity and the field no longer exists.
    #expect(!outcome.standardOutput.contains("callbackIdentityAvailable"))
    #expect(!outcome.standardOutput.lowercased().contains("identity"))
  }

  @Test("auth status reports permanent-token mode without reading the token")
  func authStatusPermanentToken() async throws {
    let frame = try FrameHarness.reader(
      transport: taskTransport(),
      environment: StaticEnvironmentReader([
        .accessToken: "FAKE-STATUS-TOKEN-do-not-log",
        .apiBaseURL: "https://app-us2.wrike.com/api/v4"
      ])
    )
    let outcome = await frame.run(arguments: ["auth", "status"])

    #expect(outcome.exitCode == .success)
    #expect(outcome.standardOutput.contains("\"mode\":\"permanentToken\""))
    #expect(outcome.standardOutput.contains("\"host\":\"app-us2.wrike.com\""))
    #expect(!outcome.standardOutput.contains("FAKE-STATUS-TOKEN"))
  }

  @Test("auth status fails loudly when the credential store cannot answer")
  func authStatusSurfacesStoreFailure() async throws {
    // The failure this covers is misreporting an unreadable store as an empty
    // one: `mode: null` with exit 0 tells an operator to run `auth oauth2` and
    // burn a fresh authorization on a vault that already holds a valid,
    // rotatable refresh token, when the fix is `kinko unlock`.
    let frame = try FrameHarness.reader(
      transport: taskTransport(),
      store: UnavailableCredentialStore(),
      environment: StaticEnvironmentReader([
        .clientID: "fake-client-id",
        .clientSecret: "fake-client-secret"
      ])
    )
    let outcome = await frame.run(arguments: ["auth", "status"])

    #expect(outcome.exitCode == .localResource)
    #expect(outcome.standardOutput.contains("FILE_OPERATION_FAILED"))
    #expect(outcome.standardOutput.contains("kinko unlock"))
    #expect(!outcome.standardOutput.contains("\"mode\":null"))
    #expect(!outcome.standardOutput.contains("\"refreshStateAvailable\":false"))
  }

  @Test("auth status reports a rejected permanent-token base URL instead of a null host")
  func authStatusSurfacesInvalidBaseURL() async throws {
    // Permanent-token mode has no host default, so a missing or rejected base
    // URL makes every later query fail. Status names it here rather than
    // reporting a usable-looking `permanentToken` mode with a null host.
    let frame = try FrameHarness.reader(
      transport: taskTransport(),
      environment: StaticEnvironmentReader([
        .accessToken: "FAKE-STATUS-TOKEN-do-not-log"
      ])
    )
    let outcome = await frame.run(arguments: ["auth", "status"])

    #expect(outcome.exitCode == .credential)
    #expect(outcome.standardOutput.contains("AUTHENTICATION_FAILED"))
    #expect(outcome.standardOutput.contains(GatewayEnvironmentKey.apiBaseURL.rawValue))
    #expect(!outcome.standardOutput.contains("\"mode\":\"permanentToken\""))
    #expect(!outcome.standardOutput.contains("FAKE-STATUS-TOKEN"))
  }

  @Test("auth logout reports whether a local record was removed")
  func authLogout() async throws {
    let frame = try FrameHarness.reader(transport: taskTransport())
    let outcome = await frame.run(arguments: ["auth", "logout"])

    #expect(outcome.exitCode == .success)
    #expect(outcome.standardOutput.contains("\"removedLocalRecord\":false"))
  }

  @Test("auth logout fails loudly when the credential store cannot answer")
  func authLogoutSurfacesStoreFailure() async throws {
    // The failure this covers is silent success: reporting
    // `removedLocalRecord: false` with exit 0 tells an operator there was
    // nothing to remove while the refresh token is still stored.
    let frame = try FrameHarness.reader(
      transport: taskTransport(),
      store: UnavailableCredentialStore(),
      environment: StaticEnvironmentReader([
        .clientID: "fake-client-id",
        .clientSecret: "fake-client-secret"
      ])
    )
    let outcome = await frame.run(arguments: ["auth", "logout"])

    #expect(outcome.exitCode == .localResource)
    #expect(outcome.standardOutput.contains("FILE_OPERATION_FAILED"))
    #expect(outcome.standardOutput.contains("kinko unlock"))
    #expect(!outcome.standardOutput.contains("removedLocalRecord"))
  }

  @Test("auth oauth2 without client configuration exits 3 with safe guidance")
  func authLoginWithoutClient() async throws {
    let frame = try FrameHarness.reader(transport: taskTransport())
    let outcome = await frame.run(arguments: ["auth", "oauth2"])

    #expect(outcome.exitCode == .credential)
    #expect(outcome.standardOutput.contains("AUTHENTICATION_FAILED"))
    #expect(outcome.standardOutput.contains("WRIKE_GATEWAY_API_CLIENT_ID"))
  }
}

@Suite("Writer and admin command end to end")
struct WriterAdminCommandEndToEndTests {
  @Test("The writer executes a create mutation end to end")
  func writerCreate() async throws {
    let transport = RecordingTransport.succeeding(
      json: WrikeFixtures.envelope(kind: "tasks", data: WrikeFixtures.task)
    )
    let frame = try FrameHarness.make(
      role: .writer,
      definitions: WriteCapabilities.all,
      transport: transport
    )
    let outcome = await frame.run(arguments: [
      "graphql", "query",
      """
      mutation { createTask(input: {folderId: "IEAAAAAAI4AB5FNY", title: "Prepare launch"}) \
      { task { id title } } }
      """
    ])

    #expect(outcome.exitCode == .success)
    #expect(outcome.standardOutput.contains("\"createTask\""))
    #expect(try await transport.firstRequest().method == .post)
  }

  @Test("The admin executes a delete mutation end to end")
  func adminDelete() async throws {
    let transport = RecordingTransport.succeeding(
      json: "{\"kind\":\"ids\",\"data\":[\"IEAAAAAAKQAB5FNY\"]}"
    )
    let frame = try FrameHarness.make(
      role: .admin,
      definitions: AdminCapabilities.all,
      transport: transport
    )
    let outcome = await frame.run(arguments: [
      "graphql", "query",
      "mutation { deleteTask(input: {taskId: \"IEAAAAAAKQAB5FNY\"}) { deletedId } }"
    ])

    #expect(outcome.exitCode == .success)
    #expect(outcome.standardOutput.contains("\"deletedId\":\"IEAAAAAAKQAB5FNY\""))
    #expect(try await transport.firstRequest().method == .delete)
  }

  @Test("The same read query works in all three tiers")
  func cumulativeReadAcrossTiers() async throws {
    let roles: [(RoleDescriptor, [CapabilityDefinition])] = [
      (.reader, ReadCapabilities.all),
      (.writer, WriteCapabilities.all),
      (.admin, AdminCapabilities.all)
    ]
    for (role, definitions) in roles {
      let transport = RecordingTransport.succeeding(
        json: WrikeFixtures.envelope(kind: "tasks", data: WrikeFixtures.task)
      )
      let frame = try FrameHarness.make(
        role: role,
        definitions: definitions,
        transport: transport
      )
      let outcome = await frame.run(arguments: [
        "graphql", "query", "{ task(id: \"IEAAAAAAKQAB5FNY\") { id title } }"
      ])

      #expect(outcome.exitCode == .success, "\(role.executableName)")
      #expect(
        outcome.standardOutput.contains("\"title\":\"Prepare launch\""),
        "\(role.executableName)"
      )
      #expect(try await transport.firstRequest().path == "/api/v4/tasks/IEAAAAAAKQAB5FNY")
    }
  }
}

@Suite("Typed SDK surface")
struct TypedSDKSurfaceTests {
  @Test("The reader SDK executes through the shared planner")
  func readerClient() async throws {
    let transport = RecordingTransport.succeeding(
      json: WrikeFixtures.envelope(kind: "tasks", data: WrikeFixtures.task)
    )
    let client = try WrikeReadClient(
      transport: transport,
      credentials: StubCredentialProvider(),
      clock: TestClock()
    )
    let task = try await client.task(id: "IEAAAAAAKQAB5FNY")

    #expect(task["title"]?.stringValue == "Prepare launch")
    #expect(try await transport.firstRequest().capabilityID == CapabilityID("tasks.get"))
  }

  @Test("The reader SDK builds the same history request the GraphQL field does")
  func readerClientHistory() async throws {
    let transport = RecordingTransport.succeeding(
      json: WrikeFixtures.envelope(kind: "tasksHistory", data: WrikeFixtures.tasksHistory)
    )
    let client = try WrikeReadClient(
      transport: transport,
      credentials: StubCredentialProvider(),
      clock: TestClock()
    )

    let history = try await client.tasksHistory(
      ids: ["IEAAAAAAKQAB5FNY", "IEAAAAAAKQAB5FNZ"],
      updatedDate: WrikeInstantRange(start: "2026-01-01T00:00:00Z"),
      fields: ["plannedCost"]
    )

    #expect(history.arrayValue?.first?["id"]?.stringValue == "IEAAAAAAKQAB5FNY")
    let recorded = try await transport.firstRequest()
    #expect(recorded.capabilityID == CapabilityID("tasks.history"))
    #expect(recorded.path == "/api/v4/tasks/IEAAAAAAKQAB5FNY,IEAAAAAAKQAB5FNZ/tasks_history")
    #expect(recorded.query["updatedDate"] == "{\"start\":\"2026-01-01T00:00:00Z\"}")
    #expect(recorded.query["fields"] == "[\"plannedCost\"]")
  }

  @Test("The reader SDK downloads through the same file sink the GraphQL field uses")
  func readerClientDownload() async throws {
    let directory = try TemporaryDirectory()
    let destination = directory.path("brief.pdf")
    let transport = RecordingTransport(outcomes: [
      .response(
        WrikeResponse(
          statusCode: 200,
          headers: ["Content-Type": "application/pdf"],
          body: Data("SDK-DOWNLOAD-BYTES".utf8)
        )
      )
    ])
    let client = try WrikeReadClient(
      transport: transport,
      credentials: StubCredentialProvider(),
      clock: TestClock()
    )

    let file = try await client.attachmentDownload(
      id: "IEAAAAAAIYAAAAAB",
      destination: destination
    )

    #expect(file["path"]?.stringValue == destination)
    #expect(file["byteCount"]?.intValue == 18)
    #expect(file["contentType"]?.stringValue == "application/pdf")
    // The SDK result describes the file; the bytes are only in the file.
    #expect(!file.encodedJSON(pretty: false).contains("SDK-DOWNLOAD-BYTES"))
    let written = try #require(FileManager.default.contents(atPath: destination))
    #expect(String(data: written, encoding: .utf8) == "SDK-DOWNLOAD-BYTES")
    #expect(try await transport.firstRequest().responseSink == .file(path: destination))
  }

  @Test("The writer SDK is cumulative and exposes its reader client")
  func writerClientIsCumulative() async throws {
    let transport = RecordingTransport.succeeding(
      json: WrikeFixtures.envelope(kind: "tasks", data: WrikeFixtures.task)
    )
    let client = try WrikeWriteClient(
      transport: transport,
      credentials: StubCredentialProvider(),
      clock: TestClock()
    )
    _ = try await client.read.task(id: "IEAAAAAAKQAB5FNY")
    #expect(try await transport.firstRequest().method == .get)

    _ = try await client.createTask(folderId: "IEAAAAAAI4AB5FNY", title: "Prepare launch")
    let requests = await transport.requests
    #expect(requests.count == 2)
    #expect(requests[1].method == .post)
  }

  @Test("The admin SDK is cumulative and its deletes route through the planner")
  func adminClientIsCumulative() async throws {
    let transport = RecordingTransport.succeeding(
      json: "{\"kind\":\"ids\",\"data\":[\"IEAAAAAAKQAB5FNY\"]}"
    )
    let client = try WrikeAdminClient(
      transport: transport,
      credentials: StubCredentialProvider(),
      clock: TestClock()
    )
    let result = try await client.deleteTask(taskId: "IEAAAAAAKQAB5FNY")

    #expect(result["deletedId"]?.stringValue == "IEAAAAAAKQAB5FNY")
    let recorded = try await transport.firstRequest()
    #expect(recorded.method == .delete)
    #expect(recorded.capabilityID == CapabilityID("tasks.delete"))
  }

  @Test("The reader SDK cannot reach a write or delete capability")
  func readerClientIsBounded() async throws {
    let transport = RecordingTransport.succeeding(json: "{}")
    let client = try WrikeReadClient(
      transport: transport,
      credentials: StubCredentialProvider(),
      clock: TestClock()
    )

    do {
      _ = try await client.executor.execute(CapabilityInvocation(
        capabilityID: CapabilityID("tasks.delete"),
        arguments: ["input": .object(["taskId": .string("IEAAAAAAKQAB5FNY")])]
      ))
      Issue.record("The reader SDK must not dispatch a delete")
    } catch let error as GatewayError {
      #expect(error.code == .capabilityDenied)
    }
    #expect(await transport.requestCount == 0)
  }
}
