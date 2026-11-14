import WrikeGatewayCore

/// Reader capabilities for spaces.
public enum SpaceCapabilities {
  public static let member = ModelShape(
    typeName: "SpaceMember",
    fields: [
      ModelField("id", .identifier, required: true),
      ModelField("accessRoleId", .identifier),
      ModelField("manager", .boolean)
    ]
  )

  public static let space = ModelShape(
    typeName: "Space",
    fields: [
      ModelField("id", .identifier, required: true),
      ModelField("title", .string),
      ModelField("avatarUrl", .string),
      ModelField("accessType", .string),
      ModelField("archived", .boolean),
      ModelField("guestRoleId", .identifier),
      ModelField("defaultProjectWorkflowId", .identifier),
      ModelField("defaultTaskWorkflowId", .identifier),
      ModelField("description", .string),
      ModelField("members", .objectList(member))
    ]
  )

  public static let list = CapabilityDefinition(
    id: CapabilityID("spaces.list"),
    field: "spaces",
    tier: .reader,
    operationClass: .read,
    method: .get,
    pathTemplate: "/spaces",
    arguments: [
      ArgumentDefinition("withArchived", .boolean, .query("withArchived")),
      ArgumentDefinition("userIsMember", .boolean, .query("userIsMember")),
      ArgumentDefinition("title", .string, .query("title")),
      ArgumentDefinition(
        "accessTypes",
        .stringList,
        .queryList("accessTypes")
      )
    ],
    result: .list(space),
    scopes: .workspaceRead,
    summary: "Lists spaces in the current account."
  )

  public static let get = CapabilityDefinition(
    id: CapabilityID("spaces.get"),
    field: "space",
    tier: .reader,
    operationClass: .read,
    method: .get,
    pathTemplate: "/spaces/{spaceId}",
    arguments: [
      ArgumentDefinition("id", .identifier, .path("spaceId"), required: true)
    ],
    result: .single(space),
    scopes: .workspaceRead,
    summary: "Returns one space by its opaque identifier."
  )

  public static let all: [CapabilityDefinition] = [list, get]
}
