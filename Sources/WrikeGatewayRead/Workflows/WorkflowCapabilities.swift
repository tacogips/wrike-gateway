import WrikeGatewayCore

/// Reader capabilities for workflows.
///
/// Wrike API v4 exposes only the account-level `GET /workflows`; there is no
/// documented single-workflow GET. `workflows.get` is therefore recorded as
/// `unsupported` in the capability matrix and is not registered here, rather
/// than being substituted with a client-side filter over the full list.
public enum WorkflowCapabilities {
  public static let customStatus = ModelShape(
    typeName: "CustomStatus",
    fields: [
      ModelField("id", .identifier, required: true),
      ModelField("name", .string),
      ModelField("standardName", .boolean),
      ModelField("color", .string),
      ModelField("standard", .boolean),
      ModelField("group", .string),
      ModelField("hidden", .boolean)
    ]
  )

  public static let workflow = ModelShape(
    typeName: "Workflow",
    fields: [
      ModelField("id", .identifier, required: true),
      ModelField("name", .string),
      ModelField("standard", .boolean),
      ModelField("hidden", .boolean),
      ModelField("customStatuses", .objectList(customStatus))
    ]
  )

  public static let list = CapabilityDefinition(
    id: CapabilityID("workflows.list"),
    field: "workflows",
    tier: .reader,
    operationClass: .read,
    method: .get,
    pathTemplate: "/workflows",
    result: .list(workflow),
    scopes: ScopeRequirement(
      accepted: ["Default", "amReadOnlyWorkflow", "amReadWriteWorkflow", "wsReadOnly", "wsReadWrite"],
      recommended: "amReadOnlyWorkflow"
    ),
    summary: "Lists the workflows configured for the current account."
  )

  public static let all: [CapabilityDefinition] = [list]
}
