import Foundation

enum GraphQLToken: Equatable {
  case name(String)
  case int(Int)
  case double(Double)
  case string(String)
  case punctuator(Character)
  case spread
  case endOfDocument
}

/// Tokenizes the constrained GraphQL subset.
///
/// The lexer recognizes `...` so the parser can reject fragment spreads with a
/// precise message rather than a confusing punctuation error.
struct GraphQLLexer {
  private let characters: [Character]
  private var index: Int = 0

  init(_ source: String) {
    self.characters = Array(source)
  }

  mutating func nextToken() throws -> GraphQLToken {
    skipIgnored()
    guard index < characters.count else { return .endOfDocument }
    let character = characters[index]

    if character == "." {
      guard index + 2 < characters.count,
            characters[index + 1] == ".",
            characters[index + 2] == "."
      else {
        throw GatewayError.validation("Unexpected '.' in the GraphQL document.")
      }
      index += 3
      return .spread
    }
    if character == "\"" {
      return .string(try readString())
    }
    if character.isNumber || character == "-" {
      return try readNumber()
    }
    if character.isLetter || character == "_" {
      return .name(readName())
    }
    if "{}()[]:=$!,@|&".contains(character) {
      index += 1
      return .punctuator(character)
    }
    throw GatewayError.validation("Unexpected character '\(character)' in the GraphQL document.")
  }

  private mutating func skipIgnored() {
    while index < characters.count {
      let character = characters[index]
      if character.isWhitespace || character == "," {
        index += 1
      } else if character == "#" {
        while index < characters.count, !characters[index].isNewline {
          index += 1
        }
      } else {
        return
      }
    }
  }

  private mutating func readName() -> String {
    var value = ""
    while index < characters.count {
      let character = characters[index]
      guard character.isLetter || character.isNumber || character == "_" else { break }
      value.append(character)
      index += 1
    }
    return value
  }

  private mutating func readNumber() throws -> GraphQLToken {
    var text = ""
    if characters[index] == "-" {
      text.append("-")
      index += 1
    }
    var isFloat = false
    while index < characters.count {
      let character = characters[index]
      if character.isNumber {
        text.append(character)
        index += 1
      } else if character == "." || character == "e" || character == "E" || character == "+" || character == "-" {
        isFloat = true
        text.append(character)
        index += 1
      } else {
        break
      }
    }
    if isFloat {
      guard let value = Double(text) else {
        throw GatewayError.validation("Invalid numeric literal '\(text)' in the GraphQL document.")
      }
      return .double(value)
    }
    guard let value = Int(text) else {
      throw GatewayError.validation("Invalid integer literal '\(text)' in the GraphQL document.")
    }
    return .int(value)
  }

  private mutating func readString() throws -> String {
    // Skip the opening quote.
    index += 1
    if index + 1 < characters.count, characters[index] == "\"", characters[index + 1] == "\"" {
      throw GatewayError.validation("Block strings are not supported in this GraphQL subset.")
    }
    var value = ""
    while index < characters.count {
      let character = characters[index]
      if character == "\"" {
        index += 1
        return value
      }
      if character == "\\" {
        index += 1
        guard index < characters.count else { break }
        switch characters[index] {
        case "n": value.append("\n")
        case "t": value.append("\t")
        case "r": value.append("\r")
        case "\"": value.append("\"")
        case "\\": value.append("\\")
        case "/": value.append("/")
        case "b": value.append("\u{08}")
        case "f": value.append("\u{0C}")
        case "u":
          let start = index + 1
          guard start + 3 < characters.count,
                let scalarValue = UInt32(String(characters[start...(start + 3)]), radix: 16),
                let scalar = Unicode.Scalar(scalarValue)
          else {
            throw GatewayError.validation("Invalid unicode escape in a GraphQL string.")
          }
          value.unicodeScalars.append(scalar)
          index += 4
        default:
          throw GatewayError.validation("Invalid escape sequence in a GraphQL string.")
        }
        index += 1
        continue
      }
      if character.isNewline {
        throw GatewayError.validation("A GraphQL string literal cannot span lines.")
      }
      value.append(character)
      index += 1
    }
    throw GatewayError.validation("Unterminated string literal in the GraphQL document.")
  }
}
