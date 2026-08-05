import Foundation
import Testing
import WrikeGatewayCore
import WrikeGatewayRead
import WrikeGatewayTestSupport

/// One canonical exercise per file-output capability.
///
/// These cannot use the envelope harness: their success body is
/// `application/octet-stream` and is written to disk rather than decoded, so
/// every assertion about `kind`, `data`, or a malformed envelope is meaningless
/// for them and would pass vacuously.
struct FileOutputCase: Sendable, CustomTestStringConvertible {
  let definition: CapabilityDefinition
  /// Built with the destination path the test just reserved.
  let arguments: @Sendable (String) -> [String: WrikeValue]
  let document: @Sendable (String) -> String
  let expectedPath: String
  let expectedQuery: [String: String]

  var name: String { definition.id.rawValue }
  var testDescription: String { name }
}

enum FileOutputCases {
  static let all: [FileOutputCase] = [
    FileOutputCase(
      definition: AttachmentCapabilities.download,
      arguments: { destination in
        ["id": .string("IEAAAAAAIYAAAAAB"), "destination": .string(destination)]
      },
      document: { destination in
        """
        { attachmentDownload(id: "IEAAAAAAIYAAAAAB", destination: "\(destination)") \
        { path byteCount contentType } }
        """
      },
      expectedPath: "/api/v4/attachments/IEAAAAAAIYAAAAAB/download",
      expectedQuery: [:]
    ),
    FileOutputCase(
      definition: AttachmentCapabilities.preview,
      arguments: { destination in
        [
          "id": .string("IEAAAAAAIYAAAAAB"),
          "destination": .string(destination),
          "size": .string("w200")
        ]
      },
      document: { destination in
        """
        { attachmentPreview(id: "IEAAAAAAIYAAAAAB", destination: "\(destination)", \
        size: "w200") { path byteCount } }
        """
      },
      expectedPath: "/api/v4/attachments/IEAAAAAAIYAAAAAB/preview",
      expectedQuery: ["size": "w200"]
    )
  ]

  /// The canned attachment content. It is deliberately not JSON, so a test that
  /// accidentally routed it through the envelope decoder would fail.
  static let content = "PDF-BYTES-\u{1}\u{2}not-json"

  static func transport(status: Int = 200, body: String = content) -> RecordingTransport {
    RecordingTransport(outcomes: [
      .response(
        WrikeResponse(
          statusCode: status,
          headers: ["Content-Type": "application/octet-stream"],
          body: Data(body.utf8)
        )
      )
    ])
  }
}

@Suite("Attachment binary transfer")
struct AttachmentTransferTests {
  @Test("Each binary-transfer capability writes its body to the destination", arguments: FileOutputCases.all)
  func writesToDestination(testCase: FileOutputCase) async throws {
    let directory = try TemporaryDirectory()
    let destination = directory.path("attachment.bin")
    let transport = FileOutputCases.transport()
    let runtime = try ReaderCases.runtime(transport: transport)

    let response = await runtime.execute(document: testCase.document(destination))
    #expect(response.errors.isEmpty, "\(testCase.name): \(response.errors)")

    let recorded = try await transport.firstRequest()
    #expect(recorded.method == .get)
    #expect(recorded.path == testCase.expectedPath, "\(testCase.name)")
    for (name, value) in testCase.expectedQuery {
      #expect(recorded.query[name] == value, "\(testCase.name) query \(name)")
    }
    // The destination is a local concern and must never be sent upstream.
    #expect(!recorded.queryItems.contains { $0.value.contains(destination) })
    #expect(recorded.responseSink == .file(path: destination))

    let written = try #require(FileManager.default.contents(atPath: destination))
    #expect(String(data: written, encoding: .utf8) == FileOutputCases.content)

    let data = try #require(response.data?[testCase.definition.field])
    #expect(data["path"]?.stringValue == destination)
    #expect(data["byteCount"]?.intValue == Data(FileOutputCases.content.utf8).count)
  }

  @Test("An upstream failure writes nothing to the destination", arguments: FileOutputCases.all)
  func failureLeavesNoFile(testCase: FileOutputCase) async throws {
    let directory = try TemporaryDirectory()
    let destination = directory.path("attachment.bin")
    let transport = FileOutputCases.transport(status: 403, body: WrikeFixtures.errorBody)
    let runtime = try ReaderCases.runtime(transport: transport)

    let response = await runtime.execute(document: testCase.document(destination))

    let error = try #require(response.errors.first, "\(testCase.name)")
    #expect(error.code == .authorizationFailed)
    #expect(error.capabilityID == testCase.definition.id)
    // A JSON error envelope is not content and must not land on the caller's
    // path, which would otherwise leave a "downloaded attachment" holding an
    // error document.
    #expect(!FileManager.default.fileExists(atPath: destination), "\(testCase.name)")
  }

