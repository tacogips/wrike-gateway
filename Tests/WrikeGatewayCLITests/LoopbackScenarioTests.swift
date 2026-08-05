import Foundation
import Testing
import WrikeGatewayAdmin
import WrikeGatewayCore
import WrikeGatewayRead
import WrikeGatewayTestSupport
import WrikeGatewayWrite

/// End-to-end scenarios against a real loopback HTTP server.
///
/// These exercise the live `URLSession` transport, so they verify actual URL
/// encoding, real request headers, real streamed upload bodies, and real
/// response headers, which the recording transport cannot.
@Suite("Loopback canned-response scenarios", .serialized)
struct LoopbackScenarioTests {
  private func withServer(
    responses: [LoopbackHTTPServer.CannedResponse],
    tier: CapabilityTier = .admin,
    body: (GraphQLRuntime, LoopbackHTTPServer) async throws -> Void
  ) async throws {
    let server = try LoopbackHTTPServer(responses: responses)
    try await server.start()
    defer { server.stop() }

    let definitions: [CapabilityDefinition]
    switch tier {
    case .reader: definitions = ReadCapabilities.all
    case .writer: definitions = WriteCapabilities.all
    case .admin: definitions = AdminCapabilities.all
    }

    let runtime = GraphQLRuntime(
      executor: CapabilityExecutor(
        planner: CapabilityPlanner(
          registry: try CapabilityRegistry(tier: tier, definitions: definitions),
          coercer: ArgumentCoercer(fileAccess: SystemFileAccess())
        ),
        transport: URLSessionWrikeTransport(hostPolicy: server.hostPolicy),
        credentials: StubCredentialProvider(baseURL: server.baseURL.absoluteString),
        clock: TestClock(),
        retryPolicy: RetryPolicy(jitterFraction: 0)
      ),
      requestIDFactory: { "loopback-request-id" }
    )
    try await body(runtime, server)
  }

  @Test("A read succeeds end to end over real HTTP")
  func readSucceeds() async throws {
    try await withServer(responses: [
      .init(body: WrikeFixtures.envelope(kind: "tasks", data: WrikeFixtures.task))
    ]) { runtime, server in
      let response = await runtime.execute(
        document: "{ task(id: \"IEAAAAAAKQAB5FNY\") { id title status } }"
      )
      #expect(response.errors.isEmpty)
      #expect(response.data?["task"]?["title"]?.stringValue == "Prepare launch")

      let observed = try #require(server.observedRequests.first)
      #expect(observed.method == "GET")
      #expect(observed.target == "/api/v4/tasks/IEAAAAAAKQAB5FNY")
      #expect(observed.hasAuthorizationHeader)
      #expect(observed.headerNames.contains("accept"))
    }
  }

  @Test("Query parameters are percent-encoded on the wire")
  func encodesQueryParameters() async throws {
    try await withServer(responses: [
      .init(body: WrikeFixtures.envelope(kind: "spaces", data: "{\"id\":\"IEAG\",\"title\":\"A B\"}"))
    ]) { runtime, server in
      _ = await runtime.execute(document: "{ spaces(title: \"A B & C\") { id title } }")

      let observed = try #require(server.observedRequests.first)
      #expect(observed.target.contains("title="))
      #expect(!observed.target.contains(" "), "A raw space must never reach the wire")
      #expect(observed.target.contains("%20") || observed.target.contains("+"))
    }
  }

  @Test("Pagination carries an opaque token through unchanged")
  func paginationRoundTrip() async throws {
    try await withServer(responses: [
      .init(body: WrikeFixtures.envelope(
        kind: "tasks",
        data: WrikeFixtures.task,
        nextPageToken: "opaque%2Ftoken+value"
      ))
    ]) { runtime, server in
      let response = await runtime.execute(document: """
        { tasks(page: {pageSize: 25}) { nodes { id } pageInfo { resultCount nextPageToken } } }
        """)

      #expect(response.errors.isEmpty)
      let pageInfo = try #require(response.data?["tasks"]?["pageInfo"]?.objectValue)
      #expect(pageInfo["nextPageToken"]?.stringValue == "opaque%2Ftoken+value")
      #expect(pageInfo["resultCount"]?.intValue == 1)

      let observed = try #require(server.observedRequests.first)
      #expect(observed.target.contains("pageSize=25"))
    }
  }

