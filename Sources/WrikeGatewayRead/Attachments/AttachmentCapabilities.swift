import WrikeGatewayCore

/// Reader capabilities for attachments.
///
/// Metadata, the time-limited download URL, and binary retrieval are all
/// exposed, but they stay separate contracts. Attachment bytes never enter the
/// JSON envelope, a stable model, an error message, or a test snapshot: the two
/// binary capabilities carry a `.fileOutput` result, so their success body is
/// streamed straight to the caller's destination path and the response value
/// describes only the file that was written.
public enum AttachmentCapabilities {
  public static let attachment = ModelShape(
    typeName: "Attachment",
    fields: [
      ModelField("id", .identifier, required: true),
      ModelField("authorId", .identifier),
      ModelField("name", .string),
      ModelField("createdDate", .dateTime),
      ModelField("version", .integer),
      ModelField("type", .string),
      ModelField("contentType", .string),
      ModelField("size", .integer),
      ModelField("taskId", .identifier),
      ModelField("folderId", .identifier),
      ModelField("commentId", .identifier),
      ModelField("currentAttachmentId", .identifier),
      ModelField("previewUrl", .string),
      ModelField("url", .string),
      ModelField("width", .integer),
      ModelField("height", .integer)
    ]
  )

  public static let list = CapabilityDefinition(
    id: CapabilityID("attachments.list"),
    field: "attachments",
    tier: .reader,
    operationClass: .read,
    method: .get,
    pathTemplate: "/attachments",
    scopeVariants: [
      ScopeVariant(.account, "/attachments"),
      ScopeVariant(.folder, "/folders/{scopeId}/attachments"),
      ScopeVariant(.project, "/folders/{scopeId}/attachments"),
      ScopeVariant(.task, "/tasks/{scopeId}/attachments")
    ],
    arguments: [
      ArgumentDefinition("scope", .scope, .scope),
      ArgumentDefinition("versions", .boolean, .query("versions")),
      ArgumentDefinition("withUrls", .boolean, .query("withUrls")),
      ArgumentDefinition("createdDate", .string, .query("createdDate"))
    ],
    result: .list(attachment),
    scopes: .workspaceRead,
    summary: "Lists attachment metadata for the account, a folder, a project, or a task."
  )

  public static let get = CapabilityDefinition(
    id: CapabilityID("attachments.get"),
    field: "attachment",
    tier: .reader,
    operationClass: .read,
    method: .get,
    pathTemplate: "/attachments/{attachmentId}",
    arguments: [
      ArgumentDefinition("id", .identifier, .path("attachmentId"), required: true)
    ],
    result: .single(attachment),
    scopes: .workspaceRead,
    summary: "Returns one attachment's metadata by its opaque identifier."
  )

  public static let downloadURL = ModelShape(
    typeName: "AttachmentDownloadURL",
    fields: [
      ModelField("id", .identifier, required: true),
      ModelField("url", .string),
      ModelField("name", .string),
      ModelField("contentType", .string),
      ModelField("size", .integer)
    ]
  )

  public static let url = CapabilityDefinition(
    id: CapabilityID("attachments.url"),
    field: "attachmentDownloadUrl",
    tier: .reader,
    operationClass: .read,
    method: .get,
    pathTemplate: "/attachments/{attachmentId}/url",
    arguments: [
      ArgumentDefinition("id", .identifier, .path("attachmentId"), required: true)
    ],
    result: .single(downloadURL),
    scopes: .workspaceRead,
    summary: "Returns a time-limited download URL for one attachment. No bytes are transferred."
  )

  /// Sizes accepted by `GET /attachments/{attachmentId}/preview`, curated from
  /// the official reference. An unlisted size fails locally by name instead of
  /// reaching Wrike as a rejected request.
  public static let previewSizes = ["w44", "w100", "w200", "w300", "w400", "h400"]

  /// The attachment's content, written to a local file.
  ///
  /// Route confirmed against the official reference for
  /// `GET /attachments/{attachmentId}/download`, which answers with an
  /// `application/octet-stream` body. The body is never buffered into the
  /// response envelope: `destination` selects the transport's file sink, and
  /// the result describes the written file only.
  public static let download = CapabilityDefinition(
    id: CapabilityID("attachments.download"),
    field: "attachmentDownload",
    tier: .reader,
    operationClass: .read,
    method: .get,
    pathTemplate: "/attachments/{attachmentId}/download",
    arguments: [
      ArgumentDefinition("id", .identifier, .path("attachmentId"), required: true),
      ArgumentDefinition("destination", .string, .destinationPath, required: true)
    ],
    result: .fileOutput(FileOutputShape.shape),
    scopes: .workspaceRead,
    summary: "Downloads one attachment's content to destination. "
      + "The path must not already exist; an existing file is never replaced."
  )

  /// A rendered preview of the attachment, written to a local file.
  ///
  /// Route and `size` values confirmed against the official reference for
  /// `GET /attachments/{attachmentId}/preview`. Not every attachment type has a
  /// preview; when Wrike has none it answers with a mapped upstream error and
  /// nothing is written.
  public static let preview = CapabilityDefinition(
    id: CapabilityID("attachments.preview"),
    field: "attachmentPreview",
    tier: .reader,
    operationClass: .read,
    method: .get,
    pathTemplate: "/attachments/{attachmentId}/preview",
    arguments: [
      ArgumentDefinition("id", .identifier, .path("attachmentId"), required: true),
      ArgumentDefinition("destination", .string, .destinationPath, required: true),
      ArgumentDefinition(
        "size",
        .enumeration("AttachmentPreviewSize", previewSizes),
        .query("size")
      )
    ],
    result: .fileOutput(FileOutputShape.shape),
    scopes: .workspaceRead,
    summary: "Downloads one attachment's preview to destination. "
      + "The path must not already exist; an existing file is never replaced.",
    // A preview-less attachment type is refused upstream exactly as a missing
    // attachment is, so the stable code alone sends an operator looking for a
    // wrong identifier. Naming the second cause, and the route that always has
    // content, is the difference between a dead end and a next step.
    upstreamRejectionGuidance: "Wrike refused this preview. Not every attachment type has one; "
      + "use attachmentDownload for the original content, or attachment to check the type."
  )

  public static let all: [CapabilityDefinition] = [list, get, url, download, preview]
}
