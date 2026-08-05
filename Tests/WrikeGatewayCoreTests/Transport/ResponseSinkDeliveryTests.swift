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
    var testDescription: String { "\(status)" }
  }

  static let statuses: [StatusCase] = [
    StatusCase(status: 200, writesFile: true),
    StatusCase(status: 201, writesFile: true),
    StatusCase(status: 204, writesFile: true),
    StatusCase(status: 299, writesFile: true),
    StatusCase(status: 300, writesFile: false),
    StatusCase(status: 400, writesFile: false),
    StatusCase(status: 401, writesFile: false),
    StatusCase(status: 403, writesFile: false),
    StatusCase(status: 404, writesFile: false),
    StatusCase(status: 429, writesFile: false),
    StatusCase(status: 500, writesFile: false)
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
    // On a failure the body stays in memory for the error mapper; on success it
    // is on disk and the response body is empty.
    #expect(buffered.body.isEmpty == statusCase.writesFile)
    #expect(streamed.body.isEmpty == statusCase.writesFile)
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
