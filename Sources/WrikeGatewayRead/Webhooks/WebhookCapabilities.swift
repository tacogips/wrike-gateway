import WrikeGatewayCore

/// Reader capabilities for webhook registrations.
///
/// This binary inspects and manages registrations only; it never hosts callback
/// delivery. The webhook signing secret is not part of the stable model, so it
/// cannot reach output even when a caller selects every field.
public enum WebhookCapabilities {
  public static let webhook = ModelShape(
    typeName: "Webhook",
    fields: [
      ModelField("id", .identifier, required: true),
      ModelField("accountId", .identifier),
      ModelField("folderId", .identifier),
      ModelField("spaceId", .identifier),
      ModelField("hookUrl", .string),
      ModelField("status", .string),
      ModelField("events", .stringList),
      ModelField("recursive", .boolean)
    ]
  )

  public static let list = CapabilityDefinition(
    id: CapabilityID("webhooks.list"),
    field: "webhooks",
    tier: .reader,
    operationClass: .read,
    method: .get,
    pathTemplate: "/webhooks",
    result: .list(webhook),
    scopes: .workspaceRead,
    summary: "Lists webhook registrations visible to this API application."
  )

  public static let get = CapabilityDefinition(
    id: CapabilityID("webhooks.get"),
    field: "webhook",
    tier: .reader,
    operationClass: .read,
    method: .get,
    pathTemplate: "/webhooks/{webhookId}",
    arguments: [
      ArgumentDefinition("id", .identifier, .path("webhookId"), required: true)
    ],
    result: .single(webhook),
    scopes: .workspaceRead,
    summary: "Returns one webhook registration by its opaque identifier."
  )

  public static let all: [CapabilityDefinition] = [list, get]
}
