import Foundation

/// Decodes a Wrike API v4 envelope and maps it onto the capability's stable
/// model shape.
///
/// Unknown upstream fields are ignored, but the public projection exposes only
/// registered stable fields. An unexpected `kind`, missing required data, or an
/// incompatible field type is a decoding error rather than a silently empty
/// result.
public enum ResponseProjection {
  /// Extracts the `data` array from the documented envelope.
  public static func envelopeData(_ body: Data, capability: CapabilityID) throws -> [WrikeValue] {
    let value: WrikeValue
    do {
      value = try WrikeValue.decodeJSON(body)
    } catch {
      throw GatewayError(
        code: .upstreamResponseInvalid,
        message: "Wrike returned a response that is not valid JSON.",
        capabilityID: capability
      )
    }
    guard let fields = value.objectValue else {
      throw GatewayError(
        code: .upstreamResponseInvalid,
        message: "Wrike returned a response envelope that is not an object.",
        capabilityID: capability
      )
    }
    guard let data = fields["data"] else {
      throw GatewayError(
        code: .upstreamResponseInvalid,
        message: "Wrike response envelope is missing its data collection.",
        capabilityID: capability
      )
    }
    guard let items = data.arrayValue else {
      throw GatewayError(
        code: .upstreamResponseInvalid,
        message: "Wrike response data is not a collection.",
        capabilityID: capability
      )
    }
    return items
  }

  static func nextPageToken(_ body: Data) -> String? {
    guard let value = try? WrikeValue.decodeJSON(body),
          let token = value["nextPageToken"]?.stringValue,
          !token.isEmpty
    else {
      return nil
    }
    return token
  }

  /// Builds the full stable result for a capability from a transport response.
  ///
  /// A file-output capability is projected from the transport's write outcome
  /// rather than from a body, because its success body was streamed to the
  /// caller's destination path and is deliberately not in memory.
  public static func result(
    for definition: CapabilityDefinition,
    response: WrikeResponse
  ) throws -> WrikeValue {
    guard case .fileOutput(let shape) = definition.result else {
      return try result(for: definition, body: response.body)
    }
    guard let file = response.downloadedFile else {
      // Reached when Wrike answered a binary route with a body-less success,
      // which the delivery refuses to turn into a zero-byte file. Naming that
      // nothing was written is the part an operator cannot see for themselves.
      throw GatewayError(
        code: .upstreamResponseInvalid,
        message: "Wrike returned no content for \(definition.field).",
        capabilityID: definition.id,
        recoveryGuidance: "No file was written. Confirm the attachment still holds content, "
          + "then retry."
      )
    }
    return try project(
      .object([
        "path": .string(file.path),
        "byteCount": .int(file.byteCount),
        "contentType": file.contentType.map(WrikeValue.string) ?? .null
      ]),
      shape: shape,
      capability: definition.id
    )
  }

  /// Builds the full stable result for a capability from a response body.
  public static func result(
    for definition: CapabilityDefinition,
    body: Data
  ) throws -> WrikeValue {
    switch definition.result {
    case .fileOutput:
      throw GatewayError.internalFailure(
        "\(definition.id) writes its body to a file and cannot be projected from memory."
      )
    case .single(let shape):
      let items = try envelopeData(body, capability: definition.id)
      guard let first = items.first else {
        throw GatewayError(
          code: .notFound,
          message: "Wrike returned no \(shape.typeName) for this request.",
          capabilityID: definition.id
        )
      }
      return try project(first, shape: shape, capability: definition.id)

    case .list(let shape):
      let items = try envelopeData(body, capability: definition.id)
      return .array(try items.map { try project($0, shape: shape, capability: definition.id) })

    case .connection(let shape):
      let items = try envelopeData(body, capability: definition.id)
      let nodes = try items.map { try project($0, shape: shape, capability: definition.id) }
      let pageInfo = PageInfo(resultCount: nodes.count, nextPageToken: nextPageToken(body))
      return .object(["nodes": .array(nodes), "pageInfo": pageInfo.stableValue])

    case .payload(let field, let shape):
      let items = try envelopeData(body, capability: definition.id)
      guard let first = items.first else {
        throw GatewayError(
          code: .upstreamResponseInvalid,
          message: "Wrike accepted the \(definition.field) mutation but returned no \(shape.typeName).",
          capabilityID: definition.id
        )
      }
      return .object([field: try project(first, shape: shape, capability: definition.id)])

    case .deletion:
      let items = try envelopeData(body, capability: definition.id)
      // The identifier the caller asked to delete is never echoed back as a
      // confirmation: an empty or unreadable `data` array means Wrike did not
      // confirm the deletion, which is an outcome-unknown result.
      guard let confirmed = confirmedDeletedIdentifier(in: items) else {
        throw GatewayError(
          code: .upstreamResponseInvalid,
          message: "Wrike did not confirm which resource was deleted.",
          capabilityID: definition.id,
          outcomeUnknown: true
        )
      }
      return .object(["deletedId": .string(confirmed)])
    }
  }

