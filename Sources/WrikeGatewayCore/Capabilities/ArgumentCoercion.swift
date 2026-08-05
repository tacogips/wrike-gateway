import Foundation

/// A validated argument value. Coercion happens once, in the planner, so the
/// typed SDK path and the GraphQL path cannot disagree about what a value means.
public indirect enum ValidatedArgument: Sendable, Equatable {
  case identifier(WrikeIdentifier)
  case identifierList([WrikeIdentifier])
  case string(String)
  case stringList([String])
  case integer(Int)
  case number(Double)
  case boolean(Bool)
  case enumeration(String)
  case scope(ScopeInput)
  case page(PageInput)
  case filePath(String)
  case destinationPath(String)
  case object([String: ValidatedArgument])
}

/// Why a declared destination path cannot receive a downloaded body.
///
/// Each case is a distinct operator mistake with a distinct remedy, so they are
/// reported separately rather than collapsed into one "unusable path".
public enum DestinationProblem: String, Sendable, Equatable, CaseIterable {
  case alreadyExists
  case isDirectory
  case parentMissing
  case parentNotWritable

  public var summary: String {
    switch self {
    case .alreadyExists: return "already exists"
    case .isDirectory: return "names a directory"
    case .parentMissing: return "has no existing parent directory"
    case .parentNotWritable: return "has a parent directory that is not writable"
    }
  }

  public var recovery: String {
    switch self {
    case .alreadyExists:
      return "Choose a path that does not exist yet; a download never replaces a local file."
    case .isDirectory:
      return "Provide the full path of the file to create, including its name."
    case .parentMissing, .parentNotWritable:
      return "Create a writable parent directory first, then retry."
    }
  }
}

/// Checks that a declared file path names a readable regular file, and that a
/// declared destination path can be created.
public protocol FileAccess: Sendable {
  func isReadableRegularFile(atPath path: String) -> Bool
  func fileSize(atPath path: String) -> Int?
  /// `nil` when the path can be created as a new file.
  func destinationProblem(atPath path: String) -> DestinationProblem?
}

public struct SystemFileAccess: FileAccess {
  public init() {}

  public func isReadableRegularFile(atPath path: String) -> Bool {
    var isDirectory: ObjCBool = false
    let manager = FileManager.default
    guard manager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
      return false
    }
    return manager.isReadableFile(atPath: path)
  }

  public func fileSize(atPath path: String) -> Int? {
    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    return (attributes?[.size] as? NSNumber)?.intValue
  }

  /// Checked before the request is sent so an unusable path costs no upstream
  /// call. The transport still refuses to overwrite, so a file that appears
  /// between this check and the write is caught there rather than clobbered.
  public func destinationProblem(atPath path: String) -> DestinationProblem? {
    let manager = FileManager.default
    var isDirectory: ObjCBool = false
    if manager.fileExists(atPath: path, isDirectory: &isDirectory) {
      return isDirectory.boolValue ? .isDirectory : .alreadyExists
    }
    let parent = (path as NSString).deletingLastPathComponent
    let resolved = parent.isEmpty ? FileManager.default.currentDirectoryPath : parent
    var parentIsDirectory: ObjCBool = false
    guard manager.fileExists(atPath: resolved, isDirectory: &parentIsDirectory),
          parentIsDirectory.boolValue
    else {
      return .parentMissing
    }
    return manager.isWritableFile(atPath: resolved) ? nil : .parentNotWritable
  }
}

/// Coerces raw request arguments into validated values.
public struct ArgumentCoercer: Sendable {
  private let fileAccess: any FileAccess

  public init(fileAccess: any FileAccess = SystemFileAccess()) {
    self.fileAccess = fileAccess
  }

