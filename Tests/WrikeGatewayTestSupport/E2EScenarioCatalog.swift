import Foundation
import WrikeGatewayCore

/// The verification catalog: every case the live verification exercises,
/// written once and shared by the replay and live runners.
///
/// Documents are written against the schema the binaries actually print. A
/// scenario whose field or argument does not exist fails the schema-coherence
/// case in the replay runner, so the catalog cannot drift away from the
/// contract unnoticed.
public enum E2EScenarioCatalog {
  /// The twelve resource areas the capability matrix requires.
  public static let requiredAreas = [
    "contacts", "users", "groups", "accounts/spaces", "folders/projects", "tasks",
    "comments", "attachments", "timelogs", "customFields", "workflows", "webhooks"
  ]

  // MARK: - Read scenarios

  public static let readScenarios: [E2EScenario] = [
    E2EScenario(
      name: "contacts list",
      tier: .reader,
      area: "contacts",
      document: "{ contacts { id firstName lastName type } }",
      captures: [.init(key: "contactId", path: ["contacts", "0", "id"])],
      expectation: .succeeds(field: "contacts"),
      replayResponses: [WrikeFixtures.envelope(kind: "contacts", data: WrikeFixtures.contact)]
    ),
    E2EScenario(
      name: "contact by id",
      tier: .reader,
      area: "contacts",
      document: "query C($id: ID!) { contact(id: $id) { id firstName } }",
      variables: ["id": "KUAAAAAA"],
      liveVariableKeys: ["id": "contactId"],
      expectation: .succeeds(field: "contact"),
      replayResponses: [WrikeFixtures.envelope(kind: "contacts", data: WrikeFixtures.contact)]
    ),
    E2EScenario(
      name: "current user contact",
      tier: .reader,
      area: "users",
      document: "{ contacts(me: true) { id type } }",
      captures: [.init(key: "userId", path: ["contacts", "0", "id"])],
      expectation: .succeeds(field: "contacts"),
      replayResponses: [WrikeFixtures.envelope(kind: "contacts", data: WrikeFixtures.contact)]
    ),
    E2EScenario(
      name: "user by id",
      tier: .reader,
      area: "users",
      document: "query U($id: ID!) { user(id: $id) { id type } }",
      variables: ["id": "KUAAAAAA"],
      liveVariableKeys: ["id": "userId"],
      expectation: .succeeds(field: "user"),
      replayResponses: [WrikeFixtures.envelope(kind: "contacts", data: WrikeFixtures.contact)]
    ),
    E2EScenario(
      name: "user types",
      tier: .reader,
      area: "users",
      document: "{ userTypes { id title } }",
      expectation: .succeeds(field: "userTypes"),
      replayResponses: [
        WrikeFixtures.envelope(kind: "userTypes", data: "{\"id\":\"IEAAAAAAK4\",\"title\":\"Regular\"}")
      ]
    ),
    E2EScenario(
      name: "groups list",
      tier: .reader,
      area: "groups",
      document: "{ groups { id title } }",
      expectation: .succeeds(field: "groups"),
      replayResponses: [
        WrikeFixtures.envelope(kind: "groups", data: "{\"id\":\"KX000000\",\"title\":\"Team\",\"accountId\":\"IEAAAAAA\"}")
      ]
    ),
    E2EScenario(
      name: "account",
      tier: .reader,
      area: "accounts/spaces",
      document: "{ account { id name rootFolderId } }",
      captures: [.init(key: "rootFolderId", path: ["account", "rootFolderId"])],
      expectation: .succeeds(field: "account"),
      replayResponses: [
        WrikeFixtures.envelope(
          kind: "accounts",
          data: "{\"id\":\"IEAAAAAA\",\"name\":\"Example Account\",\"rootFolderId\":\"IEAAAAAAI7777777\"}"
        )
      ]
    ),
    E2EScenario(
      name: "spaces list",
      tier: .reader,
      area: "accounts/spaces",
      document: "{ spaces { id title } }",
      expectation: .succeeds(field: "spaces"),
      replayResponses: [
        WrikeFixtures.envelope(kind: "spaces", data: "{\"id\":\"IEAGIMSZ\",\"title\":\"Delivery\",\"accessType\":\"Public\"}")
      ]
    ),
    E2EScenario(
      name: "folders list",
      tier: .reader,
      area: "folders/projects",
      document: "{ folders { id title } }",
      captures: [.init(key: "folderId", path: ["folders", "0", "id"])],
      expectation: .succeeds(field: "folders"),
      replayResponses: [WrikeFixtures.envelope(kind: "folderTree", data: WrikeFixtures.folder)]
    ),
    E2EScenario(
      name: "folder by id",
      tier: .reader,
      area: "folders/projects",
      document: "query F($id: ID!) { folder(id: $id) { id title } }",
      variables: ["id": "IEAAAAAAI4AB5FNY"],
      liveVariableKeys: ["id": "folderId"],
      expectation: .succeeds(field: "folder"),
      replayResponses: [WrikeFixtures.envelope(kind: "folders", data: WrikeFixtures.folder)]
    ),
    E2EScenario(
      name: "tasks page",
      tier: .reader,
      area: "tasks",
      document: "{ tasks(page: { pageSize: 1 }) { nodes { id title status } pageInfo { resultCount nextPageToken } } }",
      captures: [.init(key: "taskId", path: ["tasks", "nodes", "0", "id"])],
      expectation: .succeedsWithPageInfo(field: "tasks"),
      replayResponses: [
        WrikeFixtures.envelope(kind: "tasks", data: WrikeFixtures.task, nextPageToken: "opaque-token")
      ]
    ),
    E2EScenario(
      name: "task by id",
      tier: .reader,
      area: "tasks",
      document: "query T($id: ID!) { task(id: $id) { id title status } }",
      variables: ["id": "IEAAAAAAKQAB5FNY"],
      liveVariableKeys: ["id": "taskId"],
      expectation: .succeeds(field: "task"),
      replayResponses: [WrikeFixtures.envelope(kind: "tasks", data: WrikeFixtures.task)]
    ),
    E2EScenario(
      name: "comments list",
      tier: .reader,
      area: "comments",
      document: "{ comments(limit: 1) { id text } }",
      expectation: .succeeds(field: "comments"),
      replayResponses: [WrikeFixtures.envelope(kind: "comments", data: WrikeFixtures.comment)]
    ),
    E2EScenario(
      name: "attachments list",
      tier: .reader,
      area: "attachments",
      document: "{ attachments { id name contentType } }",
      expectation: .succeeds(field: "attachments"),
      replayResponses: [WrikeFixtures.envelope(kind: "attachments", data: WrikeFixtures.attachment)]
    ),
    E2EScenario(
      name: "timelogs page",
      tier: .reader,
      area: "timelogs",
      document: "{ timelogs(page: { pageSize: 1 }) { nodes { id hours } pageInfo { resultCount nextPageToken } } }",
      expectation: .succeedsWithPageInfo(field: "timelogs"),
      replayResponses: [WrikeFixtures.envelope(kind: "timelogs", data: WrikeFixtures.timelog)]
    ),
    E2EScenario(
      name: "custom fields list",
      tier: .reader,
      area: "customFields",
      document: "{ customFields { id title type } }",
      expectation: .succeeds(field: "customFields"),
      replayResponses: [
        WrikeFixtures.envelope(
          kind: "customfields",
          data: "{\"id\":\"IEAAAAAAJMAAAAAB\",\"accountId\":\"IEAAAAAA\",\"title\":\"Region\",\"type\":\"Text\"}"
        )
      ]
    ),
    E2EScenario(
      name: "workflows list",
      tier: .reader,
      area: "workflows",
      document: "{ workflows { id name } }",
      expectation: .succeeds(field: "workflows"),
      replayResponses: [
        WrikeFixtures.envelope(
          kind: "workflows",
          data: "{\"id\":\"IEAAAAAAK4AAAAAB\",\"name\":\"Default Workflow\",\"standard\":true}"
        )
      ]
    ),
    E2EScenario(
      name: "webhooks list",
      tier: .reader,
      area: "webhooks",
      document: "{ webhooks { id status } }",
      expectation: .succeeds(field: "webhooks"),
      replayResponses: [WrikeFixtures.envelope(kind: "webhooks", data: WrikeFixtures.webhook)]
    )
  ]

