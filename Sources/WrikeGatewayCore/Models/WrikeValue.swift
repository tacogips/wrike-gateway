import Foundation

/// A closed JSON-shaped value used for stable models, GraphQL inputs, and
/// projected output. Using one value type keeps the typed SDK path and the
/// GraphQL path on identical data without a second serialization contract.
public enum WrikeValue: Sendable, Equatable {
  case null
  case bool(Bool)
  case int(Int)
  case double(Double)
  case string(String)
  case array([WrikeValue])
  case object([String: WrikeValue])
}

extension WrikeValue {
  public var isNull: Bool { self == .null }

  public var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  public var intValue: Int? {
    switch self {
    case .int(let value): return value
    case .double(let value) where value.rounded() == value: return Int(value)
    default: return nil
    }
  }

  public var doubleValue: Double? {
    switch self {
    case .double(let value): return value
    case .int(let value): return Double(value)
    default: return nil
    }
  }

  public var boolValue: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }

  public var arrayValue: [WrikeValue]? {
    if case .array(let value) = self { return value }
    return nil
  }

  public var objectValue: [String: WrikeValue]? {
    if case .object(let value) = self { return value }
    return nil
  }

  public subscript(key: String) -> WrikeValue? {
    guard case .object(let fields) = self else { return nil }
    return fields[key]
  }

  /// Short type name used in validation messages.
  public var typeDescription: String {
    switch self {
    case .null: return "null"
    case .bool: return "Boolean"
    case .int: return "Int"
    case .double: return "Float"
    case .string: return "String"
    case .array: return "list"
    case .object: return "object"
    }
  }
}
