import WrikeGatewayCore

/// Reader capabilities for contacts.
///
/// Wrike API v4 documents no pagination parameters on `GET /contacts`, so this
/// family exposes a plain list rather than a connection. Account people are
/// reached here through a person-type filter; the initial contract deliberately
/// registers no `users` collection alias.
public enum ContactCapabilities {
  public static let list = CapabilityDefinition(
    id: CapabilityID("contacts.list"),
    field: "contacts",
    tier: .reader,
    operationClass: .read,
    method: .get,
    pathTemplate: "/contacts",
    arguments: [
      ArgumentDefinition("me", .boolean, .query("me")),
      ArgumentDefinition("deleted", .boolean, .query("deleted")),
      ArgumentDefinition("types", .stringList, .queryList("types"))
    ],
    result: .list(ContactModels.contact),
    scopes: .workspaceRead,
    summary: "Lists contacts in the current account, optionally filtered by type."
  )

  public static let get = CapabilityDefinition(
    id: CapabilityID("contacts.get"),
    field: "contact",
    tier: .reader,
    operationClass: .read,
    method: .get,
    pathTemplate: "/contacts/{contactId}",
    arguments: [
      ArgumentDefinition("id", .identifier, .path("contactId"), required: true)
    ],
    result: .single(ContactModels.contact),
    scopes: .workspaceRead,
    summary: "Returns one contact by its opaque identifier."
  )

  public static let all: [CapabilityDefinition] = [list, get]
}
