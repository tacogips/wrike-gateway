import WrikeGatewayCore

/// Reader capabilities for the account and its access roles.
public enum AccountCapabilities {
  public static let account = ModelShape(
    typeName: "Account",
    fields: [
      ModelField("id", .identifier, required: true),
      ModelField("name", .string),
      ModelField("dateFormat", .string),
      ModelField("firstDayOfWeek", .string),
      ModelField("workDays", .stringList),
      ModelField("rootFolderId", .identifier),
      ModelField("recycleBinId", .identifier),
      ModelField("createdDate", .dateTime),
      ModelField("subscription", .object(subscription)),
      ModelField("metadata", .objectList(ContactModels.metadataEntry))
    ]
  )

  public static let subscription = ModelShape(
    typeName: "AccountSubscription",
    fields: [
      ModelField("type", .string),
      ModelField("suspended", .boolean),
      ModelField("paid", .boolean),
      ModelField("userLimit", .integer),
      ModelField("expiryDate", .date)
    ]
  )

  public static let accessRole = ModelShape(
    typeName: "AccessRole",
    fields: [
      ModelField("id", .identifier, required: true),
      ModelField("title", .string),
      ModelField("description", .string)
    ]
  )

  public static let get = CapabilityDefinition(
    id: CapabilityID("account.get"),
    field: "account",
    tier: .reader,
    operationClass: .read,
    method: .get,
    pathTemplate: "/account",
    result: .single(account),
    scopes: .workspaceRead,
    summary: "Returns the current Wrike account."
  )

  public static let accessRoles = CapabilityDefinition(
    id: CapabilityID("accessRoles.list"),
    field: "accessRoles",
    tier: .reader,
    operationClass: .read,
    method: .get,
    pathTemplate: "/access_roles",
    result: .list(accessRole),
    scopes: .workspaceRead,
    summary: "Lists the access roles available in the current account."
  )

  public static let all: [CapabilityDefinition] = [get, accessRoles]
}
