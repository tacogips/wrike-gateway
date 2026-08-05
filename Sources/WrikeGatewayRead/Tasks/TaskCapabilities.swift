import WrikeGatewayCore

/// Reader capabilities for tasks.
///
/// `GET /tasks` is the only reader capability in this project with a documented
/// pagination contract of `pageSize` up to 1000 plus an opaque `nextPageToken`,
/// so it is the one modelled as a connection.
public enum TaskCapabilities {
  public static let maximumPageSize = 1000

  public static let taskDates = ModelShape(
    typeName: "TaskDates",
    fields: [
      ModelField("type", .string),
      ModelField("duration", .integer),
      ModelField("start", .dateTime),
      ModelField("due", .dateTime),
      ModelField("workOnWeekends", .boolean)
    ]
  )

  public static let task = ModelShape(
    typeName: "Task",
    fields: [
      ModelField("id", .identifier, required: true),
      ModelField("accountId", .identifier),
      ModelField("title", .string),
      ModelField("description", .string),
      ModelField("briefDescription", .string),
      ModelField("status", .string),
      ModelField("importance", .string),
      ModelField("createdDate", .dateTime),
      ModelField("updatedDate", .dateTime),
      ModelField("completedDate", .dateTime),
      ModelField("dates", .object(taskDates)),
      ModelField("scope", .string),
      ModelField("authorIds", .identifierList),
      ModelField("responsibleIds", .identifierList),
      ModelField("customStatusId", .identifier),
      ModelField("hasAttachments", .boolean),
      ModelField("permalink", .string),
      ModelField("priority", .string),
      ModelField("followedByMe", .boolean),
      ModelField("followerIds", .identifierList),
      ModelField("superTaskIds", .identifierList),
      ModelField("subTaskIds", .identifierList),
      ModelField("dependencyIds", .identifierList),
      ModelField("parentIds", .identifierList),
      ModelField("superParentIds", .identifierList),
      ModelField("sharedIds", .identifierList),
      ModelField("customFields", .objectList(FolderCapabilities.customFieldValue)),
      ModelField("metadata", .objectList(ContactModels.metadataEntry))
    ]
  )

  public static let list = CapabilityDefinition(
    id: CapabilityID("tasks.list"),
    field: "tasks",
    tier: .reader,
    operationClass: .read,
    method: .get,
    pathTemplate: "/tasks",
    scopeVariants: [
      ScopeVariant(.account, "/tasks"),
      ScopeVariant(.folder, "/folders/{scopeId}/tasks"),
      ScopeVariant(.project, "/folders/{scopeId}/tasks"),
      ScopeVariant(.space, "/spaces/{scopeId}/tasks")
    ],
    arguments: [
      ArgumentDefinition("scope", .scope, .scope),
      ArgumentDefinition("page", .page, .page),
      ArgumentDefinition(
        "status",
        .enumeration("TaskStatus", ["Active", "Completed", "Deferred", "Cancelled"]),
        .query("status")
      ),
      ArgumentDefinition(
        "importance",
        .enumeration("TaskImportance", ["High", "Normal", "Low"]),
        .query("importance")
      ),
      ArgumentDefinition("title", .string, .query("title")),
      ArgumentDefinition("responsibles", .identifierList, .queryList("responsibles")),
      ArgumentDefinition("subTasks", .boolean, .query("subTasks")),
      ArgumentDefinition("descendants", .boolean, .query("descendants"))
    ],
    result: .connection(task),
    scopes: .workspaceRead,
    maximumPageSize: maximumPageSize,
    summary: "Searches tasks in the account, a folder, a project, or a space."
  )

  public static let get = CapabilityDefinition(
    id: CapabilityID("tasks.get"),
    field: "task",
    tier: .reader,
    operationClass: .read,
    method: .get,
    pathTemplate: "/tasks/{taskId}",
    arguments: [
      ArgumentDefinition("id", .identifier, .path("taskId"), required: true)
    ],
    result: .single(task),
    scopes: .workspaceRead,
    summary: "Returns one task by its opaque identifier."
  )

  public static let changeHistory = ModelShape(
    typeName: "TaskChangeHistory",
    fields: [
      ModelField("id", .identifier, required: true),
      ModelField("plannedCost", .objectList(HistoryModels.budgetMetricItem)),
      ModelField("plannedFees", .objectList(HistoryModels.budgetMetricItem)),
      ModelField("actualCost", .objectList(HistoryModels.budgetMetricItem)),
      ModelField("actualFees", .objectList(HistoryModels.budgetMetricItem))
    ]
  )

  /// Budget-metric history for one or more tasks.
  ///
  /// Route and filters follow the official reference for
  /// `GET /tasks/{taskIds}/tasks_history`, which accepts an `updatedDate`
  /// instant range and a `fields` selection of `plannedCost`, `plannedFees`,
  /// `actualCost`, and `actualFees`. Unlike folders, tasks carry the metrics at
  /// the top level rather than under a project object.
  /// Tasks carry no `budget` metric; only folders and projects do.
  public static let historyFields = ["plannedCost", "plannedFees", "actualCost", "actualFees"]

  public static let history = CapabilityDefinition(
    id: CapabilityID("tasks.history"),
    field: "tasksHistory",
    tier: .reader,
    operationClass: .read,
    method: .get,
    pathTemplate: "/tasks/{taskIds}/tasks_history",
    arguments: [
      HistoryModels.identifierArgument(placeholder: "taskIds")
    ] + HistoryModels.filterArguments(
      fieldEnum: "TaskHistoryField",
      values: historyFields
    ),
    result: .list(changeHistory),
    scopes: .workspaceRead,
    summary: "Returns budget-metric history for the given tasks."
  )

  public static let all: [CapabilityDefinition] = [list, get, history]
}
