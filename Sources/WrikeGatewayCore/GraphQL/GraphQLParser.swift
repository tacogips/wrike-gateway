import Foundation

/// Parses the constrained GraphQL subset described in
/// `design-docs/specs/design-graphql-contract.md#initial-parser-scope`.
///
/// Every rejection happens here, before credential resolution or any network
/// access. Unsupported syntax is named explicitly so a caller can tell an
/// unsupported feature from a typo.
public struct GraphQLParser: Sendable {
  public static let maximumDocumentLength = 64 * 1024
  public static let maximumTopLevelQueryFields = 10
  public static let maximumSelectionDepth = 8

  public init() {}

  public func parse(_ source: String) throws -> GraphQLDocument {
    guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw GatewayError.validation("The GraphQL document is empty.")
    }
    guard source.count <= Self.maximumDocumentLength else {
      throw GatewayError.validation(
        "The GraphQL document exceeds the \(Self.maximumDocumentLength) character limit."
      )
    }
    var state = ParserState(source: source)
    try state.advance()
    let operation = try state.parseOperation()
    try state.expectEndOfDocument()
    return GraphQLDocument(operation: operation)
  }
}

private struct ParserState {
  private var lexer: GraphQLLexer
  private var token: GraphQLToken = .endOfDocument

  init(source: String) {
    self.lexer = GraphQLLexer(source)
  }

  mutating func advance() throws {
    token = try lexer.nextToken()
  }

  mutating func expectEndOfDocument() throws {
    guard token == .endOfDocument else {
      throw GatewayError.validation(
        "The GraphQL document must contain exactly one executable operation."
      )
    }
  }

  mutating func parseOperation() throws -> GraphQLOperation {
    var type = GraphQLOperationType.query
    var name: String?
    var variables: [GraphQLVariableDefinition] = []

    if case .name(let keyword) = token {
      switch keyword {
      case "query":
        type = .query
        try advance()
      case "mutation":
        type = .mutation
        try advance()
      case "subscription":
        throw GatewayError.validation("Subscriptions are not supported by this contract.")
      case "fragment":
        throw GatewayError.validation("Fragment definitions are not supported by this contract.")
      default:
        throw GatewayError.validation("Unexpected token '\(keyword)' before the selection set.")
      }

      if case .name(let operationName) = token {
        name = operationName
        try advance()
      }
      if token == .punctuator("(") {
        variables = try parseVariableDefinitions()
      }
    }

    guard token == .punctuator("{") else {
      throw GatewayError.validation("The GraphQL document must start with an operation or selection set.")
    }
    let selections = try parseSelectionSet(depth: 1)
    guard !selections.isEmpty else {
      throw GatewayError.validation("The operation must select at least one field.")
    }
    if type == .mutation, selections.count != 1 {
      throw GatewayError.validation(
        "A mutation document must contain exactly one top-level field.",
        recovery: "Send each mutation as a separate request to avoid ambiguous partial side effects."
      )
    }
    if type == .query, selections.count > GraphQLParser.maximumTopLevelQueryFields {
      throw GatewayError.validation(
        "A query may select at most \(GraphQLParser.maximumTopLevelQueryFields) top-level fields."
      )
    }
    return GraphQLOperation(
      type: type,
      name: name,
      variableDefinitions: variables,
      selections: selections
    )
  }

  private mutating func parseVariableDefinitions() throws -> [GraphQLVariableDefinition] {
    try advance()
    var definitions: [GraphQLVariableDefinition] = []
    while token != .punctuator(")") {
      guard token == .punctuator("$") else {
        throw GatewayError.validation("Expected a variable definition starting with '$'.")
      }
      try advance()
      guard case .name(let variableName) = token else {
        throw GatewayError.validation("Expected a variable name after '$'.")
      }
      try advance()
      guard token == .punctuator(":") else {
        throw GatewayError.validation("Expected ':' after variable $\(variableName).")
      }
      try advance()
      let (typeName, isRequired) = try parseTypeReference()
      if token == .punctuator("=") {
        throw GatewayError.validation("Default variable values are not supported by this contract.")
      }
      definitions.append(
        GraphQLVariableDefinition(name: variableName, typeName: typeName, isRequired: isRequired)
      )
    }
    try advance()
    return definitions
  }

