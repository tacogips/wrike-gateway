import Foundation

/// How a validated argument value reaches the upstream request.
public enum ArgumentBinding: Sendable, Equatable {
  /// Substituted into a `{name}` placeholder in the path template. An
  /// identifier list renders as one comma-separated segment, which is how
  /// Wrike's multi-entity routes address several entities at once.
  case path(String)
  /// Sent as a single query parameter with the given upstream name.
  case query(String)
  /// Sent as a comma-separated query parameter, matching Wrike's list encoding.
  case queryList(String)
  /// Sent as a JSON document in a single query parameter. Wrike uses this
  /// encoding for object-valued filters such as an instant range.
  case queryJSON(String)
  /// Sent as a JSON body field.
  case bodyJSON(String)
  /// Sent as a form field.
  case bodyForm(String)
  /// Selects the upstream path variant and any scope path placeholder.
  case scope
  /// Expands to `pageSize` and `nextPageToken` query parameters.
  case page
  /// A validated local file path used for a streamed upload.
  case filePath
  /// A validated local destination path. It selects the request's file response
  /// sink and contributes nothing to the upstream URL, query, or body.
  case destinationPath
  /// Carries no binding of its own; only its nested input-object fields bind.
  /// Mutations use this for their single `input` argument.
  case container
}

public enum ArgumentValueType: Sendable, Equatable {
  case identifier
  case identifierList
  case string
  case stringList
  case integer
  case number
  case boolean
  case scope
  case page
  case enumeration(String, [String])
  /// A list restricted to a curated set of values, such as the field selection
  /// accepted by Wrike's field-history routes. Validating locally means an
  /// unaccepted value is a named validation error rather than an upstream 400.
  case enumerationList(String, [String])
  case inputObject(InputObjectShape)

  public var graphQLTypeName: String {
    switch self {
    case .identifier: return "ID"
    case .identifierList: return "[ID!]"
    case .string: return "String"
    case .stringList: return "[String!]"
    case .integer: return "Int"
    case .number: return "Float"
    case .boolean: return "Boolean"
    case .scope: return ScopeInput.typeName
    case .page: return "PageInput"
    case .enumeration(let name, _): return name
    case .enumerationList(let name, _): return "[\(name)!]"
    case .inputObject(let shape): return shape.typeName
    }
  }
}

public struct ArgumentDefinition: Sendable, Equatable {
  public let name: String
  public let type: ArgumentValueType
  public let binding: ArgumentBinding
  public let isRequired: Bool
  /// Upstream limit on a list argument's length, when the reference documents
  /// one. Enforcing it locally keeps an over-long request from being assembled
  /// at all, rather than sending a URL Wrike will refuse.
  public let maximumCount: Int?

  public init(
    _ name: String,
    _ type: ArgumentValueType,
    _ binding: ArgumentBinding,
    required: Bool = false,
    maximumCount: Int? = nil
  ) {
    self.name = name
    self.type = type
    self.binding = binding
    self.isRequired = required
    self.maximumCount = maximumCount
  }
}

/// A named GraphQL input object. Mutations accept exactly one `input` argument
/// whose fields carry their own bindings.
public struct InputObjectShape: Sendable, Equatable {
  public let typeName: String
  public let fields: [ArgumentDefinition]

  public init(typeName: String, fields: [ArgumentDefinition]) {
    self.typeName = typeName
    self.fields = fields
  }

  public func field(named name: String) -> ArgumentDefinition? {
    fields.first { $0.name == name }
  }
}

/// A typed scope selector. It names a reviewed relation rather than accepting a
/// path string, so no caller can reach an unregistered endpoint.
public struct ScopeInput: Sendable, Equatable {
  public static let typeName = "ScopeInput"

  /// The reviewed relations a capability may scope by.
  public enum Relation: String, Sendable, CaseIterable {
    case account = "accountId"
    case space = "spaceId"
    case folder = "folderId"
    case project = "projectId"
    case task = "taskId"
    case user = "userId"
    case category = "categoryId"
  }

  public let relation: Relation
  public let identifier: WrikeIdentifier

  public init(relation: Relation, identifier: WrikeIdentifier) {
    self.relation = relation
    self.identifier = identifier
  }
}

/// Maps one scope relation to an upstream path template.
public struct ScopeVariant: Sendable, Equatable {
  public let relation: ScopeInput.Relation
  /// Uses `{scopeId}` for the scope identifier.
  public let pathTemplate: String

  public init(_ relation: ScopeInput.Relation, _ pathTemplate: String) {
    self.relation = relation
    self.pathTemplate = pathTemplate
  }
}

/// The complete, declarative description of one capability.
///
/// Registration is a single value so the GraphQL field, the tier check, the
/// upstream route, the scope metadata, the result projection, and the
/// implementation status cannot drift apart.
public struct CapabilityDefinition: Sendable, Equatable {
  public let id: CapabilityID
  /// Public GraphQL field name.
  public let field: String
  public let tier: CapabilityTier
  public let operationClass: OperationClass
  public let method: HTTPMethod
  /// Upstream path used when no scope argument is supplied. Placeholders are
  /// `{name}` tokens bound from `.path` arguments.
  public let pathTemplate: String
  /// Alternative templates selected by a scope relation.
  public let scopeVariants: [ScopeVariant]
  public let arguments: [ArgumentDefinition]
  public let result: ResultShape
  public let scopes: ScopeRequirement
  public let maximumPageSize: Int?
  public let status: CapabilityStatus
  /// Documentation string printed in the role schema.
  public let summary: String

