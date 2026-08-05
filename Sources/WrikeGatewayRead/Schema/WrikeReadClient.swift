import Foundation
import WrikeGatewayCore

/// The typed reader SDK.
///
/// Each method builds a `CapabilityInvocation` and hands it to the shared
/// `CapabilityExecutor`. It performs no path construction, no argument
/// validation, and no error mapping of its own, which is what makes the typed
/// SDK and the GraphQL runtime provably equivalent for the same operation.
public struct WrikeReadClient: Sendable {
  public let executor: CapabilityExecutor

  public init(executor: CapabilityExecutor) {
    self.executor = executor
  }

  public init(
    transport: any WrikeTransport,
    credentials: any CredentialProvider,
    clock: any GatewayClock = SystemClock(),
    retryPolicy: RetryPolicy = RetryPolicy()
  ) throws {
    self.executor = CapabilityExecutor(
      planner: CapabilityPlanner(registry: try ReadCapabilities.registry()),
      transport: transport,
      credentials: credentials,
      clock: clock,
      retryPolicy: retryPolicy
    )
  }

  // MARK: - Work hierarchy

  public func contacts(me: Bool? = nil, deleted: Bool? = nil, types: [String]? = nil) async throws -> WrikeValue {
    try await execute(ContactCapabilities.list, [
      "me": me.map(WrikeValue.bool),
      "deleted": deleted.map(WrikeValue.bool),
      "types": types.map { .array($0.map(WrikeValue.string)) }
    ])
  }

  public func contact(id: String) async throws -> WrikeValue {
    try await execute(ContactCapabilities.get, ["id": .string(id)])
  }

  public func user(id: String) async throws -> WrikeValue {
    try await execute(UserCapabilities.get, ["id": .string(id)])
  }

  public func userTypes() async throws -> WrikeValue {
    try await execute(UserCapabilities.types, [:])
  }

  public func groups(metadata: String? = nil) async throws -> WrikeValue {
    try await execute(GroupCapabilities.list, ["metadata": metadata.map(WrikeValue.string)])
  }

  public func group(id: String) async throws -> WrikeValue {
    try await execute(GroupCapabilities.get, ["id": .string(id)])
  }

  public func account() async throws -> WrikeValue {
    try await execute(AccountCapabilities.get, [:])
  }

  public func accessRoles() async throws -> WrikeValue {
    try await execute(AccountCapabilities.accessRoles, [:])
  }

  public func spaces(withArchived: Bool? = nil, title: String? = nil) async throws -> WrikeValue {
    try await execute(SpaceCapabilities.list, [
      "withArchived": withArchived.map(WrikeValue.bool),
      "title": title.map(WrikeValue.string)
    ])
  }

  public func space(id: String) async throws -> WrikeValue {
    try await execute(SpaceCapabilities.get, ["id": .string(id)])
  }

  public func folders(scope: WrikeScope? = nil, descendants: Bool? = nil) async throws -> WrikeValue {
    try await execute(FolderCapabilities.list, [
      "scope": scope?.value,
      "descendants": descendants.map(WrikeValue.bool)
    ])
  }

  public func folder(id: String) async throws -> WrikeValue {
    try await execute(FolderCapabilities.get, ["id": .string(id)])
  }

  public func projects(scope: WrikeScope? = nil) async throws -> WrikeValue {
    try await execute(ProjectCapabilities.list, ["scope": scope?.value, "project": .bool(true)])
  }

  public func project(id: String) async throws -> WrikeValue {
    try await execute(ProjectCapabilities.get, ["id": .string(id)])
  }

  public func tasks(
    scope: WrikeScope? = nil,
    page: PageInput? = nil,
    status: String? = nil
  ) async throws -> WrikeValue {
    try await execute(TaskCapabilities.list, [
      "scope": scope?.value,
      "page": page.map(Self.pageValue),
      "status": status.map(WrikeValue.string)
    ])
  }

  public func task(id: String) async throws -> WrikeValue {
    try await execute(TaskCapabilities.get, ["id": .string(id)])
  }

  // MARK: - Collaboration and administration views