  @Test("A 429 with Retry-After is retried once for a GET, then succeeds")
  func rateLimitRetry() async throws {
    try await withServer(responses: [
      .init(status: 429, headers: ["Retry-After": "1"], body: "{\"error\":\"rate_limit_exceeded\"}"),
      .init(body: WrikeFixtures.envelope(kind: "tasks", data: WrikeFixtures.task))
    ]) { runtime, server in
      let response = await runtime.execute(document: "{ task(id: \"IEAAAAAAKQAB5FNY\") { id } }")

      #expect(response.errors.isEmpty)
      #expect(server.observedRequests.count == 2)
    }
  }

  @Test("A persistent 429 surfaces RATE_LIMITED with exit code 5")
  func rateLimitExhausted() async throws {
    try await withServer(responses: [
      .init(status: 429, body: "{\"error\":\"rate_limit_exceeded\"}")
    ]) { runtime, _ in
      let response = await runtime.execute(document: "{ task(id: \"IEAAAAAAKQAB5FNY\") { id } }")
      let error = try #require(response.errors.first)
      #expect(error.code == .rateLimited)
      #expect(error.exitCode == .transientUpstream)
      #expect(error.recoveryGuidance?.contains("400 requests per minute") == true)
    }
  }

  static let failureStatuses: [(Int, GatewayErrorCode)] = [
    (400, .validationError),
    (401, .authenticationFailed),
    (403, .authorizationFailed),
    (404, .notFound),
    (500, .upstreamUnavailable)
  ]

  @Test("Each upstream failure status maps end to end", arguments: failureStatuses)
  func mapsFailureStatuses(status: Int, expected: GatewayErrorCode) async throws {
    try await withServer(responses: [.init(status: status, body: WrikeFixtures.errorBody)]) { runtime, _ in
      let response = await runtime.execute(document: "{ task(id: \"IEAAAAAAKQAB5FNY\") { id } }")
      let error = try #require(response.errors.first)
      #expect(error.code == expected)
      #expect(error.httpStatus == status)
    }
  }

  @Test("A malformed response body is UPSTREAM_RESPONSE_INVALID")
  func malformedResponse() async throws {
    try await withServer(responses: [.init(body: "{not json")]) { runtime, _ in
      let response = await runtime.execute(document: "{ task(id: \"IEAAAAAAKQAB5FNY\") { id } }")
      #expect(response.errors.first?.code == .upstreamResponseInvalid)
    }
  }

  @Test("A wrong-shape success envelope fails instead of returning empty data")
  func wrongEnvelopeShape() async throws {
    try await withServer(responses: [.init(body: "{\"kind\":\"tasks\",\"data\":\"not-a-list\"}")]) { runtime, _ in
      let response = await runtime.execute(document: "{ task(id: \"IEAAAAAAKQAB5FNY\") { id } }")
      #expect(response.errors.first?.code == .upstreamResponseInvalid)
    }
  }

  @Test("A delete succeeds end to end and returns the confirmed id")
  func deleteSucceeds() async throws {
    try await withServer(responses: [
      .init(body: "{\"kind\":\"ids\",\"data\":[\"IEAAAAAAKQAB5FNY\"]}")
    ]) { runtime, server in
      let response = await runtime.execute(
        document: "mutation { deleteTask(input: {taskId: \"IEAAAAAAKQAB5FNY\"}) { deletedId } }"
      )

      #expect(response.errors.isEmpty)
      #expect(response.data?["deleteTask"]?["deletedId"]?.stringValue == "IEAAAAAAKQAB5FNY")
      let observed = try #require(server.observedRequests.first)
      #expect(observed.method == "DELETE")
      #expect(observed.target == "/api/v4/tasks/IEAAAAAAKQAB5FNY")
      #expect(observed.contentLength == 0)
    }
  }

