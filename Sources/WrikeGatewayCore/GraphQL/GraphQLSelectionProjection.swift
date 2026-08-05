import Foundation

/// Validates a selection set against a stable model shape and projects the
/// executed result down to the selected fields.
///
/// Validation runs before authentication or transport, so an unsupported field
/// never causes a Wrike request.
public enum GraphQLSelectionProjection {
  /// Validates the selection set for a capability's result type.
  public static func validate(
    selections: [GraphQLField],
    for result: ResultShape,
    fieldName: String
  ) throws {
    switch result {
    case .single(let shape), .list(let shape):
      try validate(selections: selections, shape: shape, path: fieldName)
    case .connection(let shape):
      try validateConnection(selections: selections, shape: shape, path: fieldName)
    case .payload(let payloadField, let shape):
      try validatePayload(
        selections: selections,
        payloadField: payloadField,
        shape: shape,
        path: fieldName
      )
    case .deletion:
      try validateDeletion(selections: selections, path: fieldName)
    }
  }

  private static func validate(selections: [GraphQLField], shape: ModelShape, path: String) throws {
    guard !selections.isEmpty else {
      throw GatewayError.validation("Field \(path) of type \(shape.typeName) requires a selection set.")
    }
    for selection in selections {
      guard let field = shape.field(named: selection.name) else {
        throw GatewayError.validation(
          "Field \(selection.name) is not part of type \(shape.typeName).",
          recovery: "Run `graphql schema` to see the fields this binary exposes."
        )
      }
      guard selection.arguments.isEmpty else {
        throw GatewayError.validation("Field \(path).\(selection.name) does not accept arguments.")
      }
      if let nested = field.type.nestedShape {
        try validate(
          selections: selection.selections,
          shape: nested,
          path: "\(path).\(selection.name)"
        )
      } else if !selection.selections.isEmpty {
        throw GatewayError.validation(
          "Field \(path).\(selection.name) is a scalar and cannot have a selection set."
        )
      }
    }
  }

  private static func validateConnection(
    selections: [GraphQLField],
    shape: ModelShape,
    path: String
  ) throws {
    guard !selections.isEmpty else {
      throw GatewayError.validation("Field \(path) requires a selection set of nodes and/or pageInfo.")
    }
    for selection in selections {
      switch selection.name {
      case "nodes":
        try validate(selections: selection.selections, shape: shape, path: "\(path).nodes")
      case "pageInfo":
        try validatePageInfo(selections: selection.selections, path: "\(path).pageInfo")
      default:
        throw GatewayError.validation(
          "Field \(selection.name) is not part of type \(shape.typeName)Connection."
        )
      }
    }
  }

  private static func validatePageInfo(selections: [GraphQLField], path: String) throws {
    guard !selections.isEmpty else {
      throw GatewayError.validation("Field \(path) requires a selection set.")
    }
    for selection in selections {
      guard selection.name == "resultCount" || selection.name == "nextPageToken" else {
        throw GatewayError.validation("Field \(selection.name) is not part of type PageInfo.")
      }
      guard selection.selections.isEmpty else {
        throw GatewayError.validation("Field \(path).\(selection.name) is a scalar.")
      }
    }
  }

  private static func validatePayload(
    selections: [GraphQLField],
    payloadField: String,
    shape: ModelShape,
    path: String
  ) throws {
    guard !selections.isEmpty else {
      throw GatewayError.validation("Field \(path) requires a selection set.")
    }
    for selection in selections {
      guard selection.name == payloadField else {
        throw GatewayError.validation(
          "Field \(selection.name) is not part of type \(shape.typeName)Payload."
        )
      }
      try validate(
        selections: selection.selections,
        shape: shape,
        path: "\(path).\(payloadField)"
      )
    }
  }

  private static func validateDeletion(selections: [GraphQLField], path: String) throws {
    guard !selections.isEmpty else {
      throw GatewayError.validation("Field \(path) requires a selection set.")
    }
    for selection in selections {
      guard selection.name == "deletedId" else {
        throw GatewayError.validation("Field \(selection.name) is not part of type DeletionPayload.")
      }
      guard selection.selections.isEmpty else {
        throw GatewayError.validation("Field \(path).deletedId is a scalar.")
      }
    }
  }

  /// Narrows an executed stable result to the selected fields.
  public static func project(_ value: WrikeValue, selections: [GraphQLField]) -> WrikeValue {
    guard !selections.isEmpty else { return value }
    switch value {
    case .array(let items):
      return .array(items.map { project($0, selections: selections) })
    case .object(let fields):
      var projected: [String: WrikeValue] = [:]
      for selection in selections {
        let child = fields[selection.name] ?? .null
        projected[selection.name] = selection.selections.isEmpty
          ? child
          : project(child, selections: selection.selections)
      }
      return .object(projected)
    default:
      return value
    }
  }
}
