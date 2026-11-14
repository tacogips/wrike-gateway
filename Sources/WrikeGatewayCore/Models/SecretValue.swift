import Foundation

/// A wrapper that structurally prevents a secret from reaching any formatted
/// output. Interpolation, `dump`, `print`, mirrors, and error descriptions all
/// render the redaction placeholder; the value is readable only through an
/// explicit `reveal()` call at the point where it is transmitted.
public struct SecretValue: Sendable, Equatable, Hashable {
  public static let placeholder = "<redacted>"

  private let storage: String

  public init(_ value: String) {
    self.storage = value
  }

  /// Returns the underlying value. Call sites are limited to request
  /// construction and credential-store persistence.
  public func reveal() -> String { storage }

  public var isEmpty: Bool { storage.isEmpty }
}

extension SecretValue: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
  public var description: String { Self.placeholder }
  public var debugDescription: String { Self.placeholder }
  public var customMirror: Mirror { Mirror(self, children: []) }
}

extension SecretValue: Codable {
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    self.storage = try container.decode(String.self)
  }

  /// Encoding is permitted because the only encoder used for secrets is the
  /// credential store, which writes to protected storage. Public output paths
  /// use `WrikeValue`, which cannot represent a `SecretValue`.
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(storage)
  }
}