  @Test("A 200 delete with an empty data array is outcome-unknown, not a confirmation")
  func deleteWithEmptyEnvelopeIsUnconfirmed() async throws {
    try await withServer(responses: [.init(body: "{\"kind\":\"ids\",\"data\":[]}")]) { runtime, server in
      let response = await runtime.execute(
        document: "mutation { deleteTask(input: {taskId: \"IEAAAAAAKQAB5FNY\"}) { deletedId } }"
      )

      let error = try #require(response.errors.first)
      #expect(error.code == .upstreamResponseInvalid)
      #expect(error.outcomeUnknown, "An unconfirmed delete must not claim the requested id was deleted")
      #expect(response.data?["deleteTask"]?["deletedId"] == nil)
      #expect(server.observedRequests.count == 1, "A delete must never be replayed")
    }
  }

  @Test("A delete meeting a 500 is outcome-unknown and is not replayed")
  func deleteOutcomeUnknown() async throws {
    try await withServer(responses: [.init(status: 500, body: "{\"error\":\"server_error\"}")]) { runtime, server in
      let response = await runtime.execute(
        document: "mutation { deleteTask(input: {taskId: \"IEAAAAAAKQAB5FNY\"}) { deletedId } }"
      )

      let error = try #require(response.errors.first)
      #expect(error.code == .upstreamUnavailable)
      #expect(error.outcomeUnknown)
      #expect(server.observedRequests.count == 1, "A delete must never be replayed")
    }
  }

  @Test("A create meeting a 500 is outcome-unknown and is not replayed")
  func mutationOutcomeUnknown() async throws {
    try await withServer(responses: [.init(status: 500, body: "{\"error\":\"server_error\"}")]) { runtime, server in
      let response = await runtime.execute(document: """
        mutation { createTask(input: {folderId: "IEAAAAAAI4AB5FNY", title: "X"}) { task { id } } }
        """)

      let error = try #require(response.errors.first)
      #expect(error.outcomeUnknown)
      #expect(server.observedRequests.count == 1)
    }
  }

  @Test("A form-encoded mutation sends its body on the wire")
  func mutationSendsBody() async throws {
    try await withServer(responses: [
      .init(body: WrikeFixtures.envelope(kind: "tasks", data: WrikeFixtures.task))
    ]) { runtime, server in
      let response = await runtime.execute(document: """
        mutation { createTask(input: {folderId: "IEAAAAAAI4AB5FNY", title: "Prepare launch"}) \
        { task { id title } } }
        """)

      #expect(response.errors.isEmpty)
      let observed = try #require(server.observedRequests.first)
      #expect(observed.method == "POST")
      #expect(observed.target == "/api/v4/folders/IEAAAAAAI4AB5FNY/tasks")
      #expect(observed.contentLength > 0)
      #expect(observed.headerNames.contains("content-type"))
    }
  }

  @Test("An attachment upload streams the file without buffering or logging bytes")
  func attachmentUploadStreams() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("wrike-gateway-upload-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let file = directory.appendingPathComponent("brief.pdf")
    // A distinctive marker so a byte leak into output would be unmistakable.
    let payload = Data(String(repeating: "UPLOAD-BYTES-MARKER-b41c;", count: 160).utf8)
    try payload.write(to: file)

    try await withServer(responses: [
      .init(body: WrikeFixtures.envelope(kind: "attachments", data: WrikeFixtures.attachment))
    ]) { runtime, server in
      let response = await runtime.execute(document: """
        mutation { uploadTaskAttachment(input: {taskId: "IEAAAAAAKQAB5FNY", \
        filePath: "\(file.path)"}) { attachment { id name size } } }
        """)

      #expect(response.errors.isEmpty, "\(response.errors)")
      let observed = try #require(server.observedRequests.first)
      #expect(observed.method == "POST")
      #expect(observed.contentLength == payload.count, "The whole file must reach the server")

      // The rendered envelope carries metadata only, never file bytes.
      let rendered = response.rendered(pretty: false)
      #expect(!rendered.contains("UPLOAD-BYTES-MARKER"))
      #expect(rendered.contains("brief.pdf"))
    }
  }

