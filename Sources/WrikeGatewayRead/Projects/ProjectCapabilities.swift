import WrikeGatewayCore

/// Reader capabilities for projects.
///
/// These are distinct public capabilities from the folder family even though
/// Wrike serves both from `/folders`. Keeping `projects.list` and
/// `projects.get` separate preserves the caller's intent and lets the two
/// diverge later without a breaking change.
public enum ProjectCapabilities {
  /// A project is a folder that carries project metadata, so the two share a
  /// stable shape. The distinct type name keeps the schema self-describing.
  public static let project = ModelShape(
    typeName: "Project",
    fields: FolderCapabilities.folder.fields
  )

  public static let list = CapabilityDefinition(
    id: CapabilityID("projects.list"),
    field: "projects",
    tier: .reader,
    operationClass: .read,
    method: .get,
    pathTemplate: "/folders",
    scopeVariants: FolderCapabilities.listVariants,
    arguments: FolderCapabilities.listArguments + [
      ArgumentDefinition("project", .boolean, .query("project"))
    ],
    result: .list(project),
    scopes: .workspaceRead,
    summary: "Lists projects for the account, a space, or a parent folder."
  )

  public static let get = CapabilityDefinition(
    id: CapabilityID("projects.get"),
    field: "project",
    tier: .reader,
    operationClass: .read,
    method: .get,
    pathTemplate: "/folders/{projectId}",
    arguments: [
      ArgumentDefinition("id", .identifier, .path("projectId"), required: true)
    ],
    result: .single(project),
    scopes: .workspaceRead,
    summary: "Returns one project by its opaque identifier."
  )

  public static let all: [CapabilityDefinition] = [list, get]
}
