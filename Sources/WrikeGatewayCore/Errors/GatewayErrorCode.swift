import Foundation

/// Stable public error codes shared by the Swift SDK, the GraphQL error
/// envelope, and the CLI. The set is closed: adding a code is a contract
/// change that must be reflected in `design-docs/specs/design-graphql-contract.md`.
public enum GatewayErrorCode: String, Sendable, CaseIterable, Codable {
  case validationError = "VALIDATION_ERROR"
  case capabilityDenied = "CAPABILITY_DENIED"
  case authenticationFailed = "AUTHENTICATION_FAILED"
  case authorizationFailed = "AUTHORIZATION_FAILED"
  case notFound = "NOT_FOUND"
  case rateLimited = "RATE_LIMITED"
  case upstreamUnavailable = "UPSTREAM_UNAVAILABLE"
  case transportFailed = "TRANSPORT_FAILED"
  case upstreamResponseInvalid = "UPSTREAM_RESPONSE_INVALID"
  case fileOperationFailed = "FILE_OPERATION_FAILED"
  case internalError = "INTERNAL_ERROR"
}

/// Documented CLI process exit codes from `design-docs/specs/command.md`.
public enum GatewayExitCode: Int32, Sendable, CaseIterable {
  case success = 0
  case usage = 2
  case credential = 3
  case rejectedRequest = 4
  case transientUpstream = 5
  case localResource = 6
  case internalFailure = 70
}

extension GatewayErrorCode {
  /// Maps a stable error code to the documented process exit code.
  public var exitCode: GatewayExitCode {
    switch self {
    case .validationError, .capabilityDenied:
      return .usage
    case .authenticationFailed, .authorizationFailed:
      return .credential
    case .notFound, .upstreamResponseInvalid:
      return .rejectedRequest
    case .rateLimited, .upstreamUnavailable, .transportFailed:
      return .transientUpstream
    case .fileOperationFailed:
      return .localResource
    case .internalError:
      return .internalFailure
    }
  }
}
