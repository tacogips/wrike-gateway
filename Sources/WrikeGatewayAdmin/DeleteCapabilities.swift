import WrikeGatewayCore

/// The nine reviewed DELETE-backed capabilities.
///
/// Every route below was confirmed against Wrike's official API v4 reference on
/// 2026-08-05. Each takes exactly one explicit opaque identifier: there is no
/// `force`, recursive, wildcard, "all", implicit-descendant, or bulk form, and
/// none of them retries automatically.
public enum DeleteCapabilities {
  /// Builds a single-identifier delete capability.
  static func makeDelete(
    id: String,
    field: String,
    inputTypeName: String,
    identifierArgument: String,
    pathTemplate: String,
    scopes: ScopeRequirement,
    deletionConfirmation: DeletionConfirmation = .responseIdentifier,
    summary: String
  ) -> CapabilityDefinition {
    CapabilityDefinition(
      id: CapabilityID(id),
      field: field,
      tier: .admin,
      operationClass: .delete,
      method: .delete,
      pathTemplate: pathTemplate,
      arguments: [
        ArgumentDefinition(
          "input",
          .inputObject(InputObjectShape(
            typeName: inputTypeName,
            fields: [
              ArgumentDefinition(
                identifierArgument,
                .identifier,
                .path(identifierArgument),
                required: true
              )
            ]
          )),
          .container,
          required: true
        )
      ],
      result: .deletion,
      deletionConfirmation: deletionConfirmation,
      scopes: scopes,
      summary: summary
    )
  }

  public static let deleteGroup = makeDelete(
    id: "groups.delete",
    field: "deleteGroup",
    inputTypeName: "DeleteGroupInput",
    identifierArgument: "groupId",
    pathTemplate: "/groups/{groupId}",
    scopes: .accountGroupReadWrite,
    summary: "Deletes one user group."
  )

  public static let deleteSpace = makeDelete(
    id: "spaces.delete",
    field: "deleteSpace",
    inputTypeName: "DeleteSpaceInput",
    identifierArgument: "spaceId",
    pathTemplate: "/spaces/{spaceId}",
    scopes: .workspaceReadWrite,
    summary: "Deletes one space."
  )

  /// `deleteFolder` and `deleteProject` map to the same upstream family but
  /// remain distinct public capabilities with distinct inputs. The shared raw
  /// path is never exposed to callers.
  public static let deleteFolder = makeDelete(
    id: "folders.delete",
    field: "deleteFolder",
    inputTypeName: "DeleteFolderInput",
    identifierArgument: "folderId",
    pathTemplate: "/folders/{folderId}",
    scopes: .workspaceReadWrite,
    summary: "Deletes one folder, moving it and its descendants to the Recycle Bin."
  )

  public static let deleteProject = makeDelete(
    id: "projects.delete",
    field: "deleteProject",
    inputTypeName: "DeleteProjectInput",
    identifierArgument: "projectId",
    pathTemplate: "/folders/{projectId}",
    scopes: .workspaceReadWrite,
    summary: "Deletes one project, moving it and its descendants to the Recycle Bin."
  )

  public static let deleteTask = makeDelete(
    id: "tasks.delete",
    field: "deleteTask",
    inputTypeName: "DeleteTaskInput",
    identifierArgument: "taskId",
    pathTemplate: "/tasks/{taskId}",
    scopes: .workspaceReadWrite,
    summary: "Deletes one task."
  )

  public static let deleteComment = makeDelete(
    id: "comments.delete",
    field: "deleteComment",
    inputTypeName: "DeleteCommentInput",
    identifierArgument: "commentId",
    pathTemplate: "/comments/{commentId}",
    scopes: .workspaceReadWrite,
    deletionConfirmation: .validatedRequestIdentifierOnEmptyData,
    summary: "Deletes one comment."
  )

  public static let deleteAttachment = makeDelete(
    id: "attachments.delete",
    field: "deleteAttachment",
    inputTypeName: "DeleteAttachmentInput",
    identifierArgument: "attachmentId",
    pathTemplate: "/attachments/{attachmentId}",
    scopes: .workspaceReadWrite,
    deletionConfirmation: .validatedRequestIdentifierOnEmptyData,
    summary: "Deletes one attachment."
  )

  public static let deleteTimelog = makeDelete(
    id: "timelogs.delete",
    field: "deleteTimelog",
    inputTypeName: "DeleteTimelogInput",
    identifierArgument: "timelogId",
    pathTemplate: "/timelogs/{timelogId}",
    scopes: .workspaceReadWrite,
    summary: "Deletes one timelog entry."
  )

  public static let deleteWebhook = makeDelete(
    id: "webhooks.delete",
    field: "deleteWebhook",
    inputTypeName: "DeleteWebhookInput",
    identifierArgument: "webhookId",
    pathTemplate: "/webhooks/{webhookId}",
    scopes: .workspaceReadWrite,
    summary: "Deletes one webhook registration."
  )

  public static let all: [CapabilityDefinition] = [
    deleteGroup,
    deleteSpace,
    deleteFolder,
    deleteProject,
    deleteTask,
    deleteComment,
    deleteAttachment,
    deleteTimelog,
    deleteWebhook
  ]
}
