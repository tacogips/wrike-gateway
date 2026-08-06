import Foundation
import WrikeGatewayCore

/// Selects one element out of an array while resolving a capture path: the
/// first whose `field` equals `equals`.
///
/// The live folders list taught the need for this: its first element is the
/// account's Root pseudo-folder, whose id the by-id endpoint refuses with HTTP
/// 400, so a capture that blindly takes index zero hands later scenarios an id
/// that can never succeed. Selection is by a semantic field the schema exposes
/// (for folders, `scope == "WsFolder"`), never by decoding the shape of an id,
/// which the design forbids.
public struct E2ECaptureSelector: Sendable {
  public let field: String
  public let equals: String

  public init(field: String, equals: String) {
    self.field = field
    self.equals = equals
  }
}

/// A value captured from a successful scenario for later live variables.
///
/// A path component of `"*"` selects an array element through
/// `selectFirstWhere`; a numeric component indexes the array directly.
public struct E2ECapture: Sendable {
  public let key: String
  public let path: [String]
  public let selectFirstWhere: E2ECaptureSelector?

  public init(key: String, path: [String], selectFirstWhere: E2ECaptureSelector? = nil) {
    self.key = key
    self.path = path
    self.selectFirstWhere = selectFirstWhere
  }
}

/// One end-to-end verification case, expressed as data.
///
/// A scenario is written once and executed by two runners: the replay runner,
/// which serves recorded Wrike responses from the loopback server and runs in
/// the normal test suite with no credentials, and the live runner, which sends
/// the same document to a real Wrike account and is opt-in. Keeping the case
/// declarative is what makes the pair possible; a scenario that only existed as
/// hand-written test code could not be replayed.
public struct E2EScenario: Sendable {
  /// What the runner must observe for the scenario to pass.
  public enum Expectation: Sendable {
    /// The document succeeds and the named top-level field is present.
    case succeeds(field: String)
    /// The document succeeds and the named field is a collection, whose
    /// `pageInfo` must be present. Used for the pagination cases.
    case succeedsWithPageInfo(field: String)
    /// The document fails before or during execution with this stable code.
    case fails(GatewayErrorCode)
  }

  public let name: String
  /// The lowest tier whose schema contains the field under test. The replay
  /// runner builds a runtime at exactly this tier; the live runner uses the
  /// matching executable.
  public let tier: CapabilityTier
  /// The Wrike resource area this scenario covers, used to report coverage.
  public let area: String
  public let document: String
  public let variables: [String: String]
  /// Maps a GraphQL variable name to a key captured by an earlier live
  /// scenario. Replay uses the structurally realistic `variables` fixture;
  /// live execution substitutes account-owned identifiers at runtime.
  public let liveVariableKeys: [String: String]
  public let captures: [E2ECapture]
  public let expectation: Expectation
  /// The canned responses the replay runner serves, in order. A scenario that
  /// fails before any transport call declares none.
  public let replayResponses: [String]
  /// Set when the case cannot be replayed offline and is meaningful only
  /// against a real account, with the reason recorded here.
  public let liveOnlyReason: String?

  public init(
    name: String,
    tier: CapabilityTier,
    area: String,
    document: String,
    variables: [String: String] = [:],
    liveVariableKeys: [String: String] = [:],
    captures: [E2ECapture] = [],
    expectation: Expectation,
    replayResponses: [String] = [],
    liveOnlyReason: String? = nil
  ) {
    self.name = name
    self.tier = tier
    self.area = area
    self.document = document
    self.variables = variables
    self.liveVariableKeys = liveVariableKeys
    self.captures = captures
    self.expectation = expectation
    self.replayResponses = replayResponses
    self.liveOnlyReason = liveOnlyReason
  }

  /// True when the replay runner can execute this scenario offline.
  public var isReplayable: Bool { liveOnlyReason == nil }
}

/// An ordered mutation sequence that creates a container, works inside it, and
/// removes everything it created.
///
/// The live runner must never leave an object behind and must never touch
/// anything it did not create, so the lifecycle is expressed as a single
/// ordered unit rather than as independent scenarios. Each step may capture the
/// id it produced under a key that later steps interpolate as `{{key}}`.
public struct E2ELifecycle: Sendable {
  public struct Step: Sendable {
    public let name: String
    public let tier: CapabilityTier
    public let document: String
    /// The top-level field whose result the step asserts.
    public let field: String
    /// The path within the field's result whose value is captured, and the key
    /// it is captured under. Later steps interpolate `{{key}}`.
    public let captures: (key: String, path: [String])?
    /// The canned response the replay runner serves for this step.
    public let replayResponse: String
    /// True when the step deletes something the sequence created. The live
    /// runner requires every created id to be covered by a cleanup step.
    public let isCleanup: Bool

    public init(
      name: String,
      tier: CapabilityTier,
      document: String,
      field: String,
      captures: (key: String, path: [String])? = nil,
      replayResponse: String,
      isCleanup: Bool = false
    ) {
      self.name = name
      self.tier = tier
      self.document = document
      self.field = field
      self.captures = captures
      self.replayResponse = replayResponse
      self.isCleanup = isCleanup
    }
  }

  public let name: String
  public let steps: [Step]

  public init(name: String, steps: [Step]) {
    self.name = name
    self.steps = steps
  }

  /// Substitutes `{{key}}` placeholders from ids captured earlier in the run.
  public static func interpolate(_ document: String, with captured: [String: String]) -> String {
    captured.reduce(document) { partial, entry in
      partial.replacingOccurrences(of: "{{\(entry.key)}}", with: entry.value)
    }
  }

  /// The placeholder keys a document still expects, used to fail loudly rather
  /// than sending `{{containerId}}` to Wrike as a literal identifier.
  public static func unresolvedPlaceholders(in document: String) -> [String] {
    var found: [String] = []
    var remainder = Substring(document)
    while let open = remainder.range(of: "{{"), let close = remainder.range(of: "}}") {
      guard open.upperBound <= close.lowerBound else { break }
      found.append(String(remainder[open.upperBound..<close.lowerBound]))
      remainder = remainder[close.upperBound...]
    }
    return found
  }
}