  public init(
    id: CapabilityID,
    field: String,
    tier: CapabilityTier,
    operationClass: OperationClass,
    method: HTTPMethod,
    pathTemplate: String,
    scopeVariants: [ScopeVariant] = [],
    arguments: [ArgumentDefinition] = [],
    result: ResultShape,
    scopes: ScopeRequirement,
    maximumPageSize: Int? = nil,
    status: CapabilityStatus = .implemented,
    summary: String
  ) {
    self.id = id
    self.field = field
    self.tier = tier
    self.operationClass = operationClass
    self.method = method
    self.pathTemplate = pathTemplate
    self.scopeVariants = scopeVariants
    self.arguments = arguments
    self.result = result
    self.scopes = scopes
    self.maximumPageSize = maximumPageSize
    self.status = status
    self.summary = summary
  }

  public var isDestructive: Bool { operationClass == .delete }

  public func argument(named name: String) -> ArgumentDefinition? {
    arguments.first { $0.name == name }
  }

  /// Structural invariants that every registration must satisfy. Violations are
  /// internal errors surfaced by the registry's coherence test.
  public func coherenceProblems() -> [String] {
    var problems: [String] = []
    if operationClass == .delete && tier != .admin {
      problems.append("\(id) is a delete operation outside the admin tier.")
    }
    if method == .delete && tier != .admin {
      problems.append("\(id) uses HTTP DELETE outside the admin tier.")
    }
    if operationClass == .read && method != .get {
      problems.append("\(id) is a read operation but does not use HTTP GET.")
    }
    if operationClass == .read && tier != .reader {
      problems.append("\(id) is a read operation outside the reader tier.")
    }
    if operationClass.isMutation && method == .get {
      problems.append("\(id) is a mutation bound to HTTP GET.")
    }
    if case .deletion = result, operationClass != .delete {
      problems.append("\(id) returns a deletion payload without being a delete operation.")
    }
    if operationClass == .delete, case .deletion = result {} else if operationClass == .delete {
      problems.append("\(id) is a delete operation that does not return a deletion payload.")
    }
    if case .connection = result, maximumPageSize == nil {
      problems.append("\(id) returns a connection without a documented maximum page size.")
    }
    problems.append(contentsOf: fileOutputProblems())
    if maximumPageSize != nil, !arguments.contains(where: { $0.binding == .page }) {
      problems.append("\(id) declares a maximum page size without a page argument.")
    }
    problems.append(contentsOf: pathPlaceholderProblems())
    if !scopes.accepted.contains(scopes.recommended) {
      problems.append("\(id) recommends a scope that is not in its accepted list.")
    }
    if field.isEmpty || summary.isEmpty {
      problems.append("\(id) is missing a field name or summary.")
    }
    return problems
  }

  /// A destination path and a file result are two halves of the same contract.
  /// Either alone would be a silent hazard: a sink with no file result would
  /// write bytes the caller never asked to receive, and a file result with no
  /// sink would leave the projection with nothing to describe. Only reads may
  /// write a destination, so no mutation can be made to produce a local file as
  /// a side effect.
  private func fileOutputProblems() -> [String] {
    var problems: [String] = []
    let destinations = arguments.filter { $0.binding == .destinationPath }
    if result.isFileOutput {
      if destinations.count != 1 {
        problems.append("\(id) returns a file output without exactly one destination argument.")
      }
      if !destinations.allSatisfy(\.isRequired) {
        problems.append("\(id) has an optional destination argument for a file output.")
      }
      if operationClass != .read {
        problems.append("\(id) writes a local file but is not a read operation.")
      }
    } else if !destinations.isEmpty {
      problems.append("\(id) accepts a destination argument without returning a file output.")
    }
    return problems
  }

  /// Placeholder names bound by an argument or by any nested input-object
  /// field. Nested fields must be included or a mutation that binds its ids
  /// inside `input` would look unbound.
  private static func boundPathNames(in arguments: [ArgumentDefinition]) -> Set<String> {
    var names: Set<String> = []
    for argument in arguments {
      if case .path(let name) = argument.binding {
        names.insert(name)
      }
      if case .inputObject(let shape) = argument.type {
        names.formUnion(boundPathNames(in: shape.fields))
      }
    }
    return names
  }

  private func pathPlaceholderProblems() -> [String] {
    var problems: [String] = []
    let boundNames = Self.boundPathNames(in: arguments)
    for template in [pathTemplate] + scopeVariants.map(\.pathTemplate) {
      for placeholder in Self.placeholders(in: template) where placeholder != "scopeId" {
        if !boundNames.contains(placeholder) {
          problems.append("\(id) path template references unbound placeholder {\(placeholder)}.")
        }
      }
    }
    for name in boundNames where !pathTemplate.contains("{\(name)}") {
      let inVariant = scopeVariants.contains { $0.pathTemplate.contains("{\(name)}") }
      if !inVariant {
        problems.append("\(id) binds argument to path placeholder {\(name)} that no template uses.")
      }
    }
    if operationClass.isMutation {
      let containers = arguments.filter { $0.binding == .container }
      if containers.count != 1 || containers.first?.name != "input" {
        problems.append("\(id) must accept exactly one input container argument named input.")
      }
    }
    return problems
  }

  static func placeholders(in template: String) -> [String] {
    var names: [String] = []
    var current: String?
    for character in template {
      if character == "{" {
        current = ""
      } else if character == "}" {
        if let name = current { names.append(name) }
        current = nil
      } else if current != nil {
        current?.append(character)
      }
    }
    return names
  }
}
