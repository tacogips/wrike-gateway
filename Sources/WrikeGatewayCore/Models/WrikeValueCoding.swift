import Foundation

extension WrikeValue {
  /// Decodes untrusted upstream or CLI-supplied JSON into a `WrikeValue`.
  public static func decodeJSON(_ data: Data) throws -> WrikeValue {
    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    } catch {
      throw GatewayError(
        code: .upstreamResponseInvalid,
        message: "Response body is not valid JSON."
      )
    }
    return try convert(object)
  }

  /// Decodes a caller-supplied JSON document that must be an object, such as
  /// GraphQL variables.
  ///
  /// Parse failures here are local usage errors, not upstream failures, so they
  /// map to `VALIDATION_ERROR` and exit code 2 rather than to the
  /// `UPSTREAM_RESPONSE_INVALID` that `decodeJSON` reports for a Wrike body.
  public static func decodeJSONObject(_ data: Data, context: String) throws -> [String: WrikeValue] {
    let value: WrikeValue
    do {
      value = try decodeJSON(data)
    } catch {
      throw GatewayError.validation(
        "\(context) is not valid JSON.",
        recovery: "Supply a JSON object such as {\"id\": \"IEAAAAAAKQAB5FNY\"}."
      )
    }
    guard case .object(let fields) = value else {
      throw GatewayError.validation("\(context) must decode to a JSON object.")
    }
    return fields
  }

  private static func convert(_ object: Any) throws -> WrikeValue {
    switch object {
    case is NSNull:
      return .null
    case let number as NSNumber:
      return convert(number: number)
    case let text as String:
      return .string(text)
    case let list as [Any]:
      return .array(try list.map(convert))
    case let dictionary as [String: Any]:
      var fields: [String: WrikeValue] = [:]
      fields.reserveCapacity(dictionary.count)
      for (key, value) in dictionary {
        fields[key] = try convert(value)
      }
      return .object(fields)
    default:
      throw GatewayError(
        code: .upstreamResponseInvalid,
        message: "Response body contains an unsupported JSON value."
      )
    }
  }

  private static func convert(number: NSNumber) -> WrikeValue {
    if CFGetTypeID(number) == CFBooleanGetTypeID() {
      return .bool(number.boolValue)
    }
    let type = String(cString: number.objCType)
    if type == "f" || type == "d" {
      return .double(number.doubleValue)
    }
    return .int(number.intValue)
  }

  /// Renders the value as deterministic JSON with sorted object keys.
  public func encodedJSON(pretty: Bool) -> String {
    var output = ""
    Self.write(self, into: &output, pretty: pretty, indent: 0)
    return output
  }

  private static func write(_ value: WrikeValue, into output: inout String, pretty: Bool, indent: Int) {
    let pad = pretty ? String(repeating: " ", count: indent + 2) : ""
    let closePad = pretty ? String(repeating: " ", count: indent) : ""
    let newline = pretty ? "\n" : ""
    let separator = pretty ? ": " : ":"

    switch value {
    case .null:
      output += "null"
    case .bool(let flag):
      output += flag ? "true" : "false"
    case .int(let number):
      output += String(number)
    case .double(let number):
      output += formatDouble(number)
    case .string(let text):
      output += escape(text)
    case .array(let items):
      if items.isEmpty {
        output += "[]"
        return
      }
      output += "[" + newline
      for (offset, item) in items.enumerated() {
        output += pad
        write(item, into: &output, pretty: pretty, indent: indent + 2)
        if offset < items.count - 1 { output += "," }
        output += newline
      }
      output += closePad + "]"
    case .object(let fields):
      if fields.isEmpty {
        output += "{}"
        return
      }
      let keys = fields.keys.sorted()
      output += "{" + newline
      for (offset, key) in keys.enumerated() {
        output += pad + escape(key) + separator
        // `keys` is derived from `fields`, so this lookup always succeeds.
        write(fields[key] ?? .null, into: &output, pretty: pretty, indent: indent + 2)
        if offset < keys.count - 1 { output += "," }
        output += newline
      }
      output += closePad + "}"
    }
  }

  private static func formatDouble(_ number: Double) -> String {
    if number.rounded() == number, number.magnitude < 1e15 {
      return String(format: "%.1f", number)
    }
    return String(number)
  }

  private static func escape(_ text: String) -> String {
    var output = "\""
    for character in text.unicodeScalars {
      switch character {
      case "\"": output += "\\\""
      case "\\": output += "\\\\"
      case "\n": output += "\\n"
      case "\r": output += "\\r"
      case "\t": output += "\\t"
      default:
        if character.value < 0x20 {
          output += String(format: "\\u%04x", character.value)
        } else {
          output.unicodeScalars.append(character)
        }
      }
    }
    return output + "\""
  }
}
