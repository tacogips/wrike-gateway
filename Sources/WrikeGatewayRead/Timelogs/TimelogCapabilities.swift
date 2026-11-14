import WrikeGatewayCore

/// Reader capabilities for timelogs.
///
/// `GET /timelogs` documents `pageSize` from 1 to 1000 with an opaque
/// `nextPageToken`, so the account-scoped list is a connection.
public enum TimelogCapabilities {
  public static let maximumPageSize = 1000

  public static let timelog = ModelShape(
    typeName: "Timelog",
    fields: [
      ModelField("id", .identifier, required: true),
      ModelField("taskId", .identifier),
      ModelField("userId", .identifier),
      ModelField("categoryId", .identifier),
      ModelField("billingType", .string),
      ModelField("hours", .number),
      ModelField("createdDate", .dateTime),
      ModelField("updatedDate", .dateTime),
      ModelField("trackedDate", .date),
      ModelField("comment", .string),
      ModelField("approvalStatus", .string),
      ModelField("exportStatus", .string)
    ]
  )

  public static let list = CapabilityDefinition(
    id: CapabilityID("timelogs.list"),
    field: "timelogs",
    tier: .reader,
    operationClass: .read,
    method: .get,
    pathTemplate: "/timelogs",
    scopeVariants: [
      ScopeVariant(.account, "/timelogs"),
      ScopeVariant(.user, "/contacts/{scopeId}/timelogs"),
      ScopeVariant(.folder, "/folders/{scopeId}/timelogs"),
      ScopeVariant(.project, "/folders/{scopeId}/timelogs"),
      ScopeVariant(.task, "/tasks/{scopeId}/timelogs"),
      ScopeVariant(.category, "/timelog_categories/{scopeId}/timelogs")
    ],
    arguments: [
      ArgumentDefinition("scope", .scope, .scope),
      ArgumentDefinition("page", .page, .page),
      ArgumentDefinition("me", .boolean, .query("me")),
      ArgumentDefinition("descendants", .boolean, .query("descendants")),
      ArgumentDefinition("plainText", .boolean, .query("plainText")),
      ArgumentDefinition("trackedDate", .string, .query("trackedDate")),
      ArgumentDefinition("billingTypes", .stringList, .queryList("billingTypes"))
    ],
    result: .connection(timelog),
    scopes: .workspaceRead,
    maximumPageSize: maximumPageSize,
    summary: "Lists timelogs for the account, a user, a folder, a project, a task, or a category."
  )

  public static let get = CapabilityDefinition(
    id: CapabilityID("timelogs.get"),
    field: "timelog",
    tier: .reader,
    operationClass: .read,
    method: .get,
    pathTemplate: "/timelogs/{timelogId}",
    arguments: [
      ArgumentDefinition("id", .identifier, .path("timelogId"), required: true)
    ],
    result: .single(timelog),
    scopes: .workspaceRead,
    summary: "Returns one timelog by its opaque identifier."
  )

  public static let all: [CapabilityDefinition] = [list, get]
}