  private mutating func parseTypeReference() throws -> (String, Bool) {
    if token == .punctuator("[") {
      try advance()
      let (inner, innerRequired) = try parseTypeReference()
      guard token == .punctuator("]") else {
        throw GatewayError.validation("Expected ']' to close a list type.")
      }
      try advance()
      var name = "[\(inner)\(innerRequired ? "!" : "")]"
      var required = false
      if token == .punctuator("!") {
        required = true
        name += "!"
        try advance()
      }
      return (name, required)
    }
    guard case .name(let typeName) = token else {
      throw GatewayError.validation("Expected a type name in the variable definition.")
    }
    try advance()
    if token == .punctuator("!") {
      try advance()
      return (typeName, true)
    }
    return (typeName, false)
  }

  private mutating func parseSelectionSet(depth: Int) throws -> [GraphQLField] {
    guard depth <= GraphQLParser.maximumSelectionDepth else {
      throw GatewayError.validation(
        "Selection sets may nest at most \(GraphQLParser.maximumSelectionDepth) levels deep."
      )
    }
    // Consume '{'.
    try advance()
    var fields: [GraphQLField] = []
    while token != .punctuator("}") {
      if token == .endOfDocument {
        throw GatewayError.validation("Unterminated selection set in the GraphQL document.")
      }
      if token == .spread {
        throw GatewayError.validation("Fragment spreads are not supported by this contract.")
      }
      guard case .name(let fieldName) = token else {
        throw GatewayError.validation("Expected a field name in the selection set.")
      }
      try advance()
      if token == .punctuator(":") {
        throw GatewayError.validation("Field aliases are not supported by this contract.")
      }
      var arguments: [String: GraphQLInputValue] = [:]
      if token == .punctuator("(") {
        arguments = try parseArguments(field: fieldName)
      }
      if token == .punctuator("@") {
        throw GatewayError.validation("Directives are not supported by this contract.")
      }
      var selections: [GraphQLField] = []
      if token == .punctuator("{") {
        selections = try parseSelectionSet(depth: depth + 1)
      }
      if fields.contains(where: { $0.name == fieldName }) {
        throw GatewayError.validation("Field \(fieldName) is selected more than once.")
      }
      fields.append(GraphQLField(name: fieldName, arguments: arguments, selections: selections))
    }
    try advance()
    return fields
  }

  private mutating func parseArguments(field: String) throws -> [String: GraphQLInputValue] {
    try advance()
    var arguments: [String: GraphQLInputValue] = [:]
    while token != .punctuator(")") {
      guard case .name(let argumentName) = token else {
        throw GatewayError.validation("Expected an argument name for field \(field).")
      }
      try advance()
      guard token == .punctuator(":") else {
        throw GatewayError.validation("Expected ':' after argument \(argumentName).")
      }
      try advance()
      guard arguments[argumentName] == nil else {
        throw GatewayError.validation("Argument \(argumentName) is supplied more than once.")
      }
      arguments[argumentName] = try parseValue()
    }
    try advance()
    return arguments
  }

  private mutating func parseValue() throws -> GraphQLInputValue {
    switch token {
    case .punctuator("$"):
      try advance()
      guard case .name(let variableName) = token else {
        throw GatewayError.validation("Expected a variable name after '$'.")
      }
      try advance()
      return .variable(variableName)
    case .int(let number):
      try advance()
      return .int(number)
    case .double(let number):
      try advance()
      return .double(number)
    case .string(let text):
      try advance()
      return .string(text)
    case .name(let word):
      try advance()
      switch word {
      case "true": return .bool(true)
      case "false": return .bool(false)
      case "null": return .null
      default: return .enumeration(word)
      }
    case .punctuator("["):
      try advance()
      var items: [GraphQLInputValue] = []
      while token != .punctuator("]") {
        if token == .endOfDocument {
          throw GatewayError.validation("Unterminated list literal in the GraphQL document.")
        }
        items.append(try parseValue())
      }
      try advance()
      return .list(items)
    case .punctuator("{"):
      try advance()
      var fields: [String: GraphQLInputValue] = [:]
      while token != .punctuator("}") {
        guard case .name(let key) = token else {
          throw GatewayError.validation("Expected an input object field name.")
        }
        try advance()
        guard token == .punctuator(":") else {
          throw GatewayError.validation("Expected ':' after input field \(key).")
        }
        try advance()
        guard fields[key] == nil else {
          throw GatewayError.validation("Input field \(key) is supplied more than once.")
        }
        fields[key] = try parseValue()
      }
      try advance()
      return .object(fields)
    default:
      throw GatewayError.validation("Unexpected token in an argument value.")
    }
  }
}
