import Foundation

/// The constrained GraphQL AST.
///
/// The initial parser scope deliberately excludes fragments, directives,
/// aliases, subscriptions, and introspection. Widening the syntax must never
/// widen capability access, so the AST carries no escape hatch.
public struct GraphQLDocument: Sendable, Equatable {
  public let operation: GraphQLOperation

  public init(operation: GraphQLOperation) {
    self.operation = operation
  }
}

public enum GraphQLOperationType: String, Sendable, Equatable {
  case query
  case mutation

  public var isMutation: Bool { self == .mutation }
}

public struct GraphQLOperation: Sendable, Equatable {
  public let type: GraphQLOperationType
  public let name: String?
  public let variableDefinitions: [GraphQLVariableDefinition]
  public let selections: [GraphQLField]

  public init(
    type: GraphQLOperationType,
    name: String?,
    variableDefinitions: [GraphQLVariableDefinition],
    selections: [GraphQLField]
  ) {
    self.type = type
    self.name = name
    self.variableDefinitions = variableDefinitions
    self.selections = selections
  }
}

public struct GraphQLVariableDefinition: Sendable, Equatable {
  public let name: String
  public let typeName: String
  public let isRequired: Bool

  public init(name: String, typeName: String, isRequired: Bool) {
    self.name = name
    self.typeName = typeName
    self.isRequired = isRequired
  }
}

public struct GraphQLField: Sendable, Equatable {
  public let name: String
  public let arguments: [String: GraphQLInputValue]
  public let selections: [GraphQLField]

  public init(name: String, arguments: [String: GraphQLInputValue], selections: [GraphQLField]) {
    self.name = name
    self.arguments = arguments
    self.selections = selections
  }
}

/// A literal or variable reference in an argument position.
public indirect enum GraphQLInputValue: Sendable, Equatable {
  case null
  case bool(Bool)
  case int(Int)
  case double(Double)
  case string(String)
  /// GraphQL enum values are unquoted names; they stay distinct from strings
  /// until coercion so an enum argument cannot be satisfied by a quoted string.
  case enumeration(String)
  case list([GraphQLInputValue])
  case object([String: GraphQLInputValue])
  case variable(String)

  /// Resolves variable references against the supplied variable values.
  public func resolved(variables: [String: WrikeValue], path: String) throws -> WrikeValue {
    switch self {
    case .null:
      return .null
    case .bool(let flag):
      return .bool(flag)
    case .int(let number):
      return .int(number)
    case .double(let number):
      return .double(number)
    case .string(let text), .enumeration(let text):
      return .string(text)
    case .list(let items):
      return .array(try items.enumerated().map {
        try $0.element.resolved(variables: variables, path: "\(path)[\($0.offset)]")
      })
    case .object(let fields):
      var resolved: [String: WrikeValue] = [:]
      for (key, value) in fields {
        resolved[key] = try value.resolved(variables: variables, path: "\(path).\(key)")
      }
      return .object(resolved)
    case .variable(let name):
      guard let value = variables[name] else {
        throw GatewayError.validation("Variable $\(name) used at \(path) was not provided.")
      }
      return value
    }
  }

  /// Variable names referenced anywhere in this value.
  public var referencedVariables: Set<String> {
    switch self {
    case .variable(let name):
      return [name]
    case .list(let items):
      return items.reduce(into: Set<String>()) { $0.formUnion($1.referencedVariables) }
    case .object(let fields):
      return fields.values.reduce(into: Set<String>()) { $0.formUnion($1.referencedVariables) }
    default:
      return []
    }
  }
}