  /// Wrike delete responses return either an array of identifier strings or an
  /// array of entities carrying an `id`.
  private static func confirmedDeletedIdentifier(in items: [WrikeValue]) -> String? {
    guard let first = items.first else { return nil }
    if let text = first.stringValue, !text.isEmpty { return text }
    if let identifier = first["id"]?.stringValue, !identifier.isEmpty { return identifier }
    return nil
  }

  /// Maps one upstream entity onto its stable shape.
  public static func project(
    _ value: WrikeValue,
    shape: ModelShape,
    capability: CapabilityID
  ) throws -> WrikeValue {
    guard let upstream = value.objectValue else {
      throw GatewayError(
        code: .upstreamResponseInvalid,
        message: "Wrike returned a \(shape.typeName) entry that is not an object.",
        capabilityID: capability
      )
    }
    var projected: [String: WrikeValue] = [:]
    projected.reserveCapacity(shape.fields.count)
    for field in shape.fields {
      let raw = upstream[field.upstreamName] ?? .null
      if raw.isNull {
        if field.isRequired {
          throw GatewayError(
            code: .upstreamResponseInvalid,
            message: "Wrike \(shape.typeName) is missing the required field \(field.name).",
            capabilityID: capability
          )
        }
        projected[field.name] = .null
        continue
      }
      projected[field.name] = try convert(
        raw,
        to: field.type,
        fieldName: "\(shape.typeName).\(field.name)",
        capability: capability
      )
    }
    return .object(projected)
  }

  private static func convert(
    _ value: WrikeValue,
    to type: ModelFieldType,
    fieldName: String,
    capability: CapabilityID
  ) throws -> WrikeValue {
    switch type {
    case .identifier, .string, .dateTime, .date:
      guard let text = value.stringValue else {
        throw mismatch(fieldName, "a string", value, capability)
      }
      return .string(text)
    case .integer:
      guard let number = value.intValue else {
        throw mismatch(fieldName, "an integer", value, capability)
      }
      return .int(number)
    case .number:
      guard let number = value.doubleValue else {
        throw mismatch(fieldName, "a number", value, capability)
      }
      return .double(number)
    case .boolean:
      guard let flag = value.boolValue else {
        throw mismatch(fieldName, "a boolean", value, capability)
      }
      return .bool(flag)
    case .identifierList, .stringList:
      guard let items = value.arrayValue else {
        throw mismatch(fieldName, "a list", value, capability)
      }
      return .array(try items.map { item in
        guard let text = item.stringValue else {
          throw mismatch(fieldName, "a list of strings", item, capability)
        }
        return .string(text)
      })
    case .object(let nested):
      return try project(value, shape: nested, capability: capability)
    case .objectList(let nested):
      guard let items = value.arrayValue else {
        throw mismatch(fieldName, "a list", value, capability)
      }
      return .array(try items.map { try project($0, shape: nested, capability: capability) })
    }
  }

  private static func mismatch(
    _ fieldName: String,
    _ expected: String,
    _ value: WrikeValue,
    _ capability: CapabilityID
  ) -> GatewayError {
    GatewayError(
      code: .upstreamResponseInvalid,
      message: "Wrike field \(fieldName) was expected to be \(expected) but was \(value.typeDescription).",
      capabilityID: capability
    )
  }
}
