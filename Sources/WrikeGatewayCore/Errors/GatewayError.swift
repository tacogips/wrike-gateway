import Foundation

/// The single public error value produced by the SDK, the capability planner,
/// the transport, and the GraphQL runtime.
///
/// Every stored property is safe to serialize. Secret-bearing values are never
/// admitted into this type: redaction is structural, applied where a value is
/// constructed, not by string replacement after a message is formatted.
public struct GatewayError: Error, Sendable, Equatable {
  public let code: GatewayErrorCode
  /// Human-readable, non-secret summary.
  public let message: String
  /// Local diagnostic correlation id. Never an upstream idempotency key.
  public let requestID: String?
  public let httpStatus: Int?
  public let capabilityID: CapabilityID?
  public let requiredTier: CapabilityTier?
  /// True when a non-idempotent operation failed in a way that cannot prove
  /// Wrike did not apply it. Callers must not assume failure or success.
  public let outcomeUnknown: Bool
  public let retryAfterSeconds: Int?
  /// Non-secret recovery guidance, such as naming a required scope.
  public let recoveryGuidance: String?

  public init(
    code: GatewayErrorCode,
    message: String,
    requestID: String? = nil,
    httpStatus: Int? = nil,
    capabilityID: CapabilityID? = nil,
    requiredTier: CapabilityTier? = nil,
    outcomeUnknown: Bool = false,
    retryAfterSeconds: Int? = nil,
    recoveryGuidance: String? = nil
  ) {
    self.code = code
    self.message = message
    self.requestID = requestID
    self.httpStatus = httpStatus
    self.capabilityID = capabilityID
    self.requiredTier = requiredTier
    self.outcomeUnknown = outcomeUnknown
    self.retryAfterSeconds = retryAfterSeconds
    self.recoveryGuidance = recoveryGuidance
  }

  public var exitCode: GatewayExitCode { code.exitCode }

  /// Stable GraphQL `errors[].extensions` payload.
  public var extensions: WrikeValue {
    var fields: [String: WrikeValue] = ["code": .string(code.rawValue)]
    if let requestID { fields["requestId"] = .string(requestID) }
    if let httpStatus { fields["httpStatus"] = .int(httpStatus) }
    if let capabilityID { fields["capabilityId"] = .string(capabilityID.rawValue) }
    if let requiredTier { fields["requiredTier"] = .string(requiredTier.rawValue) }
    if outcomeUnknown { fields["outcomeUnknown"] = .bool(true) }
    if let retryAfterSeconds { fields["retryAfterSeconds"] = .int(retryAfterSeconds) }
    if let recoveryGuidance { fields["recovery"] = .string(recoveryGuidance) }
    return .object(fields)
  }

  /// Returns a copy carrying request correlation context added by the executor.
  public func withContext(requestID: String?, capabilityID: CapabilityID?) -> GatewayError {
    GatewayError(
      code: code,
      message: message,
      requestID: self.requestID ?? requestID,
      httpStatus: httpStatus,
      capabilityID: self.capabilityID ?? capabilityID,
      requiredTier: requiredTier,
      outcomeUnknown: outcomeUnknown,
      retryAfterSeconds: retryAfterSeconds,
      recoveryGuidance: recoveryGuidance
    )
  }
}

extension GatewayError: CustomStringConvertible {
  /// Only safe fields are rendered; this description is used by CLI stderr output.
  public var description: String { "\(code.rawValue): \(message)" }
}

extension GatewayError {
  public static func validation(_ message: String, recovery: String? = nil) -> GatewayError {
    GatewayError(code: .validationError, message: message, recoveryGuidance: recovery)
  }

  public static func internalFailure(_ message: String) -> GatewayError {
    GatewayError(code: .internalError, message: message)
  }

  public static func authentication(_ message: String, recovery: String? = nil) -> GatewayError {
    GatewayError(code: .authenticationFailed, message: message, recoveryGuidance: recovery)
  }
}
