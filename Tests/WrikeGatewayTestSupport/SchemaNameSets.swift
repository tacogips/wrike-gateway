import Foundation

/// Extracts the named schema definitions and root fields needed for SDL parity tests.
public enum SchemaNameSets {
  public struct Value: Equatable, Sendable {
    public let queryFields: Set<String>
    public let mutationFields: Set<String>
    public let typeNames: Set<String>
  }

  public static func parse(_ sdl: String) -> Value {
    var queryFields: Set<String> = []
    var mutationFields: Set<String> = []
    var typeNames: Set<String> = []
    var root: Root?

    for line in sdl.split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("type Query {") {
        root = .query
        continue
      }
      if trimmed.hasPrefix("type Mutation {") {
        root = .mutation
        continue
      }
      if trimmed == "}" {
        root = nil
        continue
      }
      if root == nil, let name = definitionName(in: trimmed) {
        typeNames.insert(name)
        continue
      }
      guard let root, !trimmed.hasPrefix("\"\"\""),
            let colon = trimmed.firstIndex(of: ":")
      else { continue }
      let fieldPrefix = trimmed[..<colon].split(separator: "(").first ?? ""
      let name = String(fieldPrefix).trimmingCharacters(in: .whitespaces)
      guard name.first?.isLetter == true || name.first == "_" else { continue }
      switch root {
      case .query: queryFields.insert(name)
      case .mutation: mutationFields.insert(name)
      }
    }
    return Value(queryFields: queryFields, mutationFields: mutationFields, typeNames: typeNames)
  }

  private enum Root { case query, mutation }

  private static func definitionName(in line: String) -> String? {
    let parts = line.split(separator: " ")
    guard parts.count >= 2, ["type", "input", "enum"].contains(String(parts[0])) else { return nil }
    return String(parts[1].prefix { $0 != "{" })
  }
}