  public func comments(scope: WrikeScope? = nil, plainText: Bool? = nil) async throws -> WrikeValue {
    try await execute(CommentCapabilities.list, [
      "scope": scope?.value,
      "plainText": plainText.map(WrikeValue.bool)
    ])
  }

  public func comment(id: String) async throws -> WrikeValue {
    try await execute(CommentCapabilities.get, ["id": .string(id)])
  }

  public func attachments(scope: WrikeScope? = nil, withUrls: Bool? = nil) async throws -> WrikeValue {
    try await execute(AttachmentCapabilities.list, [
      "scope": scope?.value,
      "withUrls": withUrls.map(WrikeValue.bool)
    ])
  }

  public func attachment(id: String) async throws -> WrikeValue {
    try await execute(AttachmentCapabilities.get, ["id": .string(id)])
  }

  public func attachmentDownloadURL(id: String) async throws -> WrikeValue {
    try await execute(AttachmentCapabilities.url, ["id": .string(id)])
  }

  public func timelogs(scope: WrikeScope? = nil, page: PageInput? = nil) async throws -> WrikeValue {
    try await execute(TimelogCapabilities.list, [
      "scope": scope?.value,
      "page": page.map(Self.pageValue)
    ])
  }

  public func timelog(id: String) async throws -> WrikeValue {
    try await execute(TimelogCapabilities.get, ["id": .string(id)])
  }

  public func customFields(scope: WrikeScope? = nil) async throws -> WrikeValue {
    try await execute(CustomFieldCapabilities.list, ["scope": scope?.value])
  }

  public func customField(id: String) async throws -> WrikeValue {
    try await execute(CustomFieldCapabilities.get, ["id": .string(id)])
  }

  public func workflows() async throws -> WrikeValue {
    try await execute(WorkflowCapabilities.list, [:])
  }

  public func webhooks() async throws -> WrikeValue {
    try await execute(WebhookCapabilities.list, [:])
  }

  public func webhook(id: String) async throws -> WrikeValue {
    try await execute(WebhookCapabilities.get, ["id": .string(id)])
  }

  // MARK: - Shared dispatch

  func execute(
    _ definition: CapabilityDefinition,
    _ arguments: [String: WrikeValue?]
  ) async throws -> WrikeValue {
    try await executor.execute(Self.invocation(definition, arguments))
  }

  /// Builds the invocation without executing it. Parity tests use this to
  /// compare the SDK's plan against the GraphQL runtime's plan.
  public static func invocation(
    _ definition: CapabilityDefinition,
    _ arguments: [String: WrikeValue?]
  ) -> CapabilityInvocation {
    CapabilityInvocation(
      capabilityID: definition.id,
      arguments: arguments.compactMapValues { $0 }
    )
  }

  static func pageValue(_ page: PageInput) -> WrikeValue {
    var fields: [String: WrikeValue] = [:]
    if let size = page.pageSize { fields["pageSize"] = .int(size) }
    if let token = page.nextPageToken { fields["nextPageToken"] = .string(token) }
    return .object(fields)
  }
}

/// A typed scope selector for the SDK, mirroring the GraphQL `ScopeInput`.
public struct WrikeScope: Sendable, Equatable {
  public let relation: ScopeInput.Relation
  public let identifier: String

  public init(relation: ScopeInput.Relation, identifier: String) {
    self.relation = relation
    self.identifier = identifier
  }

  public static func account(_ id: String) -> WrikeScope { .init(relation: .account, identifier: id) }
  public static func space(_ id: String) -> WrikeScope { .init(relation: .space, identifier: id) }
  public static func folder(_ id: String) -> WrikeScope { .init(relation: .folder, identifier: id) }
  public static func project(_ id: String) -> WrikeScope { .init(relation: .project, identifier: id) }
  public static func task(_ id: String) -> WrikeScope { .init(relation: .task, identifier: id) }
  public static func user(_ id: String) -> WrikeScope { .init(relation: .user, identifier: id) }
  public static func category(_ id: String) -> WrikeScope { .init(relation: .category, identifier: id) }

  public var value: WrikeValue {
    .object([relation.rawValue: .string(identifier)])
  }
}
