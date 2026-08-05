import Foundation

/// The GraphQL response envelope.
public struct GraphQLResponse: Sendable, Equatable {
  public let data: WrikeValue?
  public let errors: [GatewayError]
  public let requestID: String

  public init(data: WrikeValue?, errors: [GatewayError], requestID: String) {
    self.data = data
    self.errors = errors
    self.requestID = requestID
  }

  /// The highest-severity exit code among the errors, or success.
  public var exitCode: GatewayExitCode {
    errors.map(\.exitCode).max(by: { $0.rawValue < $1.rawValue }) ?? .success
  }

  public var stableValue: WrikeValue {
    var envelope: [String: WrikeValue] = ["data": data ?? .null]
    if !errors.isEmpty {
      envelope["errors"] = .array(errors.map { error in
        .object(["message": .string(error.message), "extensions": error.extensions])
      })
    }
    envelope["extensions"] = .object(["requestId": .string(requestID)])
    return .object(envelope)
  }

  public func rendered(pretty: Bool) -> String {
    stableValue.encodedJSON(pretty: pretty)
  }
}

/// Parses, validates, plans, and executes a GraphQL document.
///
/// Execution routes every field through `CapabilityPlanner` and
/// `CapabilityExecutor`, the same components the typed SDK uses. There is no
/// separate GraphQL dispatch table.
public struct GraphQLRuntime: Sendable {
  private let executor: CapabilityExecutor
  private let parser: GraphQLParser
  private let requestIDFactory: @Sendable () -> String

  public init(
    executor: CapabilityExecutor,
    parser: GraphQLParser = GraphQLParser(),
    requestIDFactory: @escaping @Sendable () -> String = { UUID().uuidString }
  ) {
    self.executor = executor
    self.parser = parser
    self.requestIDFactory = requestIDFactory
  }

  public var registry: CapabilityRegistry { executor.planner.registry }

  public func printedSchema() -> String {
    GraphQLSchemaPrinter(registry: registry).print()
  }

  public func execute(document: String, variables: [String: WrikeValue] = [:]) async -> GraphQLResponse {
    let requestID = requestIDFactory()
    do {
      let parsed = try parser.parse(document)
      let prepared = try prepare(parsed, variables: variables)
      return await run(prepared, requestID: requestID)
    } catch let error as GatewayError {
      return GraphQLResponse(data: nil, errors: [error], requestID: requestID)
    } catch {
      return GraphQLResponse(
        data: nil,
        errors: [.internalFailure("The request could not be processed.")],
        requestID: requestID
      )
    }
  }

  /// One validated top-level field, resolved to a capability invocation.
  struct PreparedField: Sendable {
    let responseKey: String
    let definition: CapabilityDefinition
    let invocation: CapabilityInvocation
    let selections: [GraphQLField]
  }

  /// Performs every local check: syntax has already passed, so this validates
  /// variables, capability resolution, tier, arguments, and selections.
  func prepare(_ document: GraphQLDocument, variables: [String: WrikeValue]) throws -> [PreparedField] {
    let operation = document.operation
    try validateVariables(operation: operation, variables: variables)

    return try operation.selections.map { field in
      let definition = try executor.planner.definition(
        field: field.name,
        isMutation: operation.type.isMutation
      )
      var arguments: [String: WrikeValue] = [:]
      for (name, value) in field.arguments {
        arguments[name] = try value.resolved(
          variables: variables,
          path: "\(field.name).\(name)"
        )
      }
      try GraphQLSelectionProjection.validate(
        selections: field.selections,
        for: definition.result,
        fieldName: field.name
      )
      return PreparedField(
        responseKey: field.name,
        definition: definition,
        invocation: CapabilityInvocation(capabilityID: definition.id, arguments: arguments),
        selections: field.selections
      )
    }
  }

  private func validateVariables(
    operation: GraphQLOperation,
    variables: [String: WrikeValue]
  ) throws {
    let declared = Set(operation.variableDefinitions.map(\.name))
    var referenced = Set<String>()
    for field in operation.selections {
      for value in field.arguments.values {
        referenced.formUnion(value.referencedVariables)
      }
    }
    // Each set is sorted before it is reported. Set iteration order varies
    // between runs, so an unsorted loop would name an arbitrary one of several
    // offending variables and the same document could produce a different
    // message every time.
    for name in referenced.subtracting(declared).sorted() {
      throw GatewayError.validation("Variable $\(name) is used but not declared by the operation.")
    }
    for name in declared.subtracting(referenced).sorted() {
      throw GatewayError.validation("Variable $\(name) is declared but never used.")
    }
    for name in variables.keys.sorted() where !declared.contains(name) {
      throw GatewayError.validation("Variable $\(name) was supplied but is not declared by the operation.")
    }
    for definition in operation.variableDefinitions where definition.isRequired {
      guard let value = variables[definition.name], !value.isNull else {
        throw GatewayError.validation("Variable $\(definition.name) is required but was not supplied.")
      }
    }
  }

  /// Executes prepared fields.
  ///
  /// Independent top-level query fields may produce partial data; a mutation
  /// document always has exactly one field, so no ambiguous partial side effect
  /// is possible.
  private func run(_ fields: [PreparedField], requestID: String) async -> GraphQLResponse {
    var data: [String: WrikeValue] = [:]
    var errors: [GatewayError] = []

    for field in fields {
      do {
        let result = try await executor.execute(field.invocation)
        data[field.responseKey] = GraphQLSelectionProjection.project(
          result,
          selections: field.selections
        )
      } catch let error as GatewayError {
        errors.append(error.withContext(requestID: requestID, capabilityID: field.definition.id))
        data[field.responseKey] = .null
      } catch {
        errors.append(.internalFailure("Field \(field.responseKey) failed unexpectedly."))
        data[field.responseKey] = .null
      }
    }

    let succeeded = data.contains { !$0.value.isNull }
    return GraphQLResponse(
      data: succeeded ? .object(data) : nil,
      errors: errors,
      requestID: requestID
    )
  }
}
