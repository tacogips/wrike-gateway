import Foundation
import GatewaySDKKit

extension CommandFrame {
  func runGraphQLSearch(
    pattern: String,
    kinds: [String]?,
    includeReferencedTypes: Bool,
    limit: Int?,
    pretty: Bool
  ) throws -> CommandOutcome {
    try GatewaySchemaSearchPattern.validate(pattern)
    let catalog = GatewaySchemaCatalog.wrike(tier: role.tier, definitions: runtime.registry.definitions)
    let selected = try Set((kinds ?? CommandParser.graphQLSearchKinds).map { value in
      guard let kind = GatewayDefinitionKind(rawValue: value) else {
        throw GatewayError.validation("Unknown schema kind \(value).")
      }
      return kind
    })
    let matches: [GatewaySchemaSearch.Match]
    do {
      matches = try GatewaySchemaSearch(catalog: catalog).search(
        pattern,
        options: .init(kinds: selected, includeReferencedTypes: includeReferencedTypes, limit: limit)
      )
    } catch {
      throw GatewayError.validation(String(describing: error))
    }
    let value = GatewayJSONValue.object([
      "count": .int(matches.count),
      "matches": try GatewayJSONValue(any: JSONSerialization.jsonObject(with: JSONEncoder().encode(matches)))
    ])
    return CommandOutcome(
      standardOutput: try value.jsonString(pretty: pretty) + "\n",
      standardError: "",
      exitCode: .success
    )
  }

  func runGraphQLOperation(
    name: String,
    variables: [String: WrikeValue],
    select: [String]?,
    pretty: Bool
  ) async throws -> CommandOutcome {
    let catalog = GatewaySchemaCatalog.wrike(tier: role.tier, definitions: runtime.registry.definitions)
    let request = GatewayOperationRequest(
      operation: name,
      variables: variables.mapValues(GatewayJSONValue.init),
      selection: select.map(GatewaySelection.fields) ?? .default
    )
    let built: GatewayBuiltDocument
    do {
      built = try GatewayDocumentBuilder(catalog: catalog).build(request)
    } catch {
      throw GatewayError.validation(String(describing: error))
    }
    return await runGraphQL(
      document: built.document,
      variables: built.variables.mapValues(WrikeValue.init),
      pretty: pretty
    )
  }
}
