import Foundation

/// A capability request expressed before validation.
///
/// Typed SDK methods and GraphQL field execution both construct this value.
/// Neither path can reach an adapter without passing through the planner.
public struct CapabilityInvocation: Sendable, Equatable {
  public let capabilityID: CapabilityID
  public let arguments: [String: WrikeValue]

  public init(capabilityID: CapabilityID, arguments: [String: WrikeValue] = [:]) {
    self.capabilityID = capabilityID
    self.arguments = arguments
  }
}

/// The validated, fully resolved outcome of planning an invocation.
public struct CapabilityPlan: Sendable, Equatable {
  public let definition: CapabilityDefinition
  public let request: WrikeRequest
  public let validatedArguments: [String: ValidatedArgument]

  public var capabilityID: CapabilityID { definition.id }
}

/// The single capability-execution planner.
///
/// It resolves the capability, enforces the tier, validates arguments, checks
/// granted scopes, and produces the upstream request. Executing a Wrike call by
/// any other route is not possible from public API because `WrikeRequest` can
/// only be built here or by a capability adapter under test.
public struct CapabilityPlanner: Sendable {
  public let registry: CapabilityRegistry
  private let coercer: ArgumentCoercer

  public init(registry: CapabilityRegistry, coercer: ArgumentCoercer = ArgumentCoercer()) {
    self.registry = registry
    self.coercer = coercer
  }

  /// Resolves a GraphQL field to a capability, applying the tier rule.
  public func definition(field: String, isMutation: Bool) throws -> CapabilityDefinition {
    if let definition = registry.definition(field: field, isMutation: isMutation) {
      return definition
    }
    if let higher = CapabilityCatalog.knownTier(field: field, isMutation: isMutation) {
      throw GatewayError(
        code: .capabilityDenied,
        message: "\(isMutation ? "Mutation" : "Query") \(field) requires the \(higher.rawValue) capability tier.",
        requiredTier: higher,
        recoveryGuidance: "Use the wrike-gateway-\(higher == .admin ? "admin" : "writer") executable."
      )
    }
    throw GatewayError.validation(
      "Unknown \(isMutation ? "mutation" : "query") field \(field).",
      recovery: "Run `graphql schema` to see the fields this binary exposes."
    )
  }

  /// Plans an invocation into an upstream request.
  ///
  /// Every check here is local, so a caller can plan before resolving a
  /// credential. `grantedScopes` is optional for exactly that reason: the
  /// executor plans first, then resolves the credential, then calls
  /// `validateScopes(for:grantedScopes:)`. That ordering is what makes an
  /// invalid argument report `VALIDATION_ERROR` rather than
  /// `AUTHENTICATION_FAILED` when no credential is configured.
  public func plan(
    _ invocation: CapabilityInvocation,
    grantedScopes: [String] = []
  ) throws -> CapabilityPlan {
    guard let definition = registry.definition(for: invocation.capabilityID) else {
      throw GatewayError(
        code: .capabilityDenied,
        message: "Capability \(invocation.capabilityID) is not linked into this binary.",
        capabilityID: invocation.capabilityID
      )
    }
    guard registry.tier.includes(definition.tier) else {
      throw GatewayError(
        code: .capabilityDenied,
        message: "Capability \(definition.id) requires the \(definition.tier.rawValue) tier.",
        capabilityID: definition.id,
        requiredTier: definition.tier
      )
    }
    guard definition.status.isExecutable else {
      throw GatewayError(
        code: .capabilityDenied,
        message: "Capability \(definition.id) is \(definition.status.rawValue) and cannot be executed.",
        capabilityID: definition.id
      )
    }
    try validateScopes(for: definition, grantedScopes: grantedScopes)

    let validated = try coercer.coerce(arguments: invocation.arguments, for: definition)
    let request = try RequestBuilder.build(definition: definition, arguments: validated)
    return CapabilityPlan(definition: definition, request: request, validatedArguments: validated)
  }

  /// Rejects a known scope mismatch before transport.
  ///
  /// An empty `grantedScopes` means the credential exposes no inspectable scope
  /// metadata, as with a permanent token; Wrike stays authoritative in that case.
  public func validateScopes(
    for definition: CapabilityDefinition,
    grantedScopes: [String]
  ) throws {
    guard definition.scopes.isSatisfied(byGranted: grantedScopes) else {
      throw GatewayError(
        code: .authorizationFailed,
        message: "The credential is missing a Wrike scope required by \(definition.id).",
        capabilityID: definition.id,
        recoveryGuidance: "Re-authorize with the \(definition.scopes.recommended) scope."
      )
    }
  }
}