  /// Validates all arguments of a capability invocation. Unknown arguments and
  /// missing required arguments both fail before authentication or transport.
  public func coerce(
    arguments: [String: WrikeValue],
    for definition: CapabilityDefinition
  ) throws -> [String: ValidatedArgument] {
    for name in arguments.keys where definition.argument(named: name) == nil {
      throw GatewayError.validation(
        "Unknown argument \(name) for field \(definition.field).",
        recovery: "Run `graphql schema` to see the arguments this binary accepts."
      )
    }

    var validated: [String: ValidatedArgument] = [:]
    for parameter in definition.arguments {
      guard let raw = arguments[parameter.name], !raw.isNull else {
        if parameter.isRequired {
          throw GatewayError.validation(
            "Argument \(parameter.name) is required for field \(definition.field)."
          )
        }
        continue
      }
      if parameter.binding == .destinationPath {
        validated[parameter.name] = .destinationPath(
          try destinationPath(raw, path: parameter.name)
        )
        continue
      }
      validated[parameter.name] = try coerce(
        raw,
        type: parameter.type,
        path: parameter.name,
        capability: definition.id,
        maximumPageSize: definition.maximumPageSize,
        maximumCount: parameter.maximumCount
      )
    }
    return validated
  }

  private func coerce(
    _ value: WrikeValue,
    type: ArgumentValueType,
    path: String,
    capability: CapabilityID,
    maximumPageSize: Int?,
    maximumCount: Int? = nil
  ) throws -> ValidatedArgument {
    switch type {
    case .identifier:
      return .identifier(try identifier(value, path: path))
    case .identifierList:
      let items = try list(value, path: path, maximumCount: maximumCount)
      return .identifierList(
        try items.enumerated().map { try identifier($0.element, path: "\(path)[\($0.offset)]") }
      )
    case .string:
      guard let text = value.stringValue else { throw typeError(path, "String", value) }
      return .string(text)
    case .stringList:
      let items = try list(value, path: path, maximumCount: maximumCount)
      return .stringList(try items.enumerated().map { entry in
        guard let text = entry.element.stringValue else {
          throw typeError("\(path)[\(entry.offset)]", "String", entry.element)
        }
        return text
      })
    case .integer:
      guard let number = value.intValue else { throw typeError(path, "Int", value) }
      return .integer(number)
    case .number:
      guard let number = value.doubleValue else { throw typeError(path, "Float", value) }
      return .number(number)
    case .boolean:
      guard let flag = value.boolValue else { throw typeError(path, "Boolean", value) }
      return .boolean(flag)
    case .enumeration(let name, let cases):
      guard let text = value.stringValue else { throw typeError(path, name, value) }
      guard cases.contains(text) else {
        throw GatewayError.validation(
          "Argument \(path) must be one of: \(cases.joined(separator: ", "))."
        )
      }
      return .enumeration(text)
    case .enumerationList(let name, let cases):
      let items = try list(value, path: path, maximumCount: maximumCount)
      return .stringList(try items.enumerated().map { entry in
        guard let text = entry.element.stringValue else {
          throw typeError("\(path)[\(entry.offset)]", name, entry.element)
        }
        guard cases.contains(text) else {
          throw GatewayError.validation(
            "Argument \(path)[\(entry.offset)] must be one of: \(cases.joined(separator: ", "))."
          )
        }
        return text
      })
    case .scope:
      return .scope(try scope(value, path: path))
    case .page:
      return .page(try page(value, path: path, capability: capability, maximum: maximumPageSize))
    case .inputObject(let shape):
      return .object(try inputObject(value, shape: shape, path: path, capability: capability))
    }
  }

  private func inputObject(
    _ value: WrikeValue,
    shape: InputObjectShape,
    path: String,
    capability: CapabilityID
  ) throws -> [String: ValidatedArgument] {
    guard let fields = value.objectValue else {
      throw typeError(path, shape.typeName, value)
    }
    for name in fields.keys where shape.field(named: name) == nil {
      throw GatewayError.validation("Unknown input field \(path).\(name) for \(shape.typeName).")
    }
    var validated: [String: ValidatedArgument] = [:]
    for field in shape.fields {
      guard let raw = fields[field.name], !raw.isNull else {
        if field.isRequired {
          throw GatewayError.validation("Input field \(path).\(field.name) is required.")
        }
        continue
      }
      if case .filePath = field.binding {
        validated[field.name] = .filePath(try filePath(raw, path: "\(path).\(field.name)"))
        continue
      }
      validated[field.name] = try coerce(
        raw,
        type: field.type,
        path: "\(path).\(field.name)",
        capability: capability,
        maximumPageSize: nil,
        maximumCount: field.maximumCount
      )
    }
    return validated
  }

