import WrikeGatewayCore

/// Stable model shapes for the Contacts resource family.
///
/// Field names are project-owned. The `upstream:` argument records the Wrike
/// API v4 field a value is read from; that name never reaches public output.
public enum ContactModels {
  public static let metadataEntry = ModelShape(
    typeName: "MetadataEntry",
    fields: [
      ModelField("key", .string, required: true),
      ModelField("value", .string)
    ]
  )

  public static let profile = ModelShape(
    typeName: "ContactProfile",
    fields: [
      ModelField("accountId", .identifier),
      ModelField("email", .string),
      ModelField("role", .string),
      ModelField("external", .boolean),
      ModelField("admin", .boolean),
      ModelField("owner", .boolean)
    ]
  )

  public static let contact = ModelShape(
    typeName: "Contact",
    fields: [
      ModelField("id", .identifier, required: true),
      ModelField("firstName", .string),
      ModelField("lastName", .string),
      ModelField("type", .string),
      ModelField("profiles", .objectList(profile)),
      ModelField("avatarUrl", .string),
      ModelField("timezone", .string),
      ModelField("locale", .string),
      ModelField("deleted", .boolean),
      ModelField("memberIds", .identifierList),
      ModelField("metadata", .objectList(metadataEntry)),
      ModelField("myTeam", .boolean),
      ModelField("title", .string),
      ModelField("companyName", .string),
      ModelField("phone", .string),
      ModelField("location", .string)
    ]
  )
}