/// Builds the upstream request from a capability definition and validated
/// arguments. This is the only place a path, query, or body is assembled.
enum RequestBuilder {
  static func build(
    definition: CapabilityDefinition,
    arguments: [String: ValidatedArgument]
  ) throws -> WrikeRequest {
    var scopeInput: ScopeInput?
    for parameter in definition.arguments where parameter.binding == .scope {
      if case .scope(let value)? = arguments[parameter.name] { scopeInput = value }
    }

    let template = try resolveTemplate(definition: definition, scope: scopeInput)
    var path = template
    if let scopeInput {
      path = path.replacingOccurrences(of: "{scopeId}", with: escapePathSegment(scopeInput.identifier.rawValue))
    }

    var queryItems: [WrikeQueryItem] = []
    var jsonBody: [String: WrikeValue] = [:]
    var formBody: [WrikeQueryItem] = []
    var upload: FileUploadBody?

    for parameter in definition.arguments {
      guard let value = arguments[parameter.name] else { continue }
      switch parameter.binding {
      case .path(let placeholder):
        guard case .identifier(let identifier) = value else {
          throw GatewayError.internalFailure("Path argument \(parameter.name) is not an identifier.")
        }
        path = path.replacingOccurrences(
          of: "{\(placeholder)}",
          with: escapePathSegment(identifier.rawValue)
        )
      case .query(let name):
        queryItems.append(contentsOf: encodeQuery(named: name, value: value, joined: false))
      case .queryList(let name):
        queryItems.append(contentsOf: encodeQuery(named: name, value: value, joined: true))
      case .bodyJSON(let name):
        jsonBody[name] = jsonValue(value)
      case .bodyForm(let name):
        formBody.append(contentsOf: formItems(named: name, value: value))
      case .page:
        guard case .page(let page) = value else { break }
        if let size = page.pageSize {
          queryItems.append(WrikeQueryItem(name: "pageSize", value: String(size)))
        }
        if let token = page.nextPageToken {
          queryItems.append(WrikeQueryItem(name: "nextPageToken", value: token))
        }
      case .filePath:
        guard case .filePath(let file) = value else { break }
        upload = makeUpload(path: file)
      case .scope, .container:
        // These carry no binding of their own; `break` leaves the switch so the
        // nested input-object bindings below still run.
        break
      }

      if case .object(let fields) = value,
         case .inputObject(let shape) = parameter.type {
        try applyInputObject(
          shape: shape,
          fields: fields,
          path: &path,
          queryItems: &queryItems,
          jsonBody: &jsonBody,
          formBody: &formBody,
          upload: &upload
        )
      }
    }

    guard !path.contains("{") else {
      throw GatewayError.internalFailure(
        "Capability \(definition.id) produced an unresolved path placeholder."
      )
    }

    let body: WrikeRequestBody
    if let upload {
      body = .file(upload)
    } else if !formBody.isEmpty {
      body = .form(formBody.sorted { $0.name < $1.name })
    } else if !jsonBody.isEmpty {
      body = .json(.object(jsonBody))
    } else {
      body = .none
    }

    return WrikeRequest(
      capabilityID: definition.id,
      method: definition.method,
      path: path,
      queryItems: queryItems.sorted { $0.name < $1.name },
      body: body
    )
  }

  /// Input-object fields carry their own bindings so a mutation payload maps to
  /// the upstream request without a second, divergent mapping table.
  private static func applyInputObject(
    shape: InputObjectShape,
    fields: [String: ValidatedArgument],
    path: inout String,
    queryItems: inout [WrikeQueryItem],
    jsonBody: inout [String: WrikeValue],
    formBody: inout [WrikeQueryItem],
    upload: inout FileUploadBody?
  ) throws {
    for field in shape.fields {
      guard let value = fields[field.name] else { continue }
      switch field.binding {
      case .path(let placeholder):
        guard case .identifier(let identifier) = value else {
          throw GatewayError.internalFailure("Input field \(field.name) is not an identifier.")
        }
        path = path.replacingOccurrences(
          of: "{\(placeholder)}",
          with: escapePathSegment(identifier.rawValue)
        )
      case .query(let name):
        queryItems.append(contentsOf: encodeQuery(named: name, value: value, joined: false))
      case .queryList(let name):
        queryItems.append(contentsOf: encodeQuery(named: name, value: value, joined: true))
      case .bodyJSON(let name):
        jsonBody[name] = jsonValue(value)
      case .bodyForm(let name):
        formBody.append(contentsOf: formItems(named: name, value: value))
      case .filePath:
        guard case .filePath(let file) = value else { break }
        upload = makeUpload(path: file)
      case .page, .scope, .container:
        continue
      }
    }
  }

