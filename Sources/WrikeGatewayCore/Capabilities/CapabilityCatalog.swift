import Foundation

/// The tier that owns each published GraphQL field name.
///
/// This is a name-only table. It links no write or admin code, so a reader
/// binary can still answer "that mutation requires the admin tier" with
/// `CAPABILITY_DENIED` instead of "unknown field", exactly as
/// `design-docs/specs/command.md#output-and-exit-codes` requires.
///
/// Every entry must match a real registration in its owning module;
/// `WrikeGatewayCLITests` asserts the two agree in both directions.
public enum CapabilityCatalog {
  public static let writerMutationFields: [String] = [
    "copyFolder",
    "createComment",
    "createCustomField",
    "createFolder",
    "createGroup",
    "createProject",
    "createSpace",
    "createTask",
    "createTimelog",
    "createWebhook",
    "createWorkflow",
    "updateAccount",
    "updateAttachment",
    "updateComment",
    "updateContact",
    "updateCustomField",
    "updateFolder",
    "updateGroup",
    "updateProject",
    "updateSpace",
    "updateTask",
    "updateTimelog",
    "updateUser",
    "updateWebhookStatus",
    "updateWorkflow",
    "uploadFolderAttachment",
    "uploadTaskAttachment"
  ]

  public static let adminMutationFields: [String] = [
    "deleteAttachment",
    "deleteComment",
    "deleteFolder",
    "deleteGroup",
    "deleteProject",
    "deleteSpace",
    "deleteTask",
    "deleteTimelog",
    "deleteWebhook"
  ]

  /// Returns the tier that owns a field name, or `nil` when the name is not
  /// part of the published contract at all.
  public static func knownTier(field: String, isMutation: Bool) -> CapabilityTier? {
    guard isMutation else { return nil }
    if adminMutationFields.contains(field) { return .admin }
    if writerMutationFields.contains(field) { return .writer }
    return nil
  }
}
