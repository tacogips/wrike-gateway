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
    guard !isNoContent(status: statusCode) else {
      return noContentResponse(statusCode: statusCode, headers: headers)
    }
    try verifyComplete(byteCount: body.count, headers: headers)
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
    guard !isNoContent(status: statusCode) else {
      try? FileManager.default.removeItem(at: temporaryURL)
      return noContentResponse(statusCode: statusCode, headers: headers)
    }
    let byteCount = fileByteCount(at: temporaryURL)
    do {
      try verifyComplete(byteCount: byteCount, headers: headers)
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

  /// Statuses HTTP defines as carrying no body.
  ///
  /// Wrike documents binary content for both file-output routes, so a
  /// no-content answer is not a zero-byte attachment: it is a response that
  /// does not match the documented contract. Writing an empty file would report
  /// a success the caller could not distinguish from a real transfer, so no
  /// file is created and no `downloadedFile` is attached. The projection turns
  /// the missing description into `UPSTREAM_RESPONSE_INVALID`.
  ///
  /// The rule is deliberately limited to the statuses that *define* an absent
  /// body rather than to any empty success body, because an attachment whose
  /// stored content is genuinely empty must still be delivered as a `200`.
  private static func isNoContent(status: Int) -> Bool { status == 204 || status == 205 }

  private static func noContentResponse(
    statusCode: Int,
    headers: [String: String]
  ) -> WrikeResponse {
    WrikeResponse(statusCode: statusCode, headers: headers, body: Data())
  }

  /// Refuses a success body whose length disagrees with the one the response
  /// declared, before any of it reaches the caller's destination path.
  ///
  /// The comparison is made only where it is meaningful. An absent, unparsable,
  /// or negative `Content-Length` leaves the check off, which is what a chunked
  /// response looks like. A content-encoded body also leaves it off, because
  /// the declared length then counts encoded bytes while the delivered file
  /// holds the decoded ones, and comparing the two would reject a complete
  /// download.
  private static func verifyComplete(byteCount: Int, headers: [String: String]) throws {
    guard let declared = declaredContentLength(in: headers), declared != byteCount else { return }
    // Only two counts are named. Neither is a byte of the body.
    throw TransportFailure.malformedResponse(
      "the download delivered \(byteCount) bytes where \(declared) were declared"
    )
  }

  private static func declaredContentLength(in headers: [String: String]) -> Int? {
    var normalized: [String: String] = [:]
    for (name, value) in headers {
      normalized[name.lowercased()] = value.trimmingCharacters(in: .whitespaces)
    }
    if let encoding = normalized["content-encoding"]?.lowercased(),
       !encoding.isEmpty,
       encoding != "identity" {
      return nil
    }
    guard let raw = normalized["content-length"], let declared = Int(raw), declared >= 0 else {
      return nil
    }
    return declared
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
