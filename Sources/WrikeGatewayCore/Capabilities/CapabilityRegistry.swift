import Foundation

/// The set of capabilities linked into a binary or SDK consumer.
///
/// Each capability module contributes a fragment; the reader, writer, and admin
/// composition roots merge only the fragments their tier links. A binary can
/// therefore never dispatch a capability whose code it does not contain.
public struct CapabilityRegistry: Sendable {
  public let tier: CapabilityTier
  private let byIdentifier: [CapabilityID: CapabilityDefinition]
  private let byFieldKey: [FieldKey: CapabilityDefinition]

  private struct FieldKey: Hashable, Sendable {
    let isMutation: Bool
    let field: String
  }

  public init(tier: CapabilityTier, definitions: [CapabilityDefinition]) throws {
    var identifiers: [CapabilityID: CapabilityDefinition] = [:]
    var fields: [FieldKey: CapabilityDefinition] = [:]
    var problems: [String] = []

    for definition in definitions {
      guard tier.includes(definition.tier) else {
        problems.append("\(definition.id) requires the \(definition.tier.rawValue) tier.")
        continue
      }
      if identifiers.updateValue(definition, forKey: definition.id) != nil {
        problems.append("Capability \(definition.id) is registered more than once.")
      }
      let key = FieldKey(isMutation: definition.operationClass.isMutation, field: definition.field)
      if fields.updateValue(definition, forKey: key) != nil {
        problems.append("GraphQL field \(definition.field) is registered more than once.")
      }
      problems.append(contentsOf: definition.coherenceProblems())
    }

    guard problems.isEmpty else {
      throw GatewayError.internalFailure(
        "Capability registration is incoherent: \(problems.sorted().joined(separator: " "))"
      )
    }

    self.tier = tier
    self.byIdentifier = identifiers
    self.byFieldKey = fields
  }

  public var definitions: [CapabilityDefinition] {
    byIdentifier.values.sorted { $0.id < $1.id }
  }

  public var queryDefinitions: [CapabilityDefinition] {
    definitions.filter { !$0.operationClass.isMutation }.sorted { $0.field < $1.field }
  }

  public var mutationDefinitions: [CapabilityDefinition] {
    definitions.filter { $0.operationClass.isMutation }.sorted { $0.field < $1.field }
  }

  public func definition(for id: CapabilityID) -> CapabilityDefinition? {
    byIdentifier[id]
  }

  public func definition(field: String, isMutation: Bool) -> CapabilityDefinition? {
    byFieldKey[FieldKey(isMutation: isMutation, field: field)]
  }

  /// Bidirectional coherence: every registered field resolves back to the same
  /// capability id, and every registered id resolves back to the same field.
  public func coherenceProblems() -> [String] {
    var problems: [String] = []
    for definition in definitions {
      let resolved = self.definition(
        field: definition.field,
        isMutation: definition.operationClass.isMutation
      )
      if resolved?.id != definition.id {
        problems.append("Field \(definition.field) does not resolve back to \(definition.id).")
      }
      if self.definition(for: definition.id)?.field != definition.field {
        problems.append("Capability \(definition.id) does not resolve back to its field.")
      }
      if !tier.includes(definition.tier) {
        problems.append("Capability \(definition.id) exceeds the registry tier.")
      }
    }
    return problems
  }
}
