import Foundation
import Testing
import WrikeGatewayCore
import WrikeGatewayTestSupport

/// Unmistakably fake secret values. Every test in this suite asserts that none
/// of them can appear in output, diagnostics, or a thrown error description.
private enum FakeSecrets {
  static let clientSecret = "FAKE-CLIENT-SECRET-do-not-log-8f2a"
  static let accessToken = "FAKE-ACCESS-TOKEN-do-not-log-91bd"
  static let refreshToken = "FAKE-REFRESH-TOKEN-do-not-log-4c7e"
  static let authorizationCode = "FAKE-AUTH-CODE-do-not-log-0d31"
  static let oauthState = "FAKE-OAUTH-STATE-do-not-log-77aa"
  static let webhookSecret = "FAKE-WEBHOOK-SECRET-do-not-log-52cc"
  /// Stands in for downloaded user content, which is not a credential but is
  /// held to the same rule: it may reach the caller's file and nothing else.
  static let attachmentContent = "FAKE-ATTACHMENT-CONTENT-do-not-log-6b19"

  static let all = [
    clientSecret, accessToken, refreshToken, authorizationCode, oauthState, webhookSecret
  ]
}

@Suite("Structural redaction")
struct StructuralRedactionTests {
  @Test("A SecretValue renders as the placeholder in every formatting path")
  func secretValueIsOpaque() {
    let secret = SecretValue(FakeSecrets.accessToken)
    #expect("\(secret)" == SecretValue.placeholder)
    #expect(String(describing: secret) == SecretValue.placeholder)
    #expect(String(reflecting: secret) == SecretValue.placeholder)

    var dumped = ""
    dump(secret, to: &dumped)
    #expect(!dumped.contains(FakeSecrets.accessToken))

    // Redaction is structural: the value survives only through reveal().
    #expect(secret.reveal() == FakeSecrets.accessToken)
  }

  @Test("Token state never renders its tokens")
  func tokenStateIsOpaque() {
    let state = OAuthTokenState(
      accessToken: SecretValue(FakeSecrets.accessToken),
      refreshToken: SecretValue(FakeSecrets.refreshToken),
      expiresAt: Date(timeIntervalSince1970: 1_900_000_000),
      grantedScopes: ["wsReadOnly"],
      host: "www.wrike.com",
      clientID: SecretValue("FAKE-CLIENT-ID")
    )
    var dumped = ""
    dump(state, to: &dumped)
    let rendered = "\(state)" + dumped
    for secret in FakeSecrets.all {
      #expect(!rendered.contains(secret))
    }
  }

  @Test("A WrikeValue cannot represent a SecretValue at all")
  func stableValuesCannotCarrySecrets() {
    // `WrikeValue` is a closed enum over JSON primitives, so the only way a
    // token could reach output is if it were first converted to a String. The
    // auth status report is the one place that formats credential state.
    let report = AuthStatusReport(
      mode: .oauth2,
      host: "www.wrike.com",
      scopes: ["wsReadOnly"],
      expiresAt: Date(timeIntervalSince1970: 1_900_000_000),
      isExpired: false,
      hasRefreshState: true,
      hasClientConfiguration: true
    )
    let rendered = report.stableValue.encodedJSON(pretty: true)
    for secret in FakeSecrets.all {
      #expect(!rendered.contains(secret))
    }
    #expect(rendered.contains("\"refreshStateAvailable\": true"))
    // The callback runs plain HTTP on the loopback interface, so there is no
    // TLS identity to report. The field was removed rather than reported as a
    // constant, and no certificate or credential-store record data replaced it.
    #expect(!rendered.contains("callbackIdentityAvailable"))
    #expect(!rendered.lowercased().contains("certificate"))
    #expect(!rendered.lowercased().contains("keychain"))
    #expect(!rendered.lowercased().contains("identity"))
  }

