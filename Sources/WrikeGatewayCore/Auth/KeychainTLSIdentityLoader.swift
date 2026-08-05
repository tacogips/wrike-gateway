import Foundation
import Security

/// The production callback-identity loader.
///
/// It queries the current user's login Keychain for the fixed application
/// label, then validates that exactly one identity matches and that the
/// certificate is currently valid, covers `localhost`, permits TLS server
/// authentication, is trusted by macOS for `https://localhost`, and exposes an
/// accessible private key. Only an opaque handle is returned.
public struct KeychainTLSIdentityLoader: CallbackTLSIdentityLoader {
  public init() {}

  public func loadIdentity(label: String) throws -> CallbackTLSIdentityHandle {
    let query: [String: Any] = [
      kSecClass as String: kSecClassIdentity,
      kSecAttrApplicationLabel as String: Data(label.utf8),
      kSecMatchLimit as String: kSecMatchLimitAll,
      kSecReturnRef as String: true
    ]

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
      throw CallbackTLSIdentityFailure.missing.asGatewayError(label: label)
    }
    guard status == errSecSuccess, let matches = result as? [SecIdentity], !matches.isEmpty else {
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
