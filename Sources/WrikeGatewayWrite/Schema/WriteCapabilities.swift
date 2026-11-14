import Foundation
import WrikeGatewayCore
import WrikeGatewayRead

/// The writer schema: every reader capability plus reviewed create and update
/// mutations.
///
/// `assertNoDestructiveCapability()` is called by the writer composition root
/// and by `WrikeGatewayWriteTests`, so a DELETE-backed registration cannot
/// reach a writer binary even if one were added to this module by mistake.
public enum WriteCapabilities {
  public static let mutations: [CapabilityDefinition] =
    PeopleMutations.all + WorkHierarchyMutations.all + CollaborationMutations.all

  public static let all: [CapabilityDefinition] = ReadCapabilities.all + mutations

  public static func registry() throws -> CapabilityRegistry {
    try assertNoDestructiveCapability()
    return try CapabilityRegistry(tier: .writer, definitions: all)
  }

  /// Writer has no DELETE-backed operation at all.
  public static func assertNoDestructiveCapability() throws {
    let offending = mutations.filter { $0.method == .delete || $0.operationClass == .delete }
    guard offending.isEmpty else {
      throw GatewayError.internalFailure(
        "Writer registered destructive capabilities: \(offending.map(\.id.rawValue).sorted().joined(separator: ", "))."
      )
    }
    let deleteFields = mutations.filter { $0.field.hasPrefix("delete") }
    guard deleteFields.isEmpty else {
      throw GatewayError.internalFailure(
        "Writer registered delete-shaped fields: \(deleteFields.map(\.field).sorted().joined(separator: ", "))."
      )
    }
  }
}

/// The typed writer SDK. It is cumulative: it exposes the reader client plus
/// create and update methods, and no delete method exists on this type.
public struct WrikeWriteClient: Sendable {
  public let executor: CapabilityExecutor
  public let read: WrikeReadClient

  public init(executor: CapabilityExecutor) {
    self.executor = executor
    self.read = WrikeReadClient(executor: executor)
  }

  public init(
    transport: any WrikeTransport,
    credentials: any CredentialProvider,
    clock: any GatewayClock = SystemClock(),
    retryPolicy: RetryPolicy = RetryPolicy()
  ) throws {
    self.init(executor: CapabilityExecutor(
      planner: CapabilityPlanner(registry: try WriteCapabilities.registry()),
      transport: transport,
      credentials: credentials,
      clock: clock,
      // Mutations never retry automatically; the executor enforces this per
      // request method, so the policy passed here only affects reads.
      retryPolicy: retryPolicy
    ))
  }

  public func createTask(folderId: String, title: String, description: String? = nil) async throws -> WrikeValue {
    try await execute(WorkHierarchyMutations.createTask, input: [
      "folderId": .string(folderId),
      "title": .string(title),
      "description": description.map(WrikeValue.string)
    ])
  }

  public func updateTask(taskId: String, title: String? = nil, status: String? = nil) async throws -> WrikeValue {
    try await execute(WorkHierarchyMutations.updateTask, input: [
      "taskId": .string(taskId),
      "title": title.map(WrikeValue.string),
      "status": status.map(WrikeValue.string)
    ])
  }

  public func createFolder(parentFolderId: String, title: String) async throws -> WrikeValue {
    try await execute(WorkHierarchyMutations.createFolder, input: [
      "parentFolderId": .string(parentFolderId),
      "title": .string(title)
    ])
  }

  public func createProject(parentFolderId: String, title: String) async throws -> WrikeValue {
    try await execute(WorkHierarchyMutations.createProject, input: [
      "parentFolderId": .string(parentFolderId),
      "title": .string(title)
    ])
  }

  public func createComment(scope: WrikeScope, text: String) async throws -> WrikeValue {
    try await executor.execute(CapabilityInvocation(
      capabilityID: CollaborationMutations.createComment.id,
      arguments: ["scope": scope.value, "input": .object(["text": .string(text)])]
    ))
  }

  public func uploadTaskAttachment(taskId: String, filePath: String) async throws -> WrikeValue {
    try await execute(CollaborationMutations.uploadTaskAttachment, input: [
      "taskId": .string(taskId),
      "filePath": .string(filePath)
    ])
  }

  public func createTimelog(
    taskId: String,
    hours: Double,
    trackedDate: String,
    comment: String
  ) async throws -> WrikeValue {
    try await execute(CollaborationMutations.createTimelog, input: [
      "taskId": .string(taskId),
      "hours": .double(hours),
      "trackedDate": .string(trackedDate),
      "comment": .string(comment)
    ])
  }

  public func updateWebhookStatus(webhookId: String, status: String) async throws -> WrikeValue {
    try await execute(CollaborationMutations.updateWebhookStatus, input: [
      "webhookId": .string(webhookId),
      "status": .string(status)
    ])
  }

  func execute(
    _ definition: CapabilityDefinition,
    input: [String: WrikeValue?]
  ) async throws -> WrikeValue {
    try await executor.execute(Self.invocation(definition, input: input))
  }

  /// Builds the invocation without executing it, for parity tests.
  public static func invocation(
    _ definition: CapabilityDefinition,
    input: [String: WrikeValue?]
  ) -> CapabilityInvocation {
    CapabilityInvocation(
      capabilityID: definition.id,
      arguments: ["input": .object(input.compactMapValues { $0 })]
    )
  }
}
