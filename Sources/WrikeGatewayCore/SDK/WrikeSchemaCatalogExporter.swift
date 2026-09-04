import GatewaySDKKit

extension GatewaySchemaCatalog {
  /// Exports exactly the capabilities a role's registry may dispatch.
  public static func wrike(
    tier: CapabilityTier,
    definitions: [CapabilityDefinition]
  ) -> GatewaySchemaCatalog {
    let included = definitions
      .filter { tier.includes($0.tier) }
      .sorted { $0.id < $1.id }
    var types: [String: GatewayNamedType] = [
      "PageInfo": GatewayNamedType(
        name: "PageInfo",
        kind: .object([
          GatewayField(name: "nextPageToken", type: .named("String")),
          GatewayField(name: "resultCount", type: .nonNull(.named("Int")))
        ])
      )
    ]
    var hasPage = false
    var hasScope = false
    var hasDeletion = false

    func addArgumentTypes(_ argument: ArgumentDefinition) {
      switch argument.type {
      case .page:
        hasPage = true
      case .scope:
        hasScope = true
      case .enumeration(let name, let values), .enumerationList(let name, let values):
        types[name] = GatewayNamedType(name: name, kind: .enumeration(values))
      case .inputObject(let shape):
        let fields = shape.fields.sorted { $0.name < $1.name }.map { argument in
          addArgumentTypes(argument)
          return GatewayArgument(
            name: argument.name,
            type: wrapped(typeRef(argument.type), required: argument.isRequired),
            isRequired: argument.isRequired
          )
        }
        types[shape.typeName] = GatewayNamedType(name: shape.typeName, kind: .inputObject(fields))
      default:
        break
      }
    }

    for definition in included {
      for argument in definition.arguments { addArgumentTypes(argument) }
      if case .deletion = definition.result { hasDeletion = true }
      guard let shape = definition.result.elementShape else { continue }
      for reachable in shape.reachableShapes {
        let fields = reachable.fields.sorted { $0.name < $1.name }.map { field in
          GatewayField(
            name: field.name,
            type: wrapped(modelTypeRef(field.type), required: field.isRequired)
          )
        }
        types[reachable.typeName] = GatewayNamedType(name: reachable.typeName, kind: .object(fields))
      }
      switch definition.result {
      case .connection(let shape):
        let name = "\(shape.typeName)Connection"
        types[name] = GatewayNamedType(name: name, kind: .object([
          GatewayField(name: "nodes", type: .nonNull(.list(.nonNull(.named(shape.typeName))))),
          GatewayField(name: "pageInfo", type: .nonNull(.named("PageInfo")))
        ]))
      case .payload(let field, let shape):
        let name = "\(shape.typeName)Payload"
        types[name] = GatewayNamedType(name: name, kind: .object([
          GatewayField(name: field, type: .nonNull(.named(shape.typeName)))
        ]))
      default:
        break
      }
    }
    if hasDeletion {
      types["DeletionPayload"] = GatewayNamedType(
        name: "DeletionPayload",
        kind: .object([GatewayField(name: "deletedId", type: .nonNull(.named("ID")))])
      )
    }
    if hasPage {
      types["PageInput"] = GatewayNamedType(
        name: "PageInput",
        kind: .inputObject([
          GatewayArgument(name: "nextPageToken", type: .named("String")),
          GatewayArgument(name: "pageSize", type: .named("Int"))
        ])
      )
    }
    if hasScope {
      let fields = ScopeInput.Relation.allCases.sorted { $0.rawValue < $1.rawValue }.map {
        GatewayArgument(name: $0.rawValue, type: .named("ID"))
      }
      types[ScopeInput.typeName] = GatewayNamedType(name: ScopeInput.typeName, kind: .inputObject(fields))
    }

    let operations = included.map { definition in
      GatewayOperation(
        name: definition.field,
        kind: definition.operationClass.isMutation ? .mutation : .query,
        tier: definition.tier.rawValue,
        arguments: definition.arguments.sorted { $0.name < $1.name }.map {
          GatewayArgument(name: $0.name, type: wrapped(typeRef($0.type), required: $0.isRequired), isRequired: $0.isRequired)
        },
        result: resultTypeRef(definition.result),
        summary: definition.summary,
        isDestructive: definition.isDestructive
      )
    }.sorted { $0.name < $1.name }
    return GatewaySchemaCatalog(
      provider: "wrike-gateway",
      tier: tier.rawValue,
      operations: operations,
      types: types.values.sorted { $0.name < $1.name }
    )
  }
}

private func wrapped(_ reference: GatewayTypeRef, required: Bool) -> GatewayTypeRef {
  required ? .nonNull(reference) : reference
}

private func typeRef(_ type: ArgumentValueType) -> GatewayTypeRef {
  switch type {
  case .identifier: return .named("ID")
  case .identifierList: return .list(.nonNull(.named("ID")))
  case .string: return .named("String")
  case .stringList: return .list(.nonNull(.named("String")))
  case .integer: return .named("Int")
  case .number: return .named("Float")
  case .boolean: return .named("Boolean")
  case .scope: return .named(ScopeInput.typeName)
  case .page: return .named("PageInput")
  case .enumeration(let name, _): return .named(name)
  case .enumerationList(let name, _): return .list(.nonNull(.named(name)))
  case .inputObject(let shape): return .named(shape.typeName)
  }
}

private func modelTypeRef(_ type: ModelFieldType) -> GatewayTypeRef {
  switch type {
  case .identifier: return .named("ID")
  case .string, .dateTime, .date: return .named("String")
  case .integer: return .named("Int")
  case .number: return .named("Float")
  case .boolean: return .named("Boolean")
  case .identifierList: return .list(.nonNull(.named("ID")))
  case .stringList: return .list(.nonNull(.named("String")))
  case .object(let shape): return .named(shape.typeName)
  case .objectList(let shape): return .list(.nonNull(.named(shape.typeName)))
  }
}

private func resultTypeRef(_ result: ResultShape) -> GatewayTypeRef {
  switch result {
  case .single(let shape): return .named(shape.typeName)
  case .connection(let shape): return .named("\(shape.typeName)Connection")
  case .list(let shape): return .nonNull(.list(.nonNull(.named(shape.typeName))))
  case .payload(_, let shape): return .named("\(shape.typeName)Payload")
  case .deletion: return .named("DeletionPayload")
  case .fileOutput(let shape): return .nonNull(.named(shape.typeName))
  }
}
