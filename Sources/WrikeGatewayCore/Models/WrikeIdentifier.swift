import Foundation

/// A Wrike resource identifier.
///
/// Identifiers are treated as opaque: they are never decoded, normalized,
/// ordered, or used to derive another value. Only length and character-class
/// bounds are enforced so that a malformed argument fails before transport.
public struct WrikeIdentifier: Sendable, Hashable, CustomStringConvertible {
  public static let maximumLength = 256

  public let rawValue: String

  public init(validating rawValue: String, argumentName: String) throws {
    guard !rawValue.isEmpty else {
      throw GatewayError.validation("Argument \(argumentName) must be a non-empty identifier.")
    }
    guard rawValue.count <= Self.maximumLength else {
      throw GatewayError.validation(
        "Argument \(argumentName) exceeds the \(Self.maximumLength) character identifier limit."
      )
    }
    guard rawValue.allSatisfy(Self.isSupported) else {
      throw GatewayError.validation(
        "Argument \(argumentName) contains characters that are not valid in a Wrike identifier."
      )
    }
    self.rawValue = rawValue
  }

  /// Supported characters cover Wrike's documented identifier alphabet plus the
  /// separators used by composite identifiers, without implying any structure.
  private static func isSupported(_ character: Character) -> Bool {
    character.isLetter && character.isASCII
      || character.isNumber && character.isASCII
      || character == "-"
      || character == "_"
  }

  public var description: String { rawValue }
}

/// Explicit pagination input. The client never fetches every page implicitly.
public struct PageInput: Sendable, Equatable {
  public let pageSize: Int?
  public let nextPageToken: String?

  public init(pageSize: Int? = nil, nextPageToken: String? = nil) {
    self.pageSize = pageSize
    self.nextPageToken = nextPageToken
  }

  /// Validates the request against the capability's documented upstream maximum.
  /// Oversized values are rejected rather than silently clamped.
  public func validated(maximumPageSize: Int?, capability: CapabilityID) throws -> PageInput {
    guard let pageSize else { return self }
    guard pageSize > 0 else {
      throw GatewayError.validation("page.pageSize must be greater than zero.")
    }
    guard let maximumPageSize else {
      throw GatewayError.validation(
        "Capability \(capability.rawValue) does not support a page size argument."
      )
    }
    guard pageSize <= maximumPageSize else {
      throw GatewayError.validation(
        "page.pageSize exceeds the maximum of \(maximumPageSize) for \(capability.rawValue)."
      )
    }
    return self
  }
}

/// Stable pagination metadata returned by collection capabilities.
public struct PageInfo: Sendable, Equatable {
  public let resultCount: Int
  public let nextPageToken: String?

  public init(resultCount: Int, nextPageToken: String?) {
    self.resultCount = resultCount
    self.nextPageToken = nextPageToken
  }

  public var stableValue: WrikeValue {
    .object([
      "resultCount": .int(resultCount),
      "nextPageToken": nextPageToken.map(WrikeValue.string) ?? .null
    ])
  }
}
