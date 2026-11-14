import WrikeGatewayCore
import WrikeGatewayRead
import WrikeGatewayWrite

/// The admin schema: the writer schema plus the reviewed delete mutations.
public enum AdminCapabilities {
  public static let all: [CapabilityDefinition] = WriteCapabilities.all + DeleteCapabilities.all

  public static func registry() throws -> CapabilityRegistry {
    try CapabilityRegistry(tier: .admin, definitions: all)
  }
}

/// The typed admin SDK.
///
/// Every method is destructive, takes exactly one explicit identifier, and
/// returns the confirmed deleted identifier. A transport failure produces an
/// outcome-unknown error rather than an inferred success, and nothing here
/// retries.
public struct WrikeAdminClient: Sendable {
  public let executor: CapabilityExecutor
  public let write: WrikeWriteClient

  public init(executor: CapabilityExecutor) {
    self.executor = executor
    self.write = WrikeWriteClient(executor: executor)
  }

  public init(
    transport: any WrikeTransport,
    credentials: any CredentialProvider,
    clock: any GatewayClock = SystemClock()
  ) throws {
    self.init(executor: CapabilityExecutor(
      planner: CapabilityPlanner(registry: try AdminCapabilities.registry()),
      transport: transport,
      credentials: credentials,
      clock: clock
    ))
  }

  /// DESTRUCTIVE. Deletes one user group.
  public func deleteGroup(groupId: String) async throws -> WrikeValue {
    try await delete(DeleteCapabilities.deleteGroup, "groupId", groupId)
  }

  /// DESTRUCTIVE. Deletes one space.
  public func deleteSpace(spaceId: String) async throws -> WrikeValue {
    try await delete(DeleteCapabilities.deleteSpace, "spaceId", spaceId)
  }

  /// DESTRUCTIVE. Deletes one folder and its descendants.
  public func deleteFolder(folderId: String) async throws -> WrikeValue {
    try await delete(DeleteCapabilities.deleteFolder, "folderId", folderId)
  }

  /// DESTRUCTIVE. Deletes one project and its descendants.
  public func deleteProject(projectId: String) async throws -> WrikeValue {
    try await delete(DeleteCapabilities.deleteProject, "projectId", projectId)
  }

  /// DESTRUCTIVE. Deletes one task.
  public func deleteTask(taskId: String) async throws -> WrikeValue {
    try await delete(DeleteCapabilities.deleteTask, "taskId", taskId)
  }

  /// DESTRUCTIVE. Deletes one comment.
  public func deleteComment(commentId: String) async throws -> WrikeValue {
    try await delete(DeleteCapabilities.deleteComment, "commentId", commentId)
  }

  /// DESTRUCTIVE. Deletes one attachment.
  public func deleteAttachment(attachmentId: String) async throws -> WrikeValue {
    try await delete(DeleteCapabilities.deleteAttachment, "attachmentId", attachmentId)
  }

  /// DESTRUCTIVE. Deletes one timelog entry.
  public func deleteTimelog(timelogId: String) async throws -> WrikeValue {
    try await delete(DeleteCapabilities.deleteTimelog, "timelogId", timelogId)
  }

  /// DESTRUCTIVE. Deletes one webhook registration.
  public func deleteWebhook(webhookId: String) async throws -> WrikeValue {
    try await delete(DeleteCapabilities.deleteWebhook, "webhookId", webhookId)
  }

  func delete(
    _ definition: CapabilityDefinition,
    _ argument: String,
    _ identifier: String
  ) async throws -> WrikeValue {
    try await executor.execute(Self.invocation(definition, argument, identifier))
  }

  /// Builds the invocation without executing it, for parity tests.
  public static func invocation(
    _ definition: CapabilityDefinition,
    _ argument: String,
    _ identifier: String
  ) -> CapabilityInvocation {
    CapabilityInvocation(
      capabilityID: definition.id,
      arguments: ["input": .object([argument: .string(identifier)])]
    )
  }
}