  @Test("A recorded request holds no authorization header value")
  func recordedRequestsAreSafe() async throws {
    let transport = RecordingTransport.succeeding(
      json: WrikeFixtures.envelope(kind: "widgets", data: "{\"id\":\"W1\"}")
    )
    let executor = try TransportTestCapabilities.executor(
      transport: transport,
      credentials: StubCredentialProvider(token: FakeSecrets.accessToken)
    )
    _ = try await executor.execute(TransportTestCapabilities.invocation("W1"))

    let recorded = try await transport.firstRequest()
    var dumped = ""
    dump(recorded, to: &dumped)
    #expect(!dumped.contains(FakeSecrets.accessToken))
    #expect(recorded.hasAuthorization)
  }

  @Test("Upstream error bodies never reach a public error message")
  func upstreamBodiesAreNotForwarded() async throws {
    let body = """
      {"error":"not_authorized",\
      "errorDescription":"token \(FakeSecrets.accessToken) failed CHECK-MARKER-ff21"}
      """
    let transport = RecordingTransport(outcomes: [
      .response(WrikeResponse(statusCode: 401, body: Data(body.utf8)))
    ])
    let executor = try TransportTestCapabilities.executor(
      transport: transport,
      retryPolicy: .disabled,
      credentials: StubCredentialProvider(token: FakeSecrets.accessToken)
    )

    do {
      _ = try await executor.execute(TransportTestCapabilities.invocation())
      Issue.record("Expected the request to fail")
    } catch let error as GatewayError {
      let rendered = error.description + error.extensions.encodedJSON(pretty: false)
      #expect(!rendered.contains(FakeSecrets.accessToken))
      // The upstream errorDescription text is dropped entirely; only the
      // documented `error` enum value is forwarded.
      #expect(!rendered.contains("CHECK-MARKER-ff21"))
      #expect(rendered.contains("not_authorized"))
    }
  }

  @Test("The webhook stable model has no secret field")
  func webhookSecretIsNotProjected() throws {
    let webhookShape = ModelShape(
      typeName: "Webhook",
      fields: [
        ModelField("id", .identifier, required: true),
        ModelField("hookUrl", .string),
        ModelField("status", .string)
      ]
    )
    let upstream = try WrikeValue.decodeJSON(Data("""
      {"id":"H1","hookUrl":"https://example.test/hook","status":"Active",\
      "secret":"\(FakeSecrets.webhookSecret)"}
      """.utf8))

    let projected = try ResponseProjection.project(
      upstream,
      shape: webhookShape,
      capability: CapabilityID("webhooks.get")
    )
    let rendered = projected.encodedJSON(pretty: false)
    #expect(!rendered.contains(FakeSecrets.webhookSecret))
    #expect(!rendered.contains("secret"))
  }

  /// A file-output capability is the only one whose upstream body is content
  /// rather than metadata. Pinning its result shape in core, rather than
  /// letting each resource declare one, is what stops a future capability from
  /// adding a field that could carry a downloaded byte into the envelope.
  @Test("The shared file-output shape describes a file and can hold no content")
  func fileOutputShapeCarriesNoContent() {
    let names = FileOutputShape.shape.fields.map(\.name)
    #expect(names == ["path", "byteCount", "contentType"])
    for field in FileOutputShape.shape.fields {
      // A scalar field cannot nest, so no sub-object can smuggle a body in.
      #expect(!field.type.isComposite, "\(field.name)")
    }
  }

