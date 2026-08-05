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

  /// Bill and cost rate history for one or more contacts.
  ///
  /// Route and filters follow the official reference for
  /// `GET /contacts/{contactIds}/contacts_history`, which accepts an
  /// `updatedDate` instant range and a `fields` selection of `billRate` and
  /// `costRate`. Several contacts are addressed through one comma-separated
  /// path segment, so `ids` is a list bound to `{contactIds}`.
  public static let historyFields = ["billRate", "costRate"]

  public static let history = CapabilityDefinition(
    id: CapabilityID("contacts.history"),
    field: "contactsHistory",
    tier: .reader,
    operationClass: .read,
    method: .get,
    pathTemplate: "/contacts/{contactIds}/contacts_history",
    arguments: [
      HistoryModels.identifierArgument(placeholder: "contactIds")
    ] + HistoryModels.filterArguments(
      fieldEnum: "ContactHistoryField",
      values: historyFields
    ),
    result: .list(ContactModels.changeHistory),
    scopes: .workspaceRead,
    summary: "Returns bill and cost rate history for the given contacts."
  )

  public static let all: [CapabilityDefinition] = [list, get, history]
}