  // MARK: - Boundary scenarios

  /// Cases that must fail, and must fail before any network call.
  ///
  /// These are the tier guarantees the whole product rests on, so they are
  /// verified through the same path as everything else rather than only by the
  /// binary-linkage tests.
  public static let boundaryScenarios: [E2EScenario] = [
    E2EScenario(
      name: "reader refuses a mutation",
      tier: .reader,
      area: "tasks",
      document: "mutation { createTask(input: { folderId: \"IEAAAAAAI4AB5FNY\", title: \"x\" }) { task { id } } }",
      expectation: .fails(.capabilityDenied)
    ),
    E2EScenario(
      name: "reader refuses a delete",
      tier: .reader,
      area: "tasks",
      document: "mutation { deleteTask(input: { taskId: \"IEAAAAAAKQAB5FNY\" }) { deletedId } }",
      expectation: .fails(.capabilityDenied)
    ),
    E2EScenario(
      name: "writer refuses a delete",
      tier: .writer,
      area: "tasks",
      document: "mutation { deleteTask(input: { taskId: \"IEAAAAAAKQAB5FNY\" }) { deletedId } }",
      expectation: .fails(.capabilityDenied)
    ),
    E2EScenario(
      name: "writer refuses a space delete",
      tier: .writer,
      area: "accounts/spaces",
      document: "mutation { deleteSpace(input: { spaceId: \"IEAGIMSZ\" }) { deletedId } }",
      expectation: .fails(.capabilityDenied)
    ),
    E2EScenario(
      name: "an unknown field is refused",
      tier: .admin,
      area: "tasks",
      document: "{ notARealField { id } }",
      expectation: .fails(.validationError)
    ),
    E2EScenario(
      name: "a raw REST escape is refused",
      tier: .admin,
      area: "tasks",
      document: "{ task(id: \"../../accounts\") { id } }",
      expectation: .fails(.validationError)
    )
  ]

