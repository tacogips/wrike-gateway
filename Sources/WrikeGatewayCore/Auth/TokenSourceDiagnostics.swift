import Foundation

extension GatewayError {
  func withCredentialSource(_ mode: CredentialMode) -> GatewayError {
    guard code == .authenticationFailed || httpStatus == 403 else { return self }
    let source = mode == .permanentToken ? "ENVIRONMENT_TOKEN (WRIKE_GATEWAY_ACCESS_TOKEN)" : "OAUTH_STORE"
    let hint = mode == .permanentToken
      ? "Unset WRIKE_GATEWAY_ACCESS_TOKEN to select stored OAuth credentials."
      : "Run auth oauth2 again and keep WRIKE_GATEWAY_ACCESS_TOKEN unset to use the stored OAuth credentials."
    return GatewayError(
      code: code, message: "\(message) (tokenSource=\(source))", requestID: requestID,
      httpStatus: httpStatus, capabilityID: capabilityID, requiredTier: requiredTier,
      outcomeUnknown: outcomeUnknown, retryAfterSeconds: retryAfterSeconds,
      recoveryGuidance: "\(recoveryGuidance ?? "") \(hint)".trimmingCharacters(in: .whitespaces)
    )
  }
}
