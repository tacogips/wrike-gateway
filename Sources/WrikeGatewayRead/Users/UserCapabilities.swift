import WrikeGatewayCore

/// Reader capabilities for users and user types.
///
/// Wrike API v4 has no reviewed paginated user-list operation, so no `users`
/// collection field is registered. Account people remain available through
/// `contacts` with a person-type filter.
public enum UserCapabilities {
  public static let user = ModelShape(
    typeName: "User",
    fields: [
      ModelField("id", .identifier, required: true),
      ModelField("firstName", .string),
      ModelField("lastName", .string),
      ModelField("type", .string),
      ModelField("profiles", .objectList(ContactModels.profile)),
      ModelField("avatarUrl", .string),
      ModelField("timezone", .string),
      ModelField("locale", .string),
      ModelField("deleted", .boolean),
      ModelField("me", .boolean),
      ModelField("memberIds", .identifierList),
      ModelField("myTeam", .boolean),
      ModelField("title", .string),
      ModelField("companyName", .string),
      ModelField("phone", .string),
      ModelField("location", .string)
    ]
  )

  public static let userType = ModelShape(
    typeName: "UserType",
    fields: [
      ModelField("id", .identifier, required: true),
      ModelField("title", .string),
      ModelField("licenseType", .string)
    ]
  )

  public static let get = CapabilityDefinition(
    id: CapabilityID("users.get"),
    field: "user",
    tier: .reader,
    operationClass: .read,
    method: .get,
    pathTemplate: "/users/{userId}",
    arguments: [
      ArgumentDefinition("id", .identifier, .path("userId"), required: true)
    ],
    result: .single(user),
    scopes: ScopeRequirement(
      accepted: ["amReadOnlyUser", "amReadWriteUser"],
      recommended: "amReadOnlyUser"
    ),
    summary: "Returns one user by its opaque identifier."
  )

  public static let types = CapabilityDefinition(
    id: CapabilityID("users.types.list"),
    field: "userTypes",
    tier: .reader,
    operationClass: .read,
    method: .get,
    pathTemplate: "/user_types",
    result: .list(userType),
    scopes: .workspaceRead,
    summary: "Lists the user types configured for the current account."
  )

  public static let all: [CapabilityDefinition] = [get, types]
}