  private func filePath(_ value: WrikeValue, path: String) throws -> String {
    guard let text = value.stringValue, !text.isEmpty else {
      throw typeError(path, "String", value)
    }
    guard !text.contains("\0") else {
      throw GatewayError(code: .fileOperationFailed, message: "\(path) is not a valid file path.")
    }
    guard fileAccess.isReadableRegularFile(atPath: text) else {
      throw GatewayError(
        code: .fileOperationFailed,
        message: "\(path) does not name a readable regular file.",
        recoveryGuidance: "Provide an absolute path to a readable file on this machine."
      )
    }
    return text
  }

  /// Validates a path the gateway will create. The check is local, so an
  /// unusable destination never costs an upstream request or a credential.
  private func destinationPath(_ value: WrikeValue, path: String) throws -> String {
    guard let text = value.stringValue, !text.isEmpty else {
      throw typeError(path, "String", value)
    }
    guard !text.contains("\0") else {
      throw GatewayError(code: .fileOperationFailed, message: "\(path) is not a valid file path.")
    }
    if let problem = fileAccess.destinationProblem(atPath: text) {
      throw GatewayError(
        code: .fileOperationFailed,
        message: "\(path) \(problem.summary).",
        recoveryGuidance: problem.recovery
      )
    }
    return text
  }

  private func identifier(_ value: WrikeValue, path: String) throws -> WrikeIdentifier {
    guard let text = value.stringValue else { throw typeError(path, "ID", value) }
    return try WrikeIdentifier(validating: text, argumentName: path)
  }

  private func list(
    _ value: WrikeValue,
    path: String,
    maximumCount: Int?
  ) throws -> [WrikeValue] {
    // GraphQL list input coercion accepts a single value as a one-item list.
    let items = value.arrayValue ?? [value]
    if let maximumCount, items.count > maximumCount {
      throw GatewayError.validation(
        "Argument \(path) accepts at most \(maximumCount) values but received \(items.count).",
        recovery: "Split the request into batches of \(maximumCount) or fewer."
      )
    }
    return items
  }

  private func scope(_ value: WrikeValue, path: String) throws -> ScopeInput {
    guard let fields = value.objectValue else {
      throw typeError(path, ScopeInput.typeName, value)
    }
    let known = Set(ScopeInput.Relation.allCases.map(\.rawValue))
    for name in fields.keys where !known.contains(name) {
      throw GatewayError.validation(
        "Unknown scope field \(path).\(name).",
        recovery: "Scope accepts exactly one of: \(known.sorted().joined(separator: ", "))."
      )
    }
    let present = fields.filter { !$0.value.isNull }
    guard present.count == 1, let entry = present.first else {
      throw GatewayError.validation(
        "Argument \(path) must select exactly one scope relation.",
        recovery: "Scope accepts exactly one of: \(known.sorted().joined(separator: ", "))."
      )
    }
    guard let relation = ScopeInput.Relation(rawValue: entry.key) else {
      throw GatewayError.validation("Unknown scope field \(path).\(entry.key).")
    }
    return ScopeInput(
      relation: relation,
      identifier: try identifier(entry.value, path: "\(path).\(entry.key)")
    )
  }

  private func page(
    _ value: WrikeValue,
    path: String,
    capability: CapabilityID,
    maximum: Int?
  ) throws -> PageInput {
    guard let fields = value.objectValue else { throw typeError(path, "PageInput", value) }
    for name in fields.keys where name != "pageSize" && name != "nextPageToken" {
      throw GatewayError.validation("Unknown page field \(path).\(name).")
    }
    var pageSize: Int?
    if let raw = fields["pageSize"], !raw.isNull {
      guard let number = raw.intValue else { throw typeError("\(path).pageSize", "Int", raw) }
      pageSize = number
    }
    var token: String?
    if let raw = fields["nextPageToken"], !raw.isNull {
      guard let text = raw.stringValue, !text.isEmpty else {
        throw typeError("\(path).nextPageToken", "String", raw)
      }
      guard text.count <= 4096 else {
        throw GatewayError.validation("\(path).nextPageToken is longer than the supported limit.")
      }
      token = text
    }
    return try PageInput(pageSize: pageSize, nextPageToken: token)
      .validated(maximumPageSize: maximum, capability: capability)
  }

  private func typeError(_ path: String, _ expected: String, _ value: WrikeValue) -> GatewayError {
    GatewayError.validation("Argument \(path) must be of type \(expected), not \(value.typeDescription).")
  }
}