  @Test("An upload of an unreadable path fails locally with no request")
  func uploadRejectsMissingFile() async throws {
    try await withServer(responses: [.init(body: "{}")]) { runtime, server in
      let response = await runtime.execute(document: """
        mutation { uploadTaskAttachment(input: {taskId: "IEAAAAAAKQAB5FNY", \
        filePath: "/tmp/wrike-gateway-definitely-absent"}) { attachment { id } } }
        """)

      #expect(response.errors.first?.code == .fileOperationFailed)
      #expect(server.observedRequests.isEmpty)
    }
  }

  @Test("An attachment download streams to disk over real HTTP")
  func attachmentDownloadStreams() async throws {
    let directory = try TemporaryDirectory()
    let destination = directory.path("brief.pdf")
    // A distinctive marker so a byte leak into output would be unmistakable.
    let payload = String(repeating: "DOWNLOAD-BYTES-MARKER-9f2e;", count: 160)

    try await withServer(responses: [
      .init(headers: ["Content-Type": "application/octet-stream"], body: payload)
    ]) { runtime, server in
      let response = await runtime.execute(document: """
        { attachmentDownload(id: "IEAAAAAAIYAAAAAB", destination: "\(destination)") \
        { path byteCount contentType } }
        """)

      #expect(response.errors.isEmpty, "\(response.errors)")
      let observed = try #require(server.observedRequests.first)
      #expect(observed.method == "GET")
      #expect(observed.target == "/api/v4/attachments/IEAAAAAAIYAAAAAB/download")

      let written = try #require(FileManager.default.contents(atPath: destination))
      #expect(String(data: written, encoding: .utf8) == payload)

      let file = try #require(response.data?["attachmentDownload"])
      #expect(file["byteCount"]?.intValue == payload.utf8.count)
      #expect(file["contentType"]?.stringValue == "application/octet-stream")

      // The bytes exist in the file and nowhere else.
      let rendered = response.rendered(pretty: false)
      #expect(!rendered.contains("DOWNLOAD-BYTES-MARKER"))
      #expect(rendered.contains("brief.pdf"))
    }
  }

  @Test("A refused download maps the upstream error and leaves no file behind")
  func attachmentDownloadFailureWritesNothing() async throws {
    let directory = try TemporaryDirectory()
    let destination = directory.path("brief.pdf")

    try await withServer(responses: [
      .init(status: 403, body: """
        {"error":"access_forbidden","errorDescription":"DOWNLOAD-LEAK-MARKER-4c10"}
        """)
    ]) { runtime, _ in
      let response = await runtime.execute(document: """
        { attachmentDownload(id: "IEAAAAAAIYAAAAAB", destination: "\(destination)") { path } }
        """)

      #expect(response.errors.first?.code == .authorizationFailed)
      // The JSON error envelope is not the attachment, so it must not be
      // written to the path the caller believes now holds their file.
      #expect(!FileManager.default.fileExists(atPath: destination))
      #expect(!response.rendered(pretty: false).contains("DOWNLOAD-LEAK-MARKER"))
    }
  }

