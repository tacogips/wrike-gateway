import WrikeGatewayCore

/// Reader capabilities for custom field definitions.
public enum CustomFieldCapabilities {
  public static let settings = ModelShape(
    typeName: "CustomFieldSettings",
    fields: [
      ModelField("inheritanceType", .string),
      ModelField("decimalPlaces", .integer),
      ModelField("useThousandsSeparator", .boolean),
      ModelField("aggregation", .string),
      ModelField("currency", .string),
      ModelField("values", .stringList),
      ModelField("allowOtherValues", .boolean),
      ModelField("readOnly", .boolean)
    ]
  )

  public static let customField = ModelShape(
    typeName: "CustomField",
    fields: [
      ModelField("id", .identifier, required: true),
      ModelField("accountId", .identifier),
      ModelField("title", .string),
      ModelField("type", .string),
      ModelField("spaceId", .identifier),
      ModelField("sharedIds", .identifierList),
      ModelField("settings", .object(settings))
    ]
  )

  public static let list = CapabilityDefinition(
    id: CapabilityID("customFields.list"),
    field: "customFields",
    tier: .reader,
    operationClass: .read,
    method: .get,
    pathTemplate: "/customfields",
    scopeVariants: [
      ScopeVariant(.account, "/customfields"),
      ScopeVariant(.space, "/spaces/{scopeId}/customfields")
    ],
    arguments: [
      ArgumentDefinition("scope", .scope, .scope)
    ],
    result: .list(customField),
    scopes: .workspaceRead,
    summary: "Lists custom field definitions for the account or a space."
  )

  public static let get = CapabilityDefinition(
    id: CapabilityID("customFields.get"),
    field: "customField",
    tier: .reader,
    operationClass: .read,
    method: .get,
    pathTemplate: "/customfields/{customFieldId}",
    arguments: [
      ArgumentDefinition("id", .identifier, .path("customFieldId"), required: true)
    ],
    result: .single(customField),
    scopes: .workspaceRead,
    summary: "Returns one custom field definition by its opaque identifier."
  )

  public static let all: [CapabilityDefinition] = [list, get]
}
