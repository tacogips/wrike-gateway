import WrikeGatewayCore
import WrikeGatewayRead

/// Writer capabilities for comments, attachments, timelogs, custom fields,
/// workflows, and webhook state.
public enum CollaborationMutations {
  public static let createComment = CapabilityDefinition(
    id: CapabilityID("comments.create"),
    field: "createComment",
    tier: .writer,
    operationClass: .create,
    method: .post,
    // A scope is required, so the default template is intentionally empty and
    // the planner rejects an unscoped call before any request is built.
    pathTemplate: "",
    scopeVariants: [
      ScopeVariant(.task, "/tasks/{scopeId}/comments"),
      ScopeVariant(.folder, "/folders/{scopeId}/comments"),
      ScopeVariant(.project, "/folders/{scopeId}/comments")
    ],
    arguments: [
      ArgumentDefinition("scope", .scope, .scope, required: true),
      ArgumentDefinition(
        "input",
        .inputObject(InputObjectShape(
          typeName: "CreateCommentInput",
          fields: [
            ArgumentDefinition("text", .string, .bodyForm("text"), required: true),
            ArgumentDefinition("plainText", .boolean, .bodyForm("plainText"))
          ]
        )),
        .container,
        required: true
      )
    ],
    result: .payload(field: "comment", CommentCapabilities.comment),
    scopes: .workspaceReadWrite,
    summary: "Creates a comment on an explicit task, folder, or project."
  )

  public static let updateComment = CapabilityDefinition(
    id: CapabilityID("comments.update"),
    field: "updateComment",
    tier: .writer,
    operationClass: .update,
    method: .put,
    pathTemplate: "/comments/{commentId}",
    arguments: [
      ArgumentDefinition(
        "input",
        .inputObject(InputObjectShape(
          typeName: "UpdateCommentInput",
          fields: [
            ArgumentDefinition("commentId", .identifier, .path("commentId"), required: true),
            ArgumentDefinition("text", .string, .bodyForm("text"), required: true),
            ArgumentDefinition("plainText", .boolean, .bodyForm("plainText"))
          ]
        )),
        .container,
        required: true
      )
    ],
    result: .payload(field: "comment", CommentCapabilities.comment),
    scopes: .workspaceReadWrite,
    summary: "Updates a comment's text."
  )

  public static let uploadTaskAttachment = CapabilityDefinition(
    id: CapabilityID("attachments.upload.task"),
    field: "uploadTaskAttachment",
    tier: .writer,
    operationClass: .create,
    method: .post,
    pathTemplate: "/tasks/{taskId}/attachments",
    arguments: [
      ArgumentDefinition(
        "input",
        .inputObject(InputObjectShape(
          typeName: "UploadTaskAttachmentInput",
          fields: [
            ArgumentDefinition("taskId", .identifier, .path("taskId"), required: true),
            // The adapter validates that the path names a readable regular file
            // before opening it. Bytes stream from disk and never enter a model,
            // a diagnostic, or a log.
            ArgumentDefinition("filePath", .string, .filePath, required: true)
          ]
        )),
        .container,
        required: true
      )
    ],
    result: .payload(field: "attachment", AttachmentCapabilities.attachment),
    scopes: .workspaceReadWrite,
    summary: "Uploads a local file as a task attachment."
  )

  public static let uploadFolderAttachment = CapabilityDefinition(
    id: CapabilityID("attachments.upload.folder"),
    field: "uploadFolderAttachment",
    tier: .writer,
    operationClass: .create,
    method: .post,
    pathTemplate: "/folders/{folderId}/attachments",
    arguments: [
      ArgumentDefinition(
        "input",
        .inputObject(InputObjectShape(
          typeName: "UploadFolderAttachmentInput",
          fields: [
            ArgumentDefinition("folderId", .identifier, .path("folderId"), required: true),
            ArgumentDefinition("filePath", .string, .filePath, required: true)
          ]
        )),
        .container,
        required: true
      )
    ],
    result: .payload(field: "attachment", AttachmentCapabilities.attachment),
    scopes: .workspaceReadWrite,
    summary: "Uploads a local file as a folder or project attachment."
  )

  public static let updateAttachment = CapabilityDefinition(
    id: CapabilityID("attachments.update"),
    field: "updateAttachment",
    tier: .writer,
    operationClass: .update,
    method: .put,
    pathTemplate: "/attachments/{attachmentId}",
    arguments: [
      ArgumentDefinition(
        "input",
        .inputObject(InputObjectShape(
          typeName: "UpdateAttachmentInput",
          fields: [
            ArgumentDefinition("attachmentId", .identifier, .path("attachmentId"), required: true),
            ArgumentDefinition("filePath", .string, .filePath, required: true)
          ]
        )),
        .container,
        required: true
      )
    ],
    result: .payload(field: "attachment", AttachmentCapabilities.attachment),
    scopes: .workspaceReadWrite,
    summary: "Uploads a new version of an existing attachment."
  )