  @Test("An existing destination is refused before any request", arguments: FileOutputCases.all)
  func refusesExistingDestination(testCase: FileOutputCase) async throws {
    let directory = try TemporaryDirectory()
    let destination = directory.path("attachment.bin")
    try Data("original".utf8).write(to: URL(fileURLWithPath: destination))
    let transport = FileOutputCases.transport()
    let runtime = try ReaderCases.runtime(transport: transport)

    let response = await runtime.execute(document: testCase.document(destination))

    let error = try #require(response.errors.first, "\(testCase.name)")
    #expect(error.code == .fileOperationFailed)
    #expect(error.exitCode == .localResource)
    #expect(await transport.requestCount == 0, "\(testCase.name) must fail before transport")
    let unchanged = try #require(FileManager.default.contents(atPath: destination))
    #expect(String(data: unchanged, encoding: .utf8) == "original")
  }

  @Test("A destination inside a missing directory is refused before any request")
  func refusesMissingParent() async throws {
    let directory = try TemporaryDirectory()
    let destination = directory.path("absent/attachment.bin")
    let transport = FileOutputCases.transport()
    let runtime = try ReaderCases.runtime(transport: transport)

    let response = await runtime.execute(
      document: """
        { attachmentDownload(id: "IEAAAAAAIYAAAAAB", destination: "\(destination)") { path } }
        """
    )

    #expect(response.errors.first?.code == .fileOperationFailed)
    #expect(await transport.requestCount == 0)
  }

  @Test("A destination naming a directory is refused before any request")
  func refusesDirectoryDestination() async throws {
    let directory = try TemporaryDirectory()
    let transport = FileOutputCases.transport()
    let runtime = try ReaderCases.runtime(transport: transport)

    let response = await runtime.execute(
      document: """
        { attachmentDownload(id: "IEAAAAAAIYAAAAAB", destination: "\(directory.url.path)") { path } }
        """
    )

    #expect(response.errors.first?.code == .fileOperationFailed)
    #expect(await transport.requestCount == 0)
  }

  @Test("The written file is readable only by its owner")
  func writesOwnerOnlyPermissions() async throws {
    let directory = try TemporaryDirectory()
    let destination = directory.path("attachment.bin")
    let runtime = try ReaderCases.runtime(transport: FileOutputCases.transport())

    _ = await runtime.execute(
      document: """
        { attachmentDownload(id: "IEAAAAAAIYAAAAAB", destination: "\(destination)") { path } }
        """
    )

    let attributes = try FileManager.default.attributesOfItem(atPath: destination)
    let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
    #expect(permissions.int16Value == 0o600)
  }

  @Test("An unaccepted preview size is rejected locally by name")
  func rejectsUnknownPreviewSize() async throws {
    let directory = try TemporaryDirectory()
    let destination = directory.path("attachment.bin")
    let transport = FileOutputCases.transport()
    let runtime = try ReaderCases.runtime(transport: transport)

    let response = await runtime.execute(
      document: """
        { attachmentPreview(id: "IEAAAAAAIYAAAAAB", destination: "\(destination)", \
        size: "w9999") { path } }
        """
    )

    let error = try #require(response.errors.first)
    #expect(error.code == .validationError)
    #expect(error.message.contains("w200"), "the error must name the accepted sizes")
    #expect(await transport.requestCount == 0)
    #expect(!FileManager.default.fileExists(atPath: destination))
  }

  @Test("Neither the response nor an error can carry attachment bytes")
  func bytesStayOutOfDiagnostics() async throws {
    let directory = try TemporaryDirectory()
    let destination = directory.path("attachment.bin")
    let runtime = try ReaderCases.runtime(transport: FileOutputCases.transport())

    let response = await runtime.execute(
      document: """
        { attachmentDownload(id: "IEAAAAAAIYAAAAAB", destination: "\(destination)") \
        { path byteCount contentType } }
        """
    )

    let rendered = response.stableValue.encodedJSON(pretty: false)
    #expect(!rendered.contains("PDF-BYTES"), "the response envelope carried attachment content")
    #expect(!rendered.contains("not-json"))
    #expect(rendered.contains("byteCount"))
  }

  @Test(
    "The typed SDK and GraphQL select the same plan for every file-output capability",
    arguments: FileOutputCases.all
  )
  func sdkGraphQLParity(testCase: FileOutputCase) throws {
    let directory = try TemporaryDirectory()
    let destination = directory.path("attachment.bin")
    let planner = CapabilityPlanner(registry: try ReadCapabilities.registry())

    let comparison = try ParityHarness.compare(
      planner: planner,
      invocation: CapabilityInvocation(
        capabilityID: testCase.definition.id,
        arguments: testCase.arguments(destination)
      ),
      document: testCase.document(destination)
    )

    #expect(comparison.isEquivalent, "\(testCase.name): \(comparison.summary)")
    #expect(comparison.sdkPlan?.request.responseSink == .file(path: destination))
  }

  @Test("No capability other than a file output selects a file sink")
  func onlyFileOutputsSelectAFileSink() throws {
    let planner = CapabilityPlanner(registry: try ReadCapabilities.registry())
    for testCase in ReaderCases.all {
      let plan = try planner.plan(
        CapabilityInvocation(
          capabilityID: testCase.definition.id,
          arguments: testCase.arguments
        )
      )
      #expect(plan.request.responseSink == .memory, "\(testCase.name)")
    }
  }
}