  @Test("A preview request carries its curated size on the wire")
  func attachmentPreviewSendsSize() async throws {
    let directory = try TemporaryDirectory()
    let destination = directory.path("preview.png")

    try await withServer(responses: [
      .init(headers: ["Content-Type": "image/png"], body: "PNG-PREVIEW-BYTES")
    ]) { runtime, server in
      let response = await runtime.execute(document: """
        { attachmentPreview(id: "IEAAAAAAIYAAAAAB", destination: "\(destination)", \
        size: "w200") { path byteCount contentType } }
        """)

      #expect(response.errors.isEmpty, "\(response.errors)")
      let observed = try #require(server.observedRequests.first)
      #expect(observed.target == "/api/v4/attachments/IEAAAAAAIYAAAAAB/preview?size=w200")
      #expect(
        response.data?["attachmentPreview"]?["contentType"]?.stringValue == "image/png"
      )
    }
  }

  @Test("Independent read fields execute against separate upstream requests")
  func multipleTopLevelReads() async throws {
    try await withServer(responses: [
      .init(body: WrikeFixtures.envelope(kind: "tasks", data: WrikeFixtures.task)),
      .init(body: WrikeFixtures.envelope(kind: "folders", data: WrikeFixtures.folder))
    ]) { runtime, server in
      let response = await runtime.execute(document: """
        { task(id: "IEAAAAAAKQAB5FNY") { id } folder(id: "IEAAAAAAI4AB5FNY") { id } }
        """)

      #expect(response.errors.isEmpty)
      #expect(response.data?["task"]?["id"]?.stringValue == "IEAAAAAAKQAB5FNY")
      #expect(response.data?["folder"]?["id"]?.stringValue == "IEAAAAAAI4AB5FNY")
      #expect(server.observedRequests.count == 2)
    }
  }

  @Test("Every data-center host is reachable through the same capability plan")
  func dataCenterHosts() throws {
    let planner = CapabilityPlanner(registry: try ReadCapabilities.registry())
    let plan = try planner.plan(CapabilityInvocation(
      capabilityID: TaskCapabilities.get.id,
      arguments: ["id": .string("IEAAAAAAKQAB5FNY")]
    ))

    for host in WrikeHostPolicy.approvedAPIHosts {
      let baseURL = try WrikeHostPolicy.production.baseURL(forOAuthHost: host)
      let prepared = try CapabilityExecutor.prepare(
        plan.request,
        credential: ResolvedCredential(
          mode: .oauth2,
          token: SecretValue("fake"),
          baseURL: baseURL,
          grantedScopes: [],
          expiresAt: nil
        ),
        requestID: "fixed"
      )
      #expect(prepared.url.host == host)
      #expect(prepared.url.path == "/api/v4/tasks/IEAAAAAAKQAB5FNY")
      #expect(prepared.hasAuthorization)
    }
  }

  @Test("Redaction holds across a full loopback round trip")
  func redactionAcrossRoundTrip() async throws {
    let secretToken = "FAKE-LOOPBACK-TOKEN-do-not-log-3a91"
    let server = try LoopbackHTTPServer(responses: [
      .init(status: 403, body: """
        {"error":"access_forbidden","errorDescription":"LEAK-MARKER-e77b"}
        """)
    ])
    try await server.start()
    defer { server.stop() }

    let runtime = GraphQLRuntime(
      executor: CapabilityExecutor(
        planner: CapabilityPlanner(registry: try ReadCapabilities.registry()),
        transport: URLSessionWrikeTransport(hostPolicy: server.hostPolicy),
        credentials: StubCredentialProvider(
          token: secretToken,
          baseURL: server.baseURL.absoluteString
        ),
        clock: TestClock()
      )
    )

    let response = await runtime.execute(document: "{ task(id: \"IEAAAAAAKQAB5FNY\") { id } }")
    let rendered = response.rendered(pretty: true)
    #expect(!rendered.contains(secretToken))
    #expect(!rendered.contains("LEAK-MARKER-e77b"))
    #expect(rendered.contains("AUTHORIZATION_FAILED"))
    #expect(server.observedRequests.first?.hasAuthorizationHeader == true)
  }
}
