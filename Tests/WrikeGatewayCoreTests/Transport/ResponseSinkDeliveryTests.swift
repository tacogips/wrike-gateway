import Foundation
import Testing
import WrikeGatewayCore
import WrikeGatewayTestSupport

/// `ResponseSinkDelivery` is the one place that decides whether a body reaches
/// the caller's disk. The live transport streams into a temporary file and the
/// test transports hold the bytes in memory, so both entry points are asserted
/// against the same table: a divergence here would mean the tested write rule
/// is not the production write rule.
@Suite("Response sink delivery")
struct ResponseSinkDeliveryTests {
  struct StatusCase: Sendable, CustomTestStringConvertible {
    let status: Int
    let writesFile: Bool
    /// Whether the delivered response still carries the bytes in memory. Only a
    /// refused status does, so the error mapper can read its JSON envelope.
    let retainsBody: Bool
    var testDescription: String { "\(status)" }
  }

  static let statuses: [StatusCase] = [
    StatusCase(status: 200, writesFile: true, retainsBody: false),
    StatusCase(status: 201, writesFile: true, retainsBody: false),
    // 204 and 205 define an absent body. Wrike documents binary content on both
    // file-output routes, so a body-less success is a contract violation rather
    // than an empty attachment: no file is written, and nothing is retained for
    // the error mapper because there is no error envelope to read.
    StatusCase(status: 204, writesFile: false, retainsBody: false),
    StatusCase(status: 205, writesFile: false, retainsBody: false),
    StatusCase(status: 299, writesFile: true, retainsBody: false),
    StatusCase(status: 300, writesFile: false, retainsBody: true),
    StatusCase(status: 400, writesFile: false, retainsBody: true),
    StatusCase(status: 401, writesFile: false, retainsBody: true),
    StatusCase(status: 403, writesFile: false, retainsBody: true),
    StatusCase(status: 404, writesFile: false, retainsBody: true),
    StatusCase(status: 429, writesFile: false, retainsBody: true),
    StatusCase(status: 500, writesFile: false, retainsBody: true)
  ]

  private func temporaryFile(in directory: TemporaryDirectory, contents: String) throws -> URL {
    let url = URL(fileURLWithPath: directory.path("streamed-\(UUID().uuidString)"))
    try Data(contents.utf8).write(to: url)
    return url
  }

  @Test("Buffered and streamed delivery agree on every status", arguments: statuses)
  func entryPointsAgree(statusCase: StatusCase) throws {
    let directory = try TemporaryDirectory()
    let body = "CONTENT-\(statusCase.status)"

    let bufferedPath = directory.path("buffered-\(statusCase.status)")
    let buffered = try ResponseSinkDelivery.deliver(
      sink: .file(path: bufferedPath),
      statusCode: statusCase.status,
      headers: ["Content-Type": "application/octet-stream"],
      body: Data(body.utf8)
    )

    let streamedPath = directory.path("streamed-\(statusCase.status)")
    let temporaryURL = try temporaryFile(in: directory, contents: body)
    let streamed = try ResponseSinkDelivery.deliver(
      destinationPath: streamedPath,
      statusCode: statusCase.status,
      headers: ["Content-Type": "application/octet-stream"],
      temporaryURL: temporaryURL
    )

    let manager = FileManager.default
    #expect(manager.fileExists(atPath: bufferedPath) == statusCase.writesFile)
    #expect(manager.fileExists(atPath: streamedPath) == statusCase.writesFile)
    #expect((buffered.downloadedFile != nil) == statusCase.writesFile)
    #expect((streamed.downloadedFile != nil) == statusCase.writesFile)
    #expect(buffered.downloadedFile?.byteCount == streamed.downloadedFile?.byteCount)
    #expect(buffered.downloadedFile?.contentType == streamed.downloadedFile?.contentType)
    // On a refusal the body stays in memory for the error mapper; on a written
    // success it is on disk, and on a body-less success there is nothing at all.
    #expect(buffered.body.isEmpty == !statusCase.retainsBody)
    #expect(streamed.body.isEmpty == !statusCase.retainsBody)
    #expect(buffered.body == streamed.body)
    // The temporary file is always consumed, whichever way it went.
    #expect(!manager.fileExists(atPath: temporaryURL.path))
  }

  @Test("A memory sink never writes a file")
  func memorySinkNeverWrites() throws {
    let response = try ResponseSinkDelivery.deliver(
      sink: .memory,
      statusCode: 200,
      headers: [:],
      body: Data("{\"kind\":\"tasks\"}".utf8)
    )

    #expect(response.downloadedFile == nil)
    #expect(String(data: response.body, encoding: .utf8) == "{\"kind\":\"tasks\"}")
  }