  private static func resolveTemplate(
    definition: CapabilityDefinition,
    scope: ScopeInput?
  ) throws -> String {
    guard let scope else {
      guard !definition.pathTemplate.isEmpty else {
        throw GatewayError.validation(
          "Field \(definition.field) requires a scope argument.",
          recovery: "Provide one of: \(definition.scopeVariants.map(\.relation.rawValue).sorted().joined(separator: ", "))."
        )
      }
      return definition.pathTemplate
    }
    if let variant = definition.scopeVariants.first(where: { $0.relation == scope.relation }) {
      return variant.pathTemplate
    }
    let supported = definition.scopeVariants.map(\.relation.rawValue).sorted().joined(separator: ", ")
    throw GatewayError.validation(
      "Field \(definition.field) does not support scoping by \(scope.relation.rawValue).",
      recovery: supported.isEmpty ? nil : "Supported scopes: \(supported)."
    )
  }

  private static func makeUpload(path: String) -> FileUploadBody {
    let name = (path as NSString).lastPathComponent
    return FileUploadBody(path: path, fileName: name, contentType: "application/octet-stream")
  }

  private static func encodeQuery(
    named name: String,
    value: ValidatedArgument,
    joined: Bool
  ) -> [WrikeQueryItem] {
    switch value {
    case .identifier(let identifier):
      return [WrikeQueryItem(name: name, value: identifier.rawValue)]
    case .string(let text), .enumeration(let text):
      return [WrikeQueryItem(name: name, value: text)]
    case .integer(let number):
      return [WrikeQueryItem(name: name, value: String(number))]
    case .number(let number):
      return [WrikeQueryItem(name: name, value: String(number))]
    case .boolean(let flag):
      return [WrikeQueryItem(name: name, value: flag ? "true" : "false")]
    case .identifierList(let identifiers):
      let values = identifiers.map(\.rawValue)
      return joined
        ? [WrikeQueryItem(name: name, value: values.joined(separator: ","))]
        : values.map { WrikeQueryItem(name: name, value: $0) }
    case .stringList(let items):
      return joined
        ? [WrikeQueryItem(name: name, value: encodeJSONList(items))]
        : items.map { WrikeQueryItem(name: name, value: $0) }
    case .scope, .page, .filePath, .object:
      return []
    }
  }

  private static func formItems(named name: String, value: ValidatedArgument) -> [WrikeQueryItem] {
    switch value {
    case .stringList(let items):
      return [WrikeQueryItem(name: name, value: encodeJSONList(items))]
    case .identifierList(let items):
      return [WrikeQueryItem(name: name, value: encodeJSONList(items.map(\.rawValue)))]
    case .object:
      return [WrikeQueryItem(name: name, value: jsonValue(value).encodedJSON(pretty: false))]
    default:
      return encodeQuery(named: name, value: value, joined: true)
    }
  }

  /// Wrike encodes list-valued form and query parameters as JSON arrays.
  private static func encodeJSONList(_ items: [String]) -> String {
    WrikeValue.array(items.map(WrikeValue.string)).encodedJSON(pretty: false)
  }

  private static func jsonValue(_ value: ValidatedArgument) -> WrikeValue {
    switch value {
    case .identifier(let identifier): return .string(identifier.rawValue)
    case .identifierList(let items): return .array(items.map { .string($0.rawValue) })
    case .string(let text), .enumeration(let text): return .string(text)
    case .stringList(let items): return .array(items.map(WrikeValue.string))
    case .integer(let number): return .int(number)
    case .number(let number): return .double(number)
    case .boolean(let flag): return .bool(flag)
    case .filePath: return .null
    case .scope(let scope): return .string(scope.identifier.rawValue)
    case .page: return .null
    case .object(let fields):
      return .object(fields.mapValues(jsonValue))
    }
  }

  /// Identifiers are already validated to a safe character class, but escaping
  /// keeps path construction correct if that class ever widens.
  private static func escapePathSegment(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_")))
      ?? value
  }
}
