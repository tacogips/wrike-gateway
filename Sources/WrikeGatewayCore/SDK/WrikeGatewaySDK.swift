import GatewaySDKKit

/// GatewaySDKKit facade for one linked Wrike capability tier.
public struct WrikeGatewaySDK: GatewaySDK {
  public let provider = "wrike-gateway"
  public let tier: String
  public let catalog: GatewaySchemaCatalog

  private let role: RoleDescriptor
  private let definitions: [CapabilityDefinition]
  private let makeRuntime: @Sendable (any EnvironmentReader) throws -> GraphQLRuntime

  public init(role: RoleDescriptor, definitions: [CapabilityDefinition]) throws {
    try self.init(role: role, definitions: definitions, makeRuntime: { environment in
      try GatewayComposition.makeFacadeRuntime(role: role, definitions: definitions, environment: environment)
    })
  }

  init(
    role: RoleDescriptor,
    definitions: [CapabilityDefinition],
    makeRuntime: @escaping @Sendable (any EnvironmentReader) throws -> GraphQLRuntime
  ) throws {
    let registry = try CapabilityRegistry(tier: role.tier, definitions: definitions)
    self.role = role
    self.definitions = registry.definitions
    self.tier = role.tier.rawValue
    self.catalog = .wrike(tier: role.tier, definitions: registry.definitions)
    self.makeRuntime = makeRuntime
  }

  public func searchSchema(
    _ pattern: String,
    options: GatewaySchemaSearch.Options
  ) throws -> [GatewaySchemaSearch.Match] {
    try GatewaySchemaSearchPattern.validate(pattern)
    return try GatewaySchemaSearch(catalog: catalog).search(pattern, options: options)
  }

  public func execute(
    document: String,
    variables: [String: GatewayJSONValue],
    environment: [String: String]
  ) async -> GatewayEnvelope {
    do {
      let runtime = try makeRuntime(StaticEnvironmentReader(extra: environment))
      let response = await runtime.execute(document: document, variables: variables.mapValues(WrikeValue.init))
      return GatewayEnvelope(
        data: response.data.map(GatewayJSONValue.init),
        errors: response.errors.map(Self.envelopeError),
        requestId: response.requestID,
        exitCode: response.exitCode.rawValue,
        rawOutput: response.rendered(pretty: false)
      )
    } catch let error as GatewayError {
      return GatewayEnvelope(
        errors: [Self.envelopeError(error)],
        requestId: error.requestID,
        exitCode: error.exitCode.rawValue
      )
    } catch {
      return GatewayEnvelope.failure(error, exitCode: 70)
    }
  }

  private static func envelopeError(_ error: GatewayError) -> GatewayEnvelopeError {
    let code = error.outcomeUnknown
      ? "\(error.code.rawValue)_OUTCOME_UNKNOWN"
      : error.code.rawValue
    let message = [error.message, error.recoveryGuidance]
      .compactMap { $0 }
      .joined(separator: " ")
    return GatewayEnvelopeError(message: message, code: code)
  }
}
