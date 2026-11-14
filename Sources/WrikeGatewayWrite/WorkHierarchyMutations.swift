import WrikeGatewayCore
import WrikeGatewayRead

/// Writer capabilities for spaces, folders, projects, and tasks.
public enum WorkHierarchyMutations {
  public static let createSpace = CapabilityDefinition(
    id: CapabilityID("spaces.create"),
    field: "createSpace",
    tier: .writer,
    operationClass: .create,
    method: .post,
    pathTemplate: "/spaces",
    arguments: [
      ArgumentDefinition(
        "input",
        .inputObject(InputObjectShape(
          typeName: "CreateSpaceInput",
          fields: [
            ArgumentDefinition("title", .string, .bodyForm("title"), required: true),
            ArgumentDefinition(
              "accessType",
              .enumeration("SpaceAccessType", ["Personal", "Private", "Public"]),
              .bodyForm("accessType")
            ),
            ArgumentDefinition("description", .string, .bodyForm("description")),
            ArgumentDefinition("memberIds", .identifierList, .bodyForm("members"))
          ]
        )),
        .container,
        required: true
      )
    ],
    result: .payload(field: "space", SpaceCapabilities.space),
    scopes: .workspaceReadWrite,
    summary: "Creates a space."
  )

  public static let updateSpace = CapabilityDefinition(
    id: CapabilityID("spaces.update"),
    field: "updateSpace",
    tier: .writer,
    operationClass: .update,
    method: .put,
    pathTemplate: "/spaces/{spaceId}",
    arguments: [
      ArgumentDefinition(
        "input",
        .inputObject(InputObjectShape(
          typeName: "UpdateSpaceInput",
          fields: [
            ArgumentDefinition("spaceId", .identifier, .path("spaceId"), required: true),
            ArgumentDefinition("title", .string, .bodyForm("title")),
            ArgumentDefinition("description", .string, .bodyForm("description")),
            ArgumentDefinition("archived", .boolean, .bodyForm("archived")),
            ArgumentDefinition("addMemberIds", .identifierList, .bodyForm("addMembers")),
            ArgumentDefinition("removeMemberIds", .identifierList, .bodyForm("removeMembers"))
          ]
        )),
        .container,
        required: true
      )
    ],
    result: .payload(field: "space", SpaceCapabilities.space),
    scopes: .workspaceReadWrite,
    summary: "Updates a space's fields or named membership."
  )

  public static let createFolder = CapabilityDefinition(
    id: CapabilityID("folders.create"),
    field: "createFolder",
    tier: .writer,
    operationClass: .create,
    method: .post,
    pathTemplate: "/folders/{parentFolderId}/folders",
    arguments: [
      ArgumentDefinition(
        "input",
        .inputObject(InputObjectShape(
          typeName: "CreateFolderInput",
          fields: [
            ArgumentDefinition("parentFolderId", .identifier, .path("parentFolderId"), required: true),
            ArgumentDefinition("title", .string, .bodyForm("title"), required: true),
            ArgumentDefinition("description", .string, .bodyForm("description")),
            ArgumentDefinition("shareIds", .identifierList, .bodyForm("shareds"))
          ]
        )),
        .container,
        required: true
      )
    ],
    result: .payload(field: "folder", FolderCapabilities.folder),
    scopes: .workspaceReadWrite,
    summary: "Creates a folder under an explicit parent folder."
  )

  public static let updateFolder = CapabilityDefinition(
    id: CapabilityID("folders.update"),
    field: "updateFolder",
    tier: .writer,
    operationClass: .update,
    method: .put,
    pathTemplate: "/folders/{folderId}",
    arguments: [
      ArgumentDefinition(
        "input",
        .inputObject(InputObjectShape(
          typeName: "UpdateFolderInput",
          fields: [
            ArgumentDefinition("folderId", .identifier, .path("folderId"), required: true),
            ArgumentDefinition("title", .string, .bodyForm("title")),
            ArgumentDefinition("description", .string, .bodyForm("description")),
            ArgumentDefinition("addShareIds", .identifierList, .bodyForm("addShareds")),
            ArgumentDefinition("removeShareIds", .identifierList, .bodyForm("removeShareds"))
          ]
        )),
        .container,
        required: true
      )
    ],
    result: .payload(field: "folder", FolderCapabilities.folder),
    scopes: .workspaceReadWrite,
    summary: "Updates a folder's fields or named sharing."
  )

  public static let copyFolder = CapabilityDefinition(
    id: CapabilityID("folders.copy"),
    field: "copyFolder",
    tier: .writer,
    operationClass: .create,
    method: .post,
    pathTemplate: "/copy_folder/{folderId}",
    arguments: [
      ArgumentDefinition(
        "input",
        .inputObject(InputObjectShape(
          typeName: "CopyFolderInput",
          fields: [
            ArgumentDefinition("folderId", .identifier, .path("folderId"), required: true),
            ArgumentDefinition("parentId", .identifier, .bodyForm("parent"), required: true),
            ArgumentDefinition("title", .string, .bodyForm("title"), required: true),
            ArgumentDefinition("copyDescriptions", .boolean, .bodyForm("copyDescriptions")),
            ArgumentDefinition("copyAssignees", .boolean, .bodyForm("copyResponsibles")),
            ArgumentDefinition("copyAttachments", .boolean, .bodyForm("copyAttachments"))
          ]
        )),
        .container,
        required: true
      )
    ],
    result: .payload(field: "folder", FolderCapabilities.folder),
    scopes: .workspaceReadWrite,
    summary: "Copies a folder into an explicit parent folder."
  )

