import Foundation
import Security

/// The production callback-identity loader.
///
/// It enumerates the current user's Keychain identities, selects the ones
/// carrying the fixed label, then validates that exactly one matches and that
/// the certificate is currently valid, covers `localhost`, permits TLS server
/// authentication, is trusted by macOS for `https://localhost`, and exposes an
/// accessible private key. Only an opaque handle is returned.
///
/// The label match is applied in code rather than in the `SecItemCopyMatching`
/// query. A `kSecClassIdentity` query against a file-based login Keychain
/// silently ignores `kSecAttrLabel` and `kSecAttrApplicationLabel` and returns
/// every identity, so a query-side filter would report a duplicate on any
/// machine holding more than one identity. `kSecAttrApplicationLabel` is not
/// even returned for an identity, so the readable `kSecAttrLabel` is the
/// attribute the operator provisions and this loader matches.
public struct KeychainTLSIdentityLoader: CallbackTLSIdentityLoader {
  public init() {}

  public func loadIdentity(label: String) throws -> CallbackTLSIdentityHandle {
    let query: [String: Any] = [
      kSecClass as String: kSecClassIdentity,
      kSecMatchLimit as String: kSecMatchLimitAll,
      kSecReturnAttributes as String: true,
      kSecReturnRef as String: true
    ]

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
      throw CallbackTLSIdentityFailure.missing.asGatewayError(label: label)
    }
    guard status == errSecSuccess, let items = result as? [[String: Any]], !items.isEmpty else {
      throw CallbackTLSIdentityFailure.missing.asGatewayError(label: label)
    }

    let matches = Self.identities(in: items, labelled: label)
    if matches.isEmpty {
      throw CallbackTLSIdentityFailure.missing.asGatewayError(label: label)
    }
    guard matches.count == 1, let identity = matches.first else {
      throw CallbackTLSIdentityFailure.duplicate.asGatewayError(label: label)
    }

    var certificate: SecCertificate?
    guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
          let certificate
    else {
      throw CallbackTLSIdentityFailure.missing.asGatewayError(label: label)
    }

    var privateKey: SecKey?
    guard SecIdentityCopyPrivateKey(identity, &privateKey) == errSecSuccess, privateKey != nil else {
      throw CallbackTLSIdentityFailure.privateKeyUnavailable.asGatewayError(label: label)
    }

    try validateTrust(certificate: certificate, label: label)
    return CallbackTLSIdentityHandle(
      reference: CredentialRecordKey.fingerprint(label),
      payload: OpaqueIdentityPayload(identity: identity)
    )
  }

  /// Combines validity period, hostname coverage, key usage, and chain trust
  /// into one policy evaluation for `https://localhost`.
  private func validateTrust(certificate: SecCertificate, label: String) throws {
    let hostnamePolicy = SecPolicyCreateSSL(true, WrikeOAuthEndpoints.callbackHost as CFString)
    var trust: SecTrust?
    guard SecTrustCreateWithCertificates(certificate, hostnamePolicy, &trust) == errSecSuccess,
          let trust
    else {
      throw CallbackTLSIdentityFailure.untrusted.asGatewayError(label: label)
    }

    var evaluationError: CFError?
    if SecTrustEvaluateWithError(trust, &evaluationError) {
      return
    }

    // `SecTrust` reports the most specific failure reason it found. The mapping
    // stays coarse on purpose: the CLI must not disclose certificate contents.
    let failure = Self.classify(evaluationError)
    throw failure.asGatewayError(label: label)
  }

  /// Selects the returned attribute dictionaries whose Keychain label equals
  /// `label`.
  ///
  /// Separated from the Keychain call so the selection rule is testable without
  /// a provisioned Keychain: the caller supplies the dictionaries that
  /// `SecItemCopyMatching` would have returned. This is the filter the Keychain
  /// query itself does not apply.
  static func matchingItems(in items: [[String: Any]], labelled label: String) -> [[String: Any]] {
    items.filter { $0[kSecAttrLabel as String] as? String == label }
  }

  /// Resolves the labelled attribute dictionaries to identity references,
  /// dropping any entry that did not carry one.
  static func identities(in items: [[String: Any]], labelled label: String) -> [SecIdentity] {
    matchingItems(in: items, labelled: label).compactMap { item in
      guard let reference = item[kSecValueRef as String],
            CFGetTypeID(reference as CFTypeRef) == SecIdentityGetTypeID()
      else {
        return nil
      }
      // swiftlint:disable:next force_cast
      return (reference as! SecIdentity)
    }
  }

  static func classify(_ error: CFError?) -> CallbackTLSIdentityFailure {
    guard let error else { return .untrusted }
    let description = CFErrorCopyDescription(error) as String? ?? ""
    let lowered = description.lowercased()
    if lowered.contains("expired") || lowered.contains("not valid before")
      || lowered.contains("not yet valid") {
      return .expired
    }
    if lowered.contains("host") || lowered.contains("name") {
      return .hostnameIncompatible
    }
    if lowered.contains("key usage") || lowered.contains("extended key usage") {
      return .wrongKeyUsage
    }
    return .untrusted
  }
}
