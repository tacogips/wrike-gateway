import Foundation

/// A stable capability identifier such as `tasks.get`.
///
/// The same value registers a GraphQL field, authorizes a tier, selects an SDK
/// adapter, and anchors test assertions. It never changes once published.
public struct CapabilityID: Sendable, Hashable, RawRepresentable, CustomStringConvertible, Comparable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }

  public var description: String { rawValue }

  /// The plural resource namespace, for example `tasks` in `tasks.get`.
  public var namespace: String {
    String(rawValue.prefix(while: { $0 != "." }))
  }

  public static func < (lhs: CapabilityID, rhs: CapabilityID) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

public enum CapabilityTier: String, Sendable, CaseIterable, Comparable, Codable {
  case reader
  case writer
  case admin

  private var rank: Int {
    switch self {
    case .reader: return 0
    case .writer: return 1
    case .admin: return 2
    }
  }

  /// Tiers are cumulative: an admin binary may execute reader capabilities.
  public func includes(_ other: CapabilityTier) -> Bool { rank >= other.rank }

  public static func < (lhs: CapabilityTier, rhs: CapabilityTier) -> Bool {
    lhs.rank < rhs.rank
  }
}

public enum OperationClass: String, Sendable, CaseIterable {
  case read
  case create
  case update
  case delete

  public var isMutation: Bool { self != .read }
}

/// Implementation state tracked per capability, mirroring the coverage states
/// in `design-docs/specs/design-capability-matrix.md#coverage-state`.
public enum CapabilityStatus: String, Sendable, CaseIterable {
  case planned
  case implemented
  case blockedByScope
  case blockedByPlan
  case unsupported

  public var isExecutable: Bool { self == .implemented }
}

/// Wrike OAuth scope metadata for a capability.
public struct ScopeRequirement: Sendable, Equatable {
  /// Every upstream scope Wrike documents as sufficient for the operation.
  public let accepted: [String]
  /// The least-privilege scope recommended when requesting authorization.
  public let recommended: String

  public init(accepted: [String], recommended: String) {
    self.accepted = accepted
    self.recommended = recommended
  }

  /// Read operations accept Wrike's default and workspace read scopes.
  public static let workspaceRead = ScopeRequirement(
    accepted: ["Default", "wsReadOnly", "wsReadWrite"],
    recommended: "wsReadOnly"
  )

  /// Mutating workspace operations require the read-write workspace scope.
  public static let workspaceReadWrite = ScopeRequirement(
    accepted: ["Default", "wsReadWrite"],
    recommended: "wsReadWrite"
  )

  /// Group administration uses Wrike's account-management group scope.
  public static let accountGroupReadWrite = ScopeRequirement(
    accepted: ["amReadWriteGroup"],
    recommended: "amReadWriteGroup"
  )

  /// Returns true when at least one accepted scope was granted.
  public func isSatisfied(byGranted granted: [String]) -> Bool {
    guard !granted.isEmpty else { return true }
    let grantedSet = Set(granted)
    return accepted.contains { grantedSet.contains($0) }
  }
}
