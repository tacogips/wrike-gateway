import Foundation

/// Admission policy for caller-supplied schema-search patterns.
///
/// GatewaySDKKit intentionally supports general regex search, but its matcher
/// evaluates a pattern against every catalog label. The gateway accepts a
/// bounded subset before delegating so a nested quantifier cannot monopolize a
/// command process or an embedding application's CPU.
enum GatewaySchemaSearchPattern {
  static let maximumUTF8Length = 256

  static func validate(_ pattern: String) throws {
    guard pattern.utf8.count <= maximumUTF8Length else {
      throw GatewayError.validation(
        "Schema search patterns must not exceed \(maximumUTF8Length) UTF-8 bytes."
      )
    }

    var groupDepth = 0
    var inCharacterClass = false
    var escaped = false
    var previousWasQuantifier = false
    var previousWasGroup = false
    var hasUnboundedQuantifier = false
    let characters = Array(pattern)

    for index in characters.indices {
      let character = characters[index]
      if escaped {
        if character.isNumber {
          throw GatewayError.validation("Schema search patterns do not support backreferences.")
        }
        escaped = false
        previousWasQuantifier = false
        previousWasGroup = false
        continue
      }
      if character == "\\" {
        escaped = true
        continue
      }
      if inCharacterClass {
        if character == "]" { inCharacterClass = false }
        continue
      }
      if character == "[" {
        inCharacterClass = true
        previousWasQuantifier = false
        previousWasGroup = false
        continue
      }
      if character == "(" {
        let next = characters.index(after: index)
        if next < characters.endIndex, characters[next] == "?" {
          throw GatewayError.validation("Schema search patterns do not support lookaround or inline options.")
        }
        groupDepth += 1
        previousWasQuantifier = false
        previousWasGroup = false
        continue
      }
      if character == ")" {
        groupDepth -= 1
        previousWasQuantifier = false
        previousWasGroup = true
        continue
      }
      if character == "{" || character == "}" {
        throw GatewayError.validation("Schema search patterns do not support counted quantifiers.")
      }
      if isQuantifier(character) {
        guard !previousWasQuantifier, !previousWasGroup, !hasUnboundedQuantifier else {
          throw GatewayError.validation(
            "Schema search patterns allow at most one unbounded quantifier."
          )
        }
        hasUnboundedQuantifier = true
        previousWasQuantifier = true
        previousWasGroup = false
        continue
      }
      previousWasQuantifier = false
      previousWasGroup = false
    }

    guard !escaped, !inCharacterClass, groupDepth == 0 else {
      throw GatewayError.validation("Schema search pattern syntax is incomplete.")
    }
  }

  private static func isQuantifier(_ character: Character) -> Bool {
    character == "*" || character == "+" || character == "?"
  }
}
