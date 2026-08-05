import Foundation

/// An opaque handle to a Keychain TLS identity.
///
/// Runtime code receives only this handle. Private-key material never leaves
/// Keychain, is never exported to kinko, environment variables, temporary
/// files, diagnostics, or test snapshots, and has no public accessor here.
public struct CallbackTLSIdentityHandle: Sendable, Equatable {
  /// A non-reversible reference used only to correlate log-free diagnostics.
  public let reference: String

  /// The validated Keychain identity, reachable only within this module so the
  /// production listener can bind TLS with it. There is no public accessor, no
  /// export path, and no representation that can be printed or encoded.
  let payload: OpaqueIdentityPayload?

  public init(reference: String) {
    self.reference = reference
    self.payload = nil
  }

  init(reference: String, payload: OpaqueIdentityPayload?) {
    self.reference = reference
    self.payload = payload
  }

  public static func == (lhs: CallbackTLSIdentityHandle, rhs: CallbackTLSIdentityHandle) -> Bool {
    lhs.reference == rhs.reference
  }
}

/// Carries a Keychain identity reference between the loader and the listener.
///
/// `AnyObject` storage keeps the concrete Security type out of this file's
/// public surface; only `KeychainTLSIdentityLoader` populates it.
final class OpaqueIdentityPayload: @unchecked Sendable {
  let identity: AnyObject

  init(identity: AnyObject) {
    self.identity = identity
  }
}

/// Every documented invalid-identity outcome. Each maps to
/// `AUTHENTICATION_FAILED` and CLI exit code 3, and each must be reached before
/// the callback listener binds or the browser opens.
public enum CallbackTLSIdentityFailure: String, Sendable, CaseIterable, Equatable {
  case missing
  case duplicate
  case expired
  case untrusted
  case hostnameIncompatible
  case wrongKeyUsage
  case privateKeyUnavailable

  /// Recovery guidance may name the fixed label and required properties. It
  /// must not include certificate contents, private-key material, Keychain
  /// record data, OAuth state, or the authorization URL.
  public var safeMessage: String {
    switch self {
    case .missing:
      return "No callback TLS identity was found in the login Keychain."
    case .duplicate:
      return "More than one callback TLS identity matches the expected label."
    case .expired:
      return "The callback TLS identity certificate is not currently valid."
    case .untrusted:
      return "macOS trust evaluation rejected the callback TLS identity."
    case .hostnameIncompatible:
      return "The callback TLS identity does not cover the localhost host name."
    case .wrongKeyUsage:
      return "The callback TLS identity does not permit TLS server authentication."
    case .privateKeyUnavailable:
      return "The callback TLS identity's private key is not accessible."
    }
  }

  public func recoveryGuidance(label: String) -> String {
    let requirement = "It must be a currently valid certificate with a localhost DNS subject "
      + "alternative name, TLS server authentication key usage, an accessible private key, "
      + "and a chain macOS trusts for https://localhost."
    switch self {
    case .duplicate:
      return "Leave exactly one identity labelled \(label) in the login Keychain. \(requirement)"
    default:
      return "Provision exactly one identity labelled \(label) in the login Keychain. \(requirement)"
    }
  }
}

/// Loads and validates the fixed callback identity. Injected so tests can cover
/// every failure state without a provisioned Keychain and without adding a
/// production override.
public protocol CallbackTLSIdentityLoader: Sendable {
  /// Returns an opaque handle, or throws a `GatewayError` describing a
  /// documented failure. Implementations must complete all validation before
  /// returning so no listener or browser activity can precede a failure.
  func loadIdentity(label: String) throws -> CallbackTLSIdentityHandle
}

extension CallbackTLSIdentityFailure {
  public func asGatewayError(label: String) -> GatewayError {
    GatewayError(
      code: .authenticationFailed,
      message: safeMessage,
      recoveryGuidance: recoveryGuidance(label: label)
    )
  }
}