  /// The coercer rejects an occupied destination before the request is sent,
  /// but a file can appear in the window between that check and the write.
  /// The transport is the last line and must refuse there too.
  @Test("Buffered delivery refuses to replace a file created after validation")
  func bufferedDeliveryRefusesOverwrite() throws {
    let directory = try TemporaryDirectory()
    let path = directory.path("occupied")
    try Data("original".utf8).write(to: URL(fileURLWithPath: path))

    #expect(throws: TransportFailure.self) {
      _ = try ResponseSinkDelivery.deliver(
        sink: .file(path: path),
        statusCode: 200,
        headers: [:],
        body: Data("replacement".utf8)
      )
    }
    let preserved = try Data(contentsOf: URL(fileURLWithPath: path))
    #expect(String(data: preserved, encoding: .utf8) == "original")
  }

  @Test("Streamed delivery refuses to replace a file and drops its temporary copy")
  func streamedDeliveryRefusesOverwrite() throws {
    let directory = try TemporaryDirectory()
    let path = directory.path("occupied")
    try Data("original".utf8).write(to: URL(fileURLWithPath: path))
    let temporaryURL = try temporaryFile(in: directory, contents: "replacement")

    #expect(throws: TransportFailure.self) {
      _ = try ResponseSinkDelivery.deliver(
        destinationPath: path,
        statusCode: 200,
        headers: [:],
        temporaryURL: temporaryURL
      )
    }
    let preserved = try Data(contentsOf: URL(fileURLWithPath: path))
    #expect(String(data: preserved, encoding: .utf8) == "original")
    // A refused download must not leave the content lying in the temporary
    // directory either.
    #expect(!FileManager.default.fileExists(atPath: temporaryURL.path))
  }

  @Test("A written file is readable only by its owner")
  func writesOwnerOnlyPermissions() throws {
    let directory = try TemporaryDirectory()
    let path = directory.path("secret.bin")

    _ = try ResponseSinkDelivery.deliver(
      sink: .file(path: path),
      statusCode: 200,
      headers: [:],
      body: Data("content".utf8)
    )

    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
    #expect(permissions.int16Value == 0o600)
  }

  @Test("An oversized failure body is truncated rather than buffered whole")
  func boundsTheBufferedErrorBody() throws {
    let directory = try TemporaryDirectory()
    let oversized = String(repeating: "x", count: ResponseSinkDelivery.maximumBufferedErrorBytes * 2)
    let temporaryURL = try temporaryFile(in: directory, contents: oversized)

    let response = try ResponseSinkDelivery.deliver(
      destinationPath: directory.path("unused"),
      statusCode: 500,
      headers: [:],
      temporaryURL: temporaryURL
    )

    #expect(response.body.count == ResponseSinkDelivery.maximumBufferedErrorBytes)
    #expect(!FileManager.default.fileExists(atPath: directory.path("unused")))
  }

  /// A body-less success is the one 2XX shape that must not become a file.
  /// Both entry points are asserted, because the live transport streams and the
  /// test transports buffer, and only one of them would otherwise be proved.
  @Test("A body-less success writes no file and describes no download", arguments: [204, 205])
  func noContentSuccessWritesNothing(status: Int) throws {
    let directory = try TemporaryDirectory()
    let bufferedPath = directory.path("buffered.bin")
    let streamedPath = directory.path("streamed.bin")
    let temporaryURL = try temporaryFile(in: directory, contents: "")

    let buffered = try ResponseSinkDelivery.deliver(
      sink: .file(path: bufferedPath),
      statusCode: status,
      headers: ["Content-Type": "application/octet-stream"],
      body: Data()
    )
    let streamed = try ResponseSinkDelivery.deliver(
      destinationPath: streamedPath,
      statusCode: status,
      headers: ["Content-Type": "application/octet-stream"],
      temporaryURL: temporaryURL
    )

    let manager = FileManager.default
    #expect(!manager.fileExists(atPath: bufferedPath))
    #expect(!manager.fileExists(atPath: streamedPath))
    #expect(buffered.downloadedFile == nil)
    #expect(streamed.downloadedFile == nil)
    #expect(!manager.fileExists(atPath: temporaryURL.path))
  }

  /// The gateway compares what arrived against what the response declared, so a
  /// truncated transfer cannot land as a complete file.
  @Test("A body shorter than its declared length is refused and written nowhere")
  func refusesTruncatedDownload() throws {
    let directory = try TemporaryDirectory()
    let bufferedPath = directory.path("buffered.bin")
    let streamedPath = directory.path("streamed.bin")
    let temporaryURL = try temporaryFile(in: directory, contents: "PARTIAL")
    let headers = ["Content-Length": "4096"]

    #expect(throws: TransportFailure.self) {
      _ = try ResponseSinkDelivery.deliver(
        sink: .file(path: bufferedPath),
        statusCode: 200,
        headers: headers,
        body: Data("PARTIAL".utf8)
      )
    }
    #expect(throws: TransportFailure.self) {
      _ = try ResponseSinkDelivery.deliver(
        destinationPath: streamedPath,
        statusCode: 200,
        headers: headers,
        temporaryURL: temporaryURL
      )
    }

    let manager = FileManager.default
    #expect(!manager.fileExists(atPath: bufferedPath))
    #expect(!manager.fileExists(atPath: streamedPath))
    // A refused transfer leaves nothing behind, the temporary copy included.
    #expect(!manager.fileExists(atPath: temporaryURL.path))
  }

  @Test("A truncation refusal is not transient and quotes no response content")
  func truncationRefusalIsSafe() throws {
    let directory = try TemporaryDirectory()
    var captured: TransportFailure?
    do {
      _ = try ResponseSinkDelivery.deliver(
        sink: .file(path: directory.path("out.bin")),
        statusCode: 200,
        headers: ["content-length": "99"],
        body: Data("SECRET-ATTACHMENT-CONTENT".utf8)
      )
    } catch let failure as TransportFailure {
      captured = failure
    }

    let failure = try #require(captured)
    #expect(!failure.safeSummary.contains("SECRET-ATTACHMENT-CONTENT"))
    #expect(failure.safeSummary.contains("99"))
    // Re-running a request whose response was cut short is the caller's call,
    // not an automatic retry: the destination now has to be reconsidered.
    #expect(!failure.isTransient)
  }

  struct ToleratedCase: Sendable, CustomTestStringConvertible {
    let name: String
    let headers: [String: String]
    var testDescription: String { name }
  }

  /// The check must stay off wherever a declared length cannot be compared to
  /// bytes written, or it would reject complete downloads.
  @Test(
    "A length that cannot be compared leaves the check off",
    arguments: [
      ToleratedCase(name: "chunked, no length", headers: [:]),
      ToleratedCase(name: "compressed body", headers: ["Content-Length": "9", "Content-Encoding": "gzip"]),
      ToleratedCase(name: "unparsable length", headers: ["Content-Length": "not-a-number"]),
      ToleratedCase(name: "negative length", headers: ["Content-Length": "-1"]),
      ToleratedCase(name: "identity encoding, matching length", headers: ["Content-Length": "7", "Content-Encoding": "identity"])
    ]
  )
  func tolerateIncomparableLength(toleratedCase: ToleratedCase) throws {
    let directory = try TemporaryDirectory()
    let path = directory.path("out.bin")

    let response = try ResponseSinkDelivery.deliver(
      sink: .file(path: path),
      statusCode: 200,
      headers: toleratedCase.headers,
      body: Data("CONTENT".utf8)
    )

    #expect(response.downloadedFile?.byteCount == 7)
    #expect(FileManager.default.fileExists(atPath: path))
  }

  @Test("A body matching its declared length is delivered")
  func acceptsMatchingLength() throws {
    let directory = try TemporaryDirectory()
    let path = directory.path("out.bin")

    let response = try ResponseSinkDelivery.deliver(
      sink: .file(path: path),
      statusCode: 200,
      headers: ["Content-Length": "7"],
      body: Data("CONTENT".utf8)
    )

    #expect(response.downloadedFile?.byteCount == 7)
  }

  @Test("A refusal names the caller's own path and no response content")
  func failureDescriptionCarriesNoContent() throws {
    let directory = try TemporaryDirectory()
    let path = directory.path("occupied")
    try Data("original".utf8).write(to: URL(fileURLWithPath: path))

    var captured: TransportFailure?
    do {
      _ = try ResponseSinkDelivery.deliver(
        sink: .file(path: path),
        statusCode: 200,
        headers: [:],
        body: Data("SECRET-ATTACHMENT-CONTENT".utf8)
      )
    } catch let failure as TransportFailure {
      captured = failure
    }

    let failure = try #require(captured)
    #expect(failure.safeSummary.contains(path))
    #expect(!failure.safeSummary.contains("SECRET-ATTACHMENT-CONTENT"))
    // A local write failure is not a transient network condition.
    #expect(!failure.isTransient)
  }
}
