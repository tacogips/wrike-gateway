import Foundation

/// The stable output type of a capability.
///
/// A shape is the single source of truth for three derived artifacts: the
/// printed GraphQL type, the validator's field list, and the upstream-to-stable
/// projection. Deriving all three from one declaration is what makes the
/// bidirectional field-to-route coherence check mechanical.
public struct ModelShape: Sendable, Equatable {
  public let typeName: String
  public let fields: [ModelField]

  public init(typeName: String, fields: [ModelField]) {
    self.typeName = typeName
    self.fields = fields
  }

  public func field(named name: String) -> ModelField? {
    fields.first { $0.name == name }
  }

  /// Every object type reachable from this shape, including itself.
  public var reachableShapes: [ModelShape] {
    var collected: [String: ModelShape] = [:]
    collect(into: &collected)
    return collected.values.sorted { $0.typeName < $1.typeName }
  }

  private func collect(into collected: inout [String: ModelShape]) {
    guard collected[typeName] == nil else { return }
    collected[typeName] = self
    for field in fields {
      field.type.nestedShape?.collect(into: &collected)
    }
  }
}

public struct ModelField: Sendable, Equatable {
  /// Project-owned stable field name exposed by GraphQL and the SDK.
  public let name: String
  /// Upstream Wrike field name; an adapter detail that never reaches output.
  public let upstreamName: String
  public let type: ModelFieldType
  /// True when the projection must produce a value for the field.
  public let isRequired: Bool

  public init(_ name: String, upstream: String? = nil, _ type: ModelFieldType, required: Bool = false) {
    self.name = name
    self.upstreamName = upstream ?? name
    self.type = type
    self.isRequired = required
  }
}

public indirect enum ModelFieldType: Sendable, Equatable {
  case identifier
  case string
  case integer
  case number
  case boolean
  /// ISO-8601 instant, preserved verbatim as an opaque timestamp string.
  case dateTime
  /// Calendar date, preserved verbatim.
  case date
  case identifierList
  case stringList
  case object(ModelShape)
  case objectList(ModelShape)

  public var nestedShape: ModelShape? {
    switch self {
    case .object(let shape), .objectList(let shape): return shape
    default: return nil
    }
  }

  /// The printed GraphQL type name for this field.
  public var graphQLTypeName: String {
    switch self {
    case .identifier: return "ID"
    case .string, .dateTime, .date: return "String"
    case .integer: return "Int"
    case .number: return "Float"
    case .boolean: return "Boolean"
    case .identifierList: return "[ID!]"
    case .stringList: return "[String!]"
    case .object(let shape): return shape.typeName
    case .objectList(let shape): return "[\(shape.typeName)!]"
    }
  }

  /// True when the field selects a nested selection set.
  public var isComposite: Bool { nestedShape != nil }
}

/// How a capability's upstream payload becomes a public result.
public enum ResultShape: Sendable, Equatable {
  /// Exactly one entity from the upstream `data` array.
  case single(ModelShape)
  /// A `nodes` plus `pageInfo` connection.
  case connection(ModelShape)
  /// A plain list with no pagination contract, such as user types.
  case list(ModelShape)
  /// A mutation payload wrapping one entity under a named field.
  case payload(field: String, ModelShape)
  /// A destructive result carrying only the confirmed deleted identifier.
  case deletion

  public var elementShape: ModelShape? {
    switch self {
    case .single(let shape), .connection(let shape), .list(let shape):
      return shape
    case .payload(_, let shape):
      return shape
    case .deletion:
      return nil
    }
  }

  /// The GraphQL type name printed for the capability's field.
  public var graphQLTypeName: String {
    switch self {
    case .single(let shape): return shape.typeName
    case .connection(let shape): return "\(shape.typeName)Connection"
    case .list(let shape): return "[\(shape.typeName)!]!"
    case .payload(_, let shape): return "\(shape.typeName)Payload"
    case .deletion: return "DeletionPayload"
    }
  }
}
