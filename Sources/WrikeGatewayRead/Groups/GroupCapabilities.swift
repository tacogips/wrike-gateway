import WrikeGatewayCore

/// Reader capabilities for user groups.
public enum GroupCapabilities {
  public static let group = ModelShape(
    typeName: "Group",
    fields: [
      ModelField("id", .identifier, required: true),
      ModelField("accountId", .identifier),
      ModelField("title", .string),
      ModelField("memberIds", .identifierList),
      ModelField("childIds", .identifierList),
      ModelField("parentIds", .identifierList),
      ModelField("avatarUrl", .string),
      ModelField("myTeam", .boolean),
      ModelField("metadata", .objectList(ContactModels.metadataEntry))
    ]
  )

  public static let list = CapabilityDefinition(
    id: CapabilityID("groups.list"),
    field: "groups",
    tier: .reader,
    operationClass: .read,
    method: .get,
    pathTemplate: "/groups",
    arguments: [
      ArgumentDefinition("metadata", .string, .query("metadata"))
    ],
    result: .list(group),
    scopes: ScopeRequirement(
      accepted: ["Default", "amReadOnlyGroup", "amReadWriteGroup"],
      recommended: "amReadOnlyGroup"
    ),
    summary: "Lists user groups in the current account."
  )

  public static let get = CapabilityDefinition(
    id: CapabilityID("groups.get"),
    field: "group",
    tier: .reader,
    operationClass: .read,
    method: .get,
    pathTemplate: "/groups/{groupId}",
    arguments: [
      ArgumentDefinition("id", .identifier, .path("groupId"), required: true)
    ],
    result: .single(group),
    scopes: ScopeRequirement(
      accepted: ["Default", "amReadOnlyGroup", "amReadWriteGroup"],
      recommended: "amReadOnlyGroup"
    ),
    summary: "Returns one user group by its opaque identifier."
  )

  public static let all: [CapabilityDefinition] = [list, get]
}