  @Test("A successful file-output response keeps its body out of memory")
  func fileOutputResponseHoldsNoBody() throws {
    let directory = try TemporaryDirectory()
    let path = directory.path("attachment.bin")

    let response = try ResponseSinkDelivery.deliver(
      sink: .file(path: path),
      statusCode: 200,
      headers: ["Content-Type": "application/octet-stream"],
      body: Data(FakeSecrets.attachmentContent.utf8)
    )

    #expect(response.body.isEmpty)
    let definition = CapabilityDefinition(
      id: CapabilityID("widgets.download"),
      field: "downloadWidget",
      tier: .reader,
      operationClass: .read,
      method: .get,
      pathTemplate: "/widgets/{widgetId}/download",
      arguments: [
        ArgumentDefinition("id", .identifier, .path("widgetId"), required: true),
        ArgumentDefinition("destination", .string, .destinationPath, required: true)
      ],
      result: .fileOutput(FileOutputShape.shape),
      scopes: .workspaceRead,
      summary: "Downloads a widget."
    )
    let projected = try ResponseProjection.result(for: definition, response: response)
    let rendered = projected.encodedJSON(pretty: false)
    #expect(!rendered.contains(FakeSecrets.attachmentContent))
    #expect(rendered.contains("byteCount"))
  }

  @Test("An upload body describes only its file name, never its bytes")
  func uploadBytesAreNotDescribed() async throws {
    let upload = CapabilityDefinition(
      id: CapabilityID("widgets.upload"),
      field: "uploadWidgetFile",
      tier: .writer,
      operationClass: .create,
      method: .post,
      pathTemplate: "/widgets/{widgetId}/attachments",
      arguments: [
        ArgumentDefinition(
          "input",
          .inputObject(InputObjectShape(
            typeName: "UploadWidgetFileInput",
            fields: [
              ArgumentDefinition("widgetId", .identifier, .path("widgetId"), required: true),
              ArgumentDefinition("filePath", .string, .filePath, required: true)
            ]
          )),
          .container,
          required: true
        )
      ],
      result: .payload(field: "widget", TransportTestCapabilities.widget),
      scopes: .workspaceReadWrite,
      summary: "Uploads a file."
    )
    let registry = try CapabilityRegistry(tier: .writer, definitions: [upload])
    let planner = CapabilityPlanner(
      registry: registry,
      coercer: ArgumentCoercer(fileAccess: StubFileAccess(readable: ["/tmp/fake-brief.pdf"]))
    )
    let transport = RecordingTransport.succeeding(
      json: WrikeFixtures.envelope(kind: "attachments", data: "{\"id\":\"W1\"}")
    )
    let executor = CapabilityExecutor(
      planner: planner,
      transport: transport,
      credentials: StubCredentialProvider()
    )

    _ = try await executor.execute(CapabilityInvocation(
      capabilityID: upload.id,
      arguments: ["input": .object([
        "widgetId": .string("W1"),
        "filePath": .string("/tmp/fake-brief.pdf")
      ])]
    ))

    let recorded = try await transport.firstRequest()
    #expect(recorded.bodyDescription == "file:fake-brief.pdf:application/octet-stream")
  }

  @Test("A missing upload file fails locally with FILE_OPERATION_FAILED")
  func missingUploadFile() throws {
    let coercer = ArgumentCoercer(fileAccess: StubFileAccess(readable: []))
    let definition = CapabilityDefinition(
      id: CapabilityID("widgets.upload"),
      field: "uploadWidgetFile",
      tier: .writer,
      operationClass: .create,
      method: .post,
      pathTemplate: "/widgets/{widgetId}/attachments",
      arguments: [
        ArgumentDefinition(
          "input",
          .inputObject(InputObjectShape(
            typeName: "UploadWidgetFileInput",
            fields: [
              ArgumentDefinition("widgetId", .identifier, .path("widgetId"), required: true),
              ArgumentDefinition("filePath", .string, .filePath, required: true)
            ]
          )),
          .container,
          required: true
        )
      ],
      result: .payload(field: "widget", TransportTestCapabilities.widget),
      scopes: .workspaceReadWrite,
      summary: "Uploads a file."
    )

    do {
      _ = try coercer.coerce(
        arguments: ["input": .object([
          "widgetId": .string("W1"),
          "filePath": .string("/tmp/does-not-exist")
        ])],
        for: definition
      )
      Issue.record("Expected a file operation failure")
    } catch let error as GatewayError {
      #expect(error.code == .fileOperationFailed)
      #expect(error.exitCode == .localResource)
    }
  }
}
