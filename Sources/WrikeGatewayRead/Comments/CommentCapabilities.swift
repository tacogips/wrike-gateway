import WrikeGatewayCore

/// Reader capabilities for comments.
///
/// Comment text is part of the stable model because a caller explicitly selects
/// it, but it is never placed in diagnostics, error messages, or logs.
public enum CommentCapabilities {
  public static let comment = ModelShape(
    typeName: "Comment",
    fields: [
      ModelField("id", .identifier, required: true),
      ModelField("authorId", .identifier),
      ModelField("text", .string),
      ModelField("createdDate", .dateTime),
      ModelField("updatedDate", .dateTime),
      ModelField("taskId", .identifier),
      ModelField("folderId", .identifier),
      ModelField("type", .string)
    ]
  )

  public static let list = CapabilityDefinition(
    id: CapabilityID("comments.list"),
    field: "comments",
    tier: .reader,
    operationClass: .read,
    method: .get,
    pathTemplate: "/comments",
    scopeVariants: [
      ScopeVariant(.account, "/comments"),
      ScopeVariant(.folder, "/folders/{scopeId}/comments"),
      ScopeVariant(.project, "/folders/{scopeId}/comments"),
      ScopeVariant(.task, "/tasks/{scopeId}/comments")
    ],
    arguments: [
      ArgumentDefinition("scope", .scope, .scope),
      ArgumentDefinition("plainText", .boolean, .query("plainText")),
      ArgumentDefinition("limit", .integer, .query("limit")),
      ArgumentDefinition("types", .stringList, .queryList("types"))
    ],
    result: .list(comment),
    scopes: .workspaceRead,
    summary: "Lists comments for the account, a folder, a project, or a task."
  )

  public static let get = CapabilityDefinition(
    id: CapabilityID("comments.get"),
    field: "comment",
    tier: .reader,
    operationClass: .read,
    method: .get,
    pathTemplate: "/comments/{commentId}",
    arguments: [
      ArgumentDefinition("id", .identifier, .path("commentId"), required: true)
    ],
    result: .single(comment),
    scopes: .workspaceRead,
    summary: "Returns one comment by its opaque identifier."
  )

  public static let all: [CapabilityDefinition] = [list, get]
}