  // MARK: - Mutation lifecycle

  /// The create/update/delete sequence, confined to one container it creates
  /// and then removes.
  ///
  /// Every created object has a matching cleanup step, and the container is
  /// removed last. The live runner refuses to start unless that holds.
  public static let lifecycle = E2ELifecycle(
    name: "verification container lifecycle",
    steps: [
      .init(
        name: "create the container folder",
        tier: .writer,
        document: """
          mutation { createFolder(input: { parentFolderId: "{{rootFolderId}}", \
          title: "wrike-gateway verification" }) { folder { id title parentIds } } }
          """,
        field: "createFolder",
        captures: (key: "containerId", path: ["folder", "id"]),
        replayResponse: WrikeFixtures.envelope(kind: "folders", data: WrikeFixtures.folder)
      ),
      .init(
        name: "create a task in the container",
        tier: .writer,
        document: """
          mutation { createTask(input: { folderId: "{{containerId}}", \
          title: "verification task" }) { task { id title parentIds } } }
          """,
        field: "createTask",
        captures: (key: "taskId", path: ["task", "id"]),
        replayResponse: WrikeFixtures.envelope(kind: "tasks", data: WrikeFixtures.task)
      ),
      .init(
        name: "update the task",
        tier: .writer,
        document: """
          mutation { updateTask(input: { taskId: "{{taskId}}", \
          description: "updated by verification" }) { task { id } } }
          """,
        field: "updateTask",
        replayResponse: WrikeFixtures.envelope(kind: "tasks", data: WrikeFixtures.task)
      ),
      .init(
        name: "comment on the task",
        tier: .writer,
        document: """
          mutation { createComment(scope: { taskId: "{{taskId}}" }, \
          input: { text: "verification comment" }) { comment { id taskId } } }
          """,
        field: "createComment",
        captures: (key: "commentId", path: ["comment", "id"]),
        replayResponse: WrikeFixtures.envelope(kind: "comments", data: WrikeFixtures.comment)
      ),
      .init(
        name: "log time on the task",
        tier: .writer,
        document: """
          mutation { createTimelog(input: { taskId: "{{taskId}}", hours: 0.25, \
          trackedDate: "2026-08-06", comment: "verification" }) { timelog { id taskId } } }
          """,
        field: "createTimelog",
        captures: (key: "timelogId", path: ["timelog", "id"]),
        replayResponse: WrikeFixtures.envelope(kind: "timelogs", data: WrikeFixtures.timelog)
      ),
      .init(
        name: "upload an attachment to the task",
        tier: .writer,
        document: """
          mutation { uploadTaskAttachment(input: { taskId: "{{taskId}}", \
          filePath: "{{uploadFilePath}}" }) { attachment { id taskId name size } } }
          """,
        field: "uploadTaskAttachment",
        captures: (key: "attachmentId", path: ["attachment", "id"]),
        replayResponse: WrikeFixtures.envelope(kind: "attachments", data: WrikeFixtures.attachment)
      ),
      .init(
        name: "delete the attachment",
        tier: .admin,
        document: "mutation { deleteAttachment(input: { attachmentId: \"{{attachmentId}}\" }) { deletedId } }",
        field: "deleteAttachment",
        replayResponse: "{\"kind\":\"attachments\",\"data\":[]}",
        isCleanup: true
      ),
      .init(
        name: "delete the timelog",
        tier: .admin,
        document: "mutation { deleteTimelog(input: { timelogId: \"{{timelogId}}\" }) { deletedId } }",
        field: "deleteTimelog",
        replayResponse: WrikeFixtures.envelope(kind: "timelogs", data: WrikeFixtures.timelog),
        isCleanup: true
      ),
      .init(
        name: "delete the comment",
        tier: .admin,
        document: "mutation { deleteComment(input: { commentId: \"{{commentId}}\" }) { deletedId } }",
        field: "deleteComment",
        replayResponse: "{\"kind\":\"comments\",\"data\":[]}",
        isCleanup: true
      ),
      .init(
        name: "delete the task",
        tier: .admin,
        document: "mutation { deleteTask(input: { taskId: \"{{taskId}}\" }) { deletedId } }",
        field: "deleteTask",
        replayResponse: WrikeFixtures.envelope(kind: "tasks", data: WrikeFixtures.task),
        isCleanup: true
      ),
      .init(
        name: "delete the container folder",
        tier: .admin,
        document: "mutation { deleteFolder(input: { folderId: \"{{containerId}}\" }) { deletedId } }",
        field: "deleteFolder",
        replayResponse: WrikeFixtures.envelope(kind: "folders", data: WrikeFixtures.folder),
        isCleanup: true
      )
    ]
  )

  /// Every scenario the replay runner executes.
  public static var allScenarios: [E2EScenario] { readScenarios + boundaryScenarios }
}
