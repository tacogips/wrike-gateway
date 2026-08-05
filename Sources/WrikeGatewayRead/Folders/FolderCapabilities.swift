import WrikeGatewayCore

/// Reader capabilities for folders.
///
/// Wrike serves folders and projects from one endpoint family. This project
/// keeps the two intents distinct: `folder`/`folders` and `project`/`projects`
/// are separate public fields with separate capability ids, and the shared
/// upstream path is never exposed to callers.
public enum FolderCapabilities {
  public static let projectDetail = ModelShape(
    typeName: "ProjectDetail",
    fields: [
      ModelField("authorId", .identifier),
      ModelField("ownerIds", .identifierList),
      ModelField("customStatusId", .identifier),
      ModelField("startDate", .date),
      ModelField("endDate", .date),
      ModelField("createdDate", .dateTime),
      ModelField("completedDate", .dateTime),
      ModelField("contractType", .string)
    ]
  )

  public static let customFieldValue = ModelShape(
    typeName: "CustomFieldValue",
    fields: [
      ModelField("id", .identifier, required: true),
      ModelField("value", .string)
    ]
  )

  public static let folder = ModelShape(
    typeName: "Folder",
    fields: [
      ModelField("id", .identifier, required: true),
      ModelField("accountId", .identifier),
      ModelField("title", .string),
      ModelField("createdDate", .dateTime),
      ModelField("updatedDate", .dateTime),
      ModelField("description", .string),
      ModelField("sharedIds", .identifierList),
      ModelField("parentIds", .identifierList),
      ModelField("childIds", .identifierList),
      ModelField("superParentIds", .identifierList),
      ModelField("scope", .string),
      ModelField("hasAttachments", .boolean),
      ModelField("permalink", .string),
      ModelField("workflowId", .identifier),
      ModelField("space", .boolean),
      ModelField("color", .string),
      ModelField("project", .object(projectDetail)),
      ModelField("customFields", .objectList(customFieldValue)),
      ModelField("metadata", .objectList(ContactModels.metadataEntry))
    ]
  )

  /// Scope variants shared by the folder and project list capabilities.
  static let listVariants: [ScopeVariant] = [
    ScopeVariant(.account, "/folders"),
    ScopeVariant(.space, "/spaces/{scopeId}/folders"),
    ScopeVariant(.folder, "/folders/{scopeId}/folders")
  ]

  static let listArguments: [ArgumentDefinition] = [
    ArgumentDefinition("scope", .scope, .scope),
    ArgumentDefinition("permalink", .string, .query("permalink")),
    ArgumentDefinition("descendants", .boolean, .query("descendants")),
    ArgumentDefinition("deleted", .boolean, .query("deleted")),
    ArgumentDefinition("metadata", .string, .query("metadata"))
  ]

  public static let list = CapabilityDefinition(
    id: CapabilityID("folders.list"),
    field: "folders",
    tier: .reader,
    operationClass: .read,
    method: .get,
    pathTemplate: "/folders",
    scopeVariants: listVariants,
    arguments: listArguments,
    result: .list(folder),
    scopes: .workspaceRead,
    summary: "Lists folders for the account, a space, or a parent folder."
  )

  public static let get = CapabilityDefinition(
    id: CapabilityID("folders.get"),
    field: "folder",
    tier: .reader,
    operationClass: .read,
    method: .get,
    pathTemplate: "/folders/{folderId}",
    arguments: [
      ArgumentDefinition("id", .identifier, .path("folderId"), required: true)
    ],
    result: .single(folder),
    scopes: .workspaceRead,
    summary: "Returns one folder by its opaque identifier."
  )

  public static let all: [CapabilityDefinition] = [list, get]
}
