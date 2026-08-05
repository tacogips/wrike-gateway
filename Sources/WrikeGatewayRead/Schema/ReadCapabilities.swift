import WrikeGatewayCore

/// Merges the resource-local reader fragments into the reader schema.
///
/// Every fragment is contributed by exactly one resource directory. The
/// registry rejects a duplicate capability id or field name at construction, so
/// a merge conflict is a build-time-visible failure rather than a silent
/// override.
public enum ReadCapabilities {
  public static let all: [CapabilityDefinition] =
    ContactCapabilities.all
    + UserCapabilities.all
    + GroupCapabilities.all
    + AccountCapabilities.all
    + SpaceCapabilities.all
    + FolderCapabilities.all
    + ProjectCapabilities.all
    + TaskCapabilities.all
    + CommentCapabilities.all
    + AttachmentCapabilities.all
    + TimelogCapabilities.all
    + CustomFieldCapabilities.all
    + WorkflowCapabilities.all
    + WebhookCapabilities.all

  /// The twelve reviewed resource areas, plus the account-level access-role
  /// view that the accounts/spaces area contributes.
  public static let resourceNamespaces: Set<String> = [
    "contacts",
    "users",
    "groups",
    "account",
    "accessRoles",
    "spaces",
    "folders",
    "projects",
    "tasks",
    "comments",
    "attachments",
    "timelogs",
    "customFields",
    "workflows",
    "webhooks"
  ]

  public static func registry() throws -> CapabilityRegistry {
    try CapabilityRegistry(tier: .reader, definitions: all)
  }
}