  public static let createTimelog = CapabilityDefinition(
    id: CapabilityID("timelogs.create"),
    field: "createTimelog",
    tier: .writer,
    operationClass: .create,
    method: .post,
    pathTemplate: "/tasks/{taskId}/timelogs",
    arguments: [
      ArgumentDefinition(
        "input",
        .inputObject(InputObjectShape(
          typeName: "CreateTimelogInput",
          fields: [
            ArgumentDefinition("taskId", .identifier, .path("taskId"), required: true),
            ArgumentDefinition("hours", .number, .bodyForm("hours"), required: true),
            ArgumentDefinition("trackedDate", .string, .bodyForm("trackedDate"), required: true),
            ArgumentDefinition("comment", .string, .bodyForm("comment"), required: true),
            ArgumentDefinition("categoryId", .identifier, .bodyForm("categoryId"))
          ]
        )),
        .container,
        required: true
      )
    ],
    result: .payload(field: "timelog", TimelogCapabilities.timelog),
    scopes: .workspaceReadWrite,
    summary: "Records a timelog entry against an explicit task."
  )

  public static let updateTimelog = CapabilityDefinition(
    id: CapabilityID("timelogs.update"),
    field: "updateTimelog",
    tier: .writer,
    operationClass: .update,
    method: .put,
    pathTemplate: "/timelogs/{timelogId}",
    arguments: [
      ArgumentDefinition(
        "input",
        .inputObject(InputObjectShape(
          typeName: "UpdateTimelogInput",
          fields: [
            ArgumentDefinition("timelogId", .identifier, .path("timelogId"), required: true),
            ArgumentDefinition("hours", .number, .bodyForm("hours")),
            ArgumentDefinition("trackedDate", .string, .bodyForm("trackedDate")),
            ArgumentDefinition("comment", .string, .bodyForm("comment")),
            ArgumentDefinition("categoryId", .identifier, .bodyForm("categoryId"))
          ]
        )),
        .container,
        required: true
      )
    ],
    result: .payload(field: "timelog", TimelogCapabilities.timelog),
    scopes: .workspaceReadWrite,
    summary: "Updates a timelog entry."
  )

  public static let createCustomField = CapabilityDefinition(
    id: CapabilityID("customFields.create"),
    field: "createCustomField",
    tier: .writer,
    operationClass: .create,
    method: .post,
    pathTemplate: "/customfields",
    arguments: [
      ArgumentDefinition(
        "input",
        .inputObject(InputObjectShape(
          typeName: "CreateCustomFieldInput",
          fields: [
            ArgumentDefinition("title", .string, .bodyForm("title"), required: true),
            ArgumentDefinition("type", .string, .bodyForm("type"), required: true),
            ArgumentDefinition("spaceId", .identifier, .bodyForm("spaceId")),
            ArgumentDefinition("shareIds", .identifierList, .bodyForm("shareds"))
          ]
        )),
        .container,
        required: true
      )
    ],
    result: .payload(field: "customField", CustomFieldCapabilities.customField),
    scopes: .workspaceReadWrite,
    summary: "Creates an account or space custom field."
  )

  public static let updateCustomField = CapabilityDefinition(
    id: CapabilityID("customFields.update"),
    field: "updateCustomField",
    tier: .writer,
    operationClass: .update,
    method: .put,
    pathTemplate: "/customfields/{customFieldId}",
    arguments: [
      ArgumentDefinition(
        "input",
        .inputObject(InputObjectShape(
          typeName: "UpdateCustomFieldInput",
          fields: [
            ArgumentDefinition("customFieldId", .identifier, .path("customFieldId"), required: true),
            ArgumentDefinition("title", .string, .bodyForm("title")),
            ArgumentDefinition("addShareIds", .identifierList, .bodyForm("addShareds")),
            ArgumentDefinition("removeShareIds", .identifierList, .bodyForm("removeShareds"))
          ]
        )),
        .container,
        required: true
      )
    ],
    result: .payload(field: "customField", CustomFieldCapabilities.customField),
    scopes: .workspaceReadWrite,
    summary: "Updates a custom field definition or its named sharing."
  )

