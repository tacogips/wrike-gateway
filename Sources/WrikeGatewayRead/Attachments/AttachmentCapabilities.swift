import WrikeGatewayCore

/// Reader capabilities for attachments.
///
/// Only metadata and the time-limited download URL are exposed. Attachment
/// bytes never enter the JSON envelope, a stable model, an error message, or a
/// test snapshot; binary retrieval is a separate reviewed capability that the
/// initial contract does not register.
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

  public static let all: [CapabilityDefinition] = [list, get, url]
}
