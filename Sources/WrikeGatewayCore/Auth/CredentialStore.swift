import Foundation

/// Identifies one stored OAuth record.
///
/// The key is scoped to the tool, the OAuth client, and the Wrike account host
/// so that two accounts or two applications never overwrite each other. The
/// client id is hashed rather than embedded so the record name itself does not
/// disclose a sensitive identifier.
public struct CredentialRecordKey: Sendable, Hashable {
  public static let namespace = "wrike-gateway"

  public let clientFingerprint: String
  public let host: String

  public init(clientID: SecretValue, host: String) {
    self.clientFingerprint = Self.fingerprint(clientID.reveal())
    self.host = host.lowercased()
  }

  public init(clientFingerprint: String, host: String) {
    self.clientFingerprint = clientFingerprint
    self.host = host.lowercased()
  }

  /// The record name used by the credential store.
  ///
  /// kinko 0.1.8 rejects anything that is not a valid environment key
  /// (`invalid environment key "..."`, exit 1): the first character must be a
  /// letter or underscore and the rest must be letters, digits, or
  /// underscores. Dots and hyphens are rejected, so the namespace separator and
  /// the host are encoded with underscores.
  public var storageName: String {
    let prefix = Self.environmentKeySegment(Self.namespace)
    return "\(prefix)_OAUTH_\(Self.environmentKeySegment(clientFingerprint))_\(Self.environmentKeySegment(host))"
  }

  /// Maps one component onto the environment-key character set.
  static func environmentKeySegment(_ value: String) -> String {
    let mapped = value.uppercased().map { character -> Character in
      character.isASCII && (character.isLetter || character.isNumber) ? character : "_"
    }
    return String(mapped)
  }

  /// A short, stable, non-reversible fingerprint. It exists to separate
  /// records, not to protect the client id, which is never printed anyway.
  static func fingerprint(_ value: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in Data(value.utf8) {
      hash ^= UInt64(byte)
      hash = hash &* 0x1000_0000_01b3
    }
    return String(hash, radix: 36)
  }
}

/// Protected storage for OAuth token records.
///
/// `replace` must be atomic: a partially written record would leave a rotated
/// refresh token unusable and the old one already invalidated upstream.
public protocol CredentialStore: Sendable {
  func load(_ key: CredentialRecordKey) async throws -> OAuthTokenState?
  func replace(_ state: OAuthTokenState, for key: CredentialRecordKey) async throws
  func delete(_ key: CredentialRecordKey) async throws -> Bool
  /// Metadata-only existence check that does not decrypt token material.
  func hasRecord(_ key: CredentialRecordKey) async throws -> Bool
}

/// A process-local store used by tests and by `auth status` when no backend is
/// configured. It never touches disk.
public actor InMemoryCredentialStore: CredentialStore {
  private var records: [CredentialRecordKey: OAuthTokenState] = [:]
  private var failNextReplace = false

  public init(seed: [CredentialRecordKey: OAuthTokenState] = [:]) {
    self.records = seed
  }

  /// Simulates an atomic persistence failure for refresh tests.
  public func failNextWrite() {
    failNextReplace = true
  }

  public func load(_ key: CredentialRecordKey) async throws -> OAuthTokenState? {
    records[key]
  }

  public func replace(_ state: OAuthTokenState, for key: CredentialRecordKey) async throws {
    if failNextReplace {
      failNextReplace = false
      throw GatewayError(
        code: .fileOperationFailed,
        message: "The credential store rejected the token record."
      )
    }
    records[key] = state
  }

  public func delete(_ key: CredentialRecordKey) async throws -> Bool {
    records.removeValue(forKey: key) != nil
  }

  public func hasRecord(_ key: CredentialRecordKey) async throws -> Bool {
    records[key] != nil
  }
}
