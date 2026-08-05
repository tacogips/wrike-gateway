import Foundation
import Testing

@testable import WrikeGatewayCore

/// Regression cover for `SecTrust` failure classification.
///
/// macOS quotes the certificate's own name in a trust failure, as in
/// `“localhost” certificate is not trusted`. This product's callback
/// certificate is always named `localhost`, whose name contains the substring
/// `host`, so a naive substring match reports a hostname problem for every
/// failure and sends the operator to reissue a certificate whose subject
/// alternative name was already correct.
@Suite("Callback TLS trust failure classification")
struct TrustFailureClassificationTests {
  @Test("An untrusted localhost chain is reported as untrusted, not as a hostname problem")
  func untrustedLocalhostChainIsNotAHostnameProblem() {
    // Captured verbatim from macOS for a self-signed, untrusted localhost
    // identity in the login Keychain.
    let observed = "\u{201C}localhost\u{201D} certificate is not trusted"
    #expect(KeychainTLSIdentityLoader.classify(description: observed) == .untrusted)
  }

  @Test("A key-usage failure survives the certificate name", arguments: [
    "\u{201C}localhost\u{201D} certificate has bad key usage",
    "\u{201C}localhost\u{201D} certificate has invalid extended key usage"
  ])
  func keyUsageIsReachable(description: String) {
    #expect(KeychainTLSIdentityLoader.classify(description: description) == .wrongKeyUsage)
  }

  @Test("An expired certificate is still reported as expired")
  func expiryWins() {
    let observed = "\u{201C}localhost\u{201D} certificate is expired"
    #expect(KeychainTLSIdentityLoader.classify(description: observed) == .expired)
  }

  @Test("A genuine hostname mismatch is still reported as a hostname problem")
  func genuineHostnameMismatchIsPreserved() {
    let observed = "\u{201C}example.internal\u{201D} certificate name does not match input"
    #expect(
      KeychainTLSIdentityLoader.classify(description: observed) == .hostnameIncompatible
    )
  }

  @Test("A hostname mismatch on a certificate named localhost is still a hostname problem")
  func hostnameMismatchOnLocalhostCertificate() {
    let observed = "\u{201C}localhost\u{201D} certificate name does not match input"
    #expect(
      KeychainTLSIdentityLoader.classify(description: observed) == .hostnameIncompatible
    )
  }

  @Test("A root-of-trust failure is reported as untrusted")
  func rootFailureIsUntrusted() {
    let observed = "\u{201C}localhost\u{201D} certificate: root is not trusted"
    #expect(KeychainTLSIdentityLoader.classify(description: observed) == .untrusted)
  }

  @Test("An unrecognised failure falls back to untrusted")
  func unknownFailureFallsBack() {
    #expect(KeychainTLSIdentityLoader.classify(description: "unspecified failure") == .untrusted)
    #expect(KeychainTLSIdentityLoader.classify(description: "") == .untrusted)
  }

  @Test("A quoted certificate name cannot drive classification")
  func quotedNameIsRemoved() {
    let stripped = KeychainTLSIdentityLoader.removingQuotedNames(
      from: "\u{201C}localhost\u{201D} certificate is not trusted"
    )
    #expect(!stripped.lowercased().contains("localhost"))
    #expect(stripped.lowercased().contains("not trusted"))
  }

  @Test("Classification discloses no certificate detail to the caller")
  func classificationStaysSafe() {
    let failure = KeychainTLSIdentityLoader.classify(
      description: "\u{201C}localhost\u{201D} certificate is not trusted"
    )
    let error = failure.asGatewayError(label: WrikeOAuthEndpoints.callbackIdentityLabel)
    let combined = error.message + (error.recoveryGuidance ?? "")
    #expect(!combined.contains("BEGIN CERTIFICATE"))
    #expect(!combined.lowercased().contains("serial"))
  }
}
