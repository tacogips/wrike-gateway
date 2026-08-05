import Foundation

/// Turns a raw upstream answer into a `WrikeResponse` that honours the
/// request's response sink.
///
/// Every transport routes its result through this type so the live
/// `URLSession` transport and the test transports cannot disagree about when a
/// body is written to disk, where it is written, or what happens to an error
/// body. The two entry points differ only in where the bytes start: one holds
/// them in memory, the other has them in a temporary file the system already
/// streamed.
public enum ResponseSinkDelivery {
  /// Attachment error envelopes are small. Reading more than this from a
  /// failed download would let an unexpected upstream body be buffered whole,
  /// so the surplus is discarded and the mapper works from the prefix.
  public static let maximumBufferedErrorBytes = 64 * 1024

  /// Permissions applied to a written attachment. Downloaded content is user
  /// data, so it is readable only by the account that asked for it.
  static let destinationPermissions: NSNumber = 0o600

  /// Delivers a body the transport already holds in memory.
  public static func deliver(
    sink: WrikeResponseSink,
    statusCode: Int,
    headers: [String: String],
    body: Data
  ) throws -> WrikeResponse {
    guard case .file(let path) = sink, WrikeResponseSink.isSuccess(status: statusCode) else {
      return WrikeResponse(statusCode: statusCode, headers: headers, body: body)
    }
    try write(body, toPath: path)
    return successResponse(
      statusCode: statusCode,
      headers: headers,
      path: path,
      byteCount: body.count
    )
  }

  /// Delivers a body the system already streamed to `temporaryURL`.
  ///
  /// The temporary file is always consumed: it is moved into place on success
  /// and removed on failure, so a refused download leaves nothing behind.
  ///
  /// This entry point takes the destination path rather than a sink, because a
  /// streamed body only ever exists for a file destination. Accepting a sink
  /// here would let a caller stream a `.memory` response and have its body
  /// silently truncated to the failure bound.
  public static func deliver(
    destinationPath path: String,
    statusCode: Int,
    headers: [String: String],
    temporaryURL: URL
  ) throws -> WrikeResponse {
    guard WrikeResponseSink.isSuccess(status: statusCode) else {
      let body = boundedContents(of: temporaryURL)
      try? FileManager.default.removeItem(at: temporaryURL)
      return WrikeResponse(statusCode: statusCode, headers: headers, body: body)
    }
    let byteCount = fileByteCount(at: temporaryURL)
    do {
      try move(temporaryURL, toPath: path)
    } catch {
      try? FileManager.default.removeItem(at: temporaryURL)
      throw error
    }
    return successResponse(
      statusCode: statusCode,
      headers: headers,
      path: path,
      byteCount: byteCount
    )
  }

  private static func successResponse(
    statusCode: Int,
    headers: [String: String],
    path: String,
    byteCount: Int
  ) -> WrikeResponse {
    let normalized = headers.reduce(into: [String: String]()) { result, entry in
      result[entry.key.lowercased()] = entry.value
    }
    return WrikeResponse(
      statusCode: statusCode,
      headers: headers,
      // The body stays empty on the success path; the bytes are in the file.
      body: Data(),
      downloadedFile: DownloadedFile(
        path: path,
        byteCount: byteCount,
        contentType: normalized["content-type"]
      )
    )
  }

  /// Creates the destination without ever replacing an existing file. A read
  /// operation must not destroy local data, so an occupied path is a failure
  /// rather than an overwrite.
  private static func write(_ body: Data, toPath path: String) throws {
    let url = URL(fileURLWithPath: path)
    do {
      try body.write(to: url, options: [.withoutOverwriting])
    } catch {
      throw TransportFailure.localIO(describe(error, path: path))
    }
    applyPermissions(toPath: path)
  }

  private static func move(_ temporaryURL: URL, toPath path: String) throws {
    let destination = URL(fileURLWithPath: path)
    do {
      // `moveItem` fails rather than replaces when the destination exists,
      // which is the same no-overwrite rule the buffered path enforces.
      try FileManager.default.moveItem(at: temporaryURL, to: destination)
    } catch {
      throw TransportFailure.localIO(describe(error, path: path))
    }
    applyPermissions(toPath: path)
  }

  private static func applyPermissions(toPath path: String) {
    try? FileManager.default.setAttributes(
      [.posixPermissions: destinationPermissions],
      ofItemAtPath: path
    )
  }

  /// Describes a file failure by its cause and the caller's own path. The path
  /// came from the caller, so naming it discloses nothing the caller did not
  /// already supply, and no byte of the response is included.
  private static func describe(_ error: any Error, path: String) -> String {
    let code = (error as NSError).code
    if code == NSFileWriteFileExistsError {
      return "the destination \(path) already exists"
    }
    return "the destination \(path) could not be written"
  }

  private static func fileByteCount(at url: URL) -> Int {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes?[.size] as? NSNumber)?.intValue ?? 0
  }

  /// Reads at most `maximumBufferedErrorBytes` so an unexpected large body on a
  /// failed download is not buffered in full.
  private static func boundedContents(of url: URL) -> Data {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
    defer { try? handle.close() }
    return (try? handle.read(upToCount: maximumBufferedErrorBytes)) ?? Data()
  }
}