  public static let createProject = CapabilityDefinition(
    id: CapabilityID("projects.create"),
    field: "createProject",
    tier: .writer,
    operationClass: .create,
    method: .post,
    pathTemplate: "/folders/{parentFolderId}/folders",
    arguments: [
      ArgumentDefinition(
        "input",
        .inputObject(InputObjectShape(
          typeName: "CreateProjectInput",
          fields: [
            ArgumentDefinition("parentFolderId", .identifier, .path("parentFolderId"), required: true),
            ArgumentDefinition("title", .string, .bodyForm("title"), required: true),
            ArgumentDefinition("description", .string, .bodyForm("description")),
            ArgumentDefinition("ownerIds", .identifierList, .bodyForm("project.ownerIds")),
            ArgumentDefinition("startDate", .string, .bodyForm("project.startDate")),
            ArgumentDefinition("endDate", .string, .bodyForm("project.endDate"))
          ]
        )),
        .container,
        required: true
      )
    ],
    result: .payload(field: "project", ProjectCapabilities.project),
    scopes: .workspaceReadWrite,
    summary: "Creates a project under an explicit parent folder."
  )

  public static let updateProject = CapabilityDefinition(
    id: CapabilityID("projects.update"),
    field: "updateProject",
    tier: .writer,
    operationClass: .update,
    method: .put,
    pathTemplate: "/folders/{projectId}",
    arguments: [
      ArgumentDefinition(
        "input",
        .inputObject(InputObjectShape(
          typeName: "UpdateProjectInput",
          fields: [
            ArgumentDefinition("projectId", .identifier, .path("projectId"), required: true),
            ArgumentDefinition("title", .string, .bodyForm("title")),
            ArgumentDefinition("description", .string, .bodyForm("description")),
            ArgumentDefinition("ownerIds", .identifierList, .bodyForm("project.ownerIds")),
            ArgumentDefinition("startDate", .string, .bodyForm("project.startDate")),
            ArgumentDefinition("endDate", .string, .bodyForm("project.endDate"))
          ]
        )),
        .container,
        required: true
      )
    ],
    result: .payload(field: "project", ProjectCapabilities.project),
    scopes: .workspaceReadWrite,
    summary: "Updates a project's fields."
  )

  public static let createTask = CapabilityDefinition(
    id: CapabilityID("tasks.create"),
    field: "createTask",
    tier: .writer,
    operationClass: .create,
    method: .post,
    pathTemplate: "/folders/{folderId}/tasks",
    arguments: [
      ArgumentDefinition(
        "input",
        .inputObject(InputObjectShape(
          typeName: "CreateTaskInput",
          fields: [
            ArgumentDefinition("folderId", .identifier, .path("folderId"), required: true),
            ArgumentDefinition("title", .string, .bodyForm("title"), required: true),
            ArgumentDefinition("description", .string, .bodyForm("description")),
            ArgumentDefinition(
              "status",
              .enumeration("TaskStatusInput", ["Active", "Completed", "Deferred", "Cancelled"]),
              .bodyForm("status")
            ),
            ArgumentDefinition(
              "importance",
              .enumeration("TaskImportanceInput", ["High", "Normal", "Low"]),
              .bodyForm("importance")
            ),
            ArgumentDefinition("responsibleIds", .identifierList, .bodyForm("responsibles")),
            ArgumentDefinition("followerIds", .identifierList, .bodyForm("followers"))
          ]
        )),
        .container,
        required: true
      )
    ],
    result: .payload(field: "task", TaskCapabilities.task),
    scopes: .workspaceReadWrite,
    summary: "Creates a task in an explicit folder or project."
  )

  public static let updateTask = CapabilityDefinition(
    id: CapabilityID("tasks.update"),
    field: "updateTask",
    tier: .writer,
    operationClass: .update,
    method: .put,
    pathTemplate: "/tasks/{taskId}",
    arguments: [
      ArgumentDefinition(
        "input",
        .inputObject(InputObjectShape(
          typeName: "UpdateTaskInput",
          fields: [
            ArgumentDefinition("taskId", .identifier, .path("taskId"), required: true),
            ArgumentDefinition("title", .string, .bodyForm("title")),
            ArgumentDefinition("description", .string, .bodyForm("description")),
            ArgumentDefinition(
              "status",
              .enumeration("TaskStatusInput", ["Active", "Completed", "Deferred", "Cancelled"]),
              .bodyForm("status")
            ),
            ArgumentDefinition(
              "importance",
              .enumeration("TaskImportanceInput", ["High", "Normal", "Low"]),
              .bodyForm("importance")
            ),
            ArgumentDefinition("addResponsibleIds", .identifierList, .bodyForm("addResponsibles")),
            ArgumentDefinition("removeResponsibleIds", .identifierList, .bodyForm("removeResponsibles")),
            ArgumentDefinition("customStatusId", .identifier, .bodyForm("customStatus"))
          ]
        )),
        .container,
        required: true
      )
    ],
    result: .payload(field: "task", TaskCapabilities.task),
    scopes: .workspaceReadWrite,
    summary: "Updates a task's fields or named assignees."
  )

  public static let all: [CapabilityDefinition] = [
    createSpace,
    updateSpace,
    createFolder,
    updateFolder,
    copyFolder,
    createProject,
    updateProject,
    createTask,
    updateTask
  ]
}