  public static let createWorkflow = CapabilityDefinition(
    id: CapabilityID("workflows.create"),
    field: "createWorkflow",
    tier: .writer,
    operationClass: .create,
    method: .post,
    pathTemplate: "/workflows",
    arguments: [
      ArgumentDefinition(
        "input",
        .inputObject(InputObjectShape(
          typeName: "CreateWorkflowInput",
          fields: [
            ArgumentDefinition("name", .string, .bodyForm("name"), required: true)
          ]
        )),
        .container,
        required: true
      )
    ],
    result: .payload(field: "workflow", WorkflowCapabilities.workflow),
    scopes: ScopeRequirement(
      accepted: ["Default", "amReadWriteWorkflow", "wsReadWrite"],
      recommended: "amReadWriteWorkflow"
    ),
    summary: "Creates an account workflow."
  )

  public static let updateWorkflow = CapabilityDefinition(
    id: CapabilityID("workflows.update"),
    field: "updateWorkflow",
    tier: .writer,
    operationClass: .update,
    method: .put,
    pathTemplate: "/workflows/{workflowId}",
    arguments: [
      ArgumentDefinition(
        "input",
        .inputObject(InputObjectShape(
          typeName: "UpdateWorkflowInput",
          fields: [
            ArgumentDefinition("workflowId", .identifier, .path("workflowId"), required: true),
            ArgumentDefinition("name", .string, .bodyForm("name")),
            ArgumentDefinition("hidden", .boolean, .bodyForm("hidden"))
          ]
        )),
        .container,
        required: true
      )
    ],
    result: .payload(field: "workflow", WorkflowCapabilities.workflow),
    scopes: ScopeRequirement(
      accepted: ["Default", "amReadWriteWorkflow", "wsReadWrite"],
      recommended: "amReadWriteWorkflow"
    ),
    summary: "Updates an account workflow."
  )

  public static let createWebhook = CapabilityDefinition(
    id: CapabilityID("webhooks.create"),
    field: "createWebhook",
    tier: .writer,
    operationClass: .create,
    method: .post,
    pathTemplate: "/webhooks",
    scopeVariants: [
      ScopeVariant(.account, "/webhooks"),
      ScopeVariant(.folder, "/folders/{scopeId}/webhooks"),
      ScopeVariant(.project, "/folders/{scopeId}/webhooks"),
      ScopeVariant(.space, "/spaces/{scopeId}/webhooks")
    ],
    arguments: [
      ArgumentDefinition("scope", .scope, .scope),
      ArgumentDefinition(
        "input",
        .inputObject(InputObjectShape(
          typeName: "CreateWebhookInput",
          fields: [
            ArgumentDefinition("hookUrl", .string, .bodyForm("hookUrl"), required: true),
            ArgumentDefinition("events", .stringList, .bodyForm("events")),
            ArgumentDefinition("recursive", .boolean, .bodyForm("recursive")),
            ArgumentDefinition("secret", .string, .bodyForm("secret"))
          ]
        )),
        .container,
        required: true
      )
    ],
    // The webhook signing secret is write-only: it is accepted as an input for
    // secure-webhook registration (pass it via --variables-file, never inline
    // in a document), it is forwarded only in the upstream request body, and
    // the stable Webhook model has no secret field, so it can never appear in
    // this project's output.
    result: .payload(field: "webhook", WebhookCapabilities.webhook),
    scopes: .workspaceReadWrite,
    summary: "Registers a webhook for the account, a folder, a project, or a space."
  )

  public static let updateWebhookStatus = CapabilityDefinition(
    id: CapabilityID("webhooks.update"),
    field: "updateWebhookStatus",
    tier: .writer,
    operationClass: .update,
    method: .put,
    pathTemplate: "/webhooks/{webhookId}",
    arguments: [
      ArgumentDefinition(
        "input",
        .inputObject(InputObjectShape(
          typeName: "UpdateWebhookStatusInput",
          fields: [
            ArgumentDefinition("webhookId", .identifier, .path("webhookId"), required: true),
            ArgumentDefinition(
              "status",
              .enumeration("WebhookStatus", ["Active", "Suspended"]),
              .bodyForm("status"),
              required: true
            )
          ]
        )),
        .container,
        required: true
      )
    ],
    result: .payload(field: "webhook", WebhookCapabilities.webhook),
    scopes: .workspaceReadWrite,
    summary: "Suspends or reactivates a webhook registration."
  )

  public static let all: [CapabilityDefinition] = [
    createComment,
    updateComment,
    uploadTaskAttachment,
    uploadFolderAttachment,
    updateAttachment,
    createTimelog,
    updateTimelog,
    createCustomField,
    updateCustomField,
    createWorkflow,
    updateWorkflow,
    createWebhook,
    updateWebhookStatus
  ]
}
