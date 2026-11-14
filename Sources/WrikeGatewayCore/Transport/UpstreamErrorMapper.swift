import Foundation

/// Maps Wrike API v4 HTTP responses to the stable public error contract.
///
/// Upstream bodies are parsed only for the documented `error` code; the
/// `errorDescription` text and any other body content are discarded because
/// they may echo user content or request parameters.
public enum UpstreamErrorMapper {
  public struct Outcome: Sendable, Equatable {
    public let code: GatewayErrorCode
    public let upstreamErrorCode: String?
    public let retryAfterSeconds: Int?
  }

  public static func classify(_ response: WrikeResponse) -> Outcome? {
    guard !(200..<300).contains(response.statusCode) else { return nil }
    let upstream = upstreamErrorCode(in: response.body)
    let retryAfter = retryAfterSeconds(in: response)

    let code: GatewayErrorCode
    switch response.statusCode {
    case 400, 422:
      code = .validationError
    case 401:
      code = .authenticationFailed
    case 403:
      code = .authorizationFailed
    case 404:
      code = .notFound
    case 429:
      code = .rateLimited
    case 500...599:
      code = .upstreamUnavailable
    default:
      code = .upstreamResponseInvalid
    }
    return Outcome(code: code, upstreamErrorCode: upstream, retryAfterSeconds: retryAfter)
  }

  /// Builds the public error. The message names the stable condition and the
  /// documented upstream error code only; no description text is forwarded.
  public static func error(
    from outcome: Outcome,
    status: Int,
    capability: CapabilityID,
    requestID: String,
    method: HTTPMethod
  ) -> GatewayError {
    let summary: String
    switch outcome.code {
    case .validationError:
      summary = "Wrike rejected the request parameters."
    case .authenticationFailed:
      summary = "Wrike rejected the credential."
    case .authorizationFailed:
      summary = "Wrike denied access to this operation."
    case .notFound:
      summary = "The requested Wrike resource was not found."
    case .rateLimited:
      summary = "Wrike rate limit reached."
    case .upstreamUnavailable:
      summary = "Wrike is temporarily unavailable."
    default:
      summary = "Wrike returned an unexpected response."
    }

    var recovery: String?
    switch outcome.code {
    case .authenticationFailed:
      recovery = "Run `auth oauth2` again, or set a valid WRIKE_GATEWAY_ACCESS_TOKEN."
    case .authorizationFailed:
      recovery = "Confirm the token's Wrike scopes and account plan permit this operation."
    case .rateLimited:
      recovery = "Wrike allows 400 requests per minute per token or IP address."
    default:
      recovery = nil
    }

    let unknownOutcome = !method.isAutomaticallyRetryable
      && (outcome.code == .upstreamUnavailable || outcome.code == .rateLimited)

    let message = outcome.upstreamErrorCode.map { "\(summary) Upstream error code: \($0)." } ?? summary
    return GatewayError(
      code: outcome.code,
      message: message,
      requestID: requestID,
      httpStatus: status,
      capabilityID: capability,
      outcomeUnknown: unknownOutcome,
      retryAfterSeconds: outcome.retryAfterSeconds,
      recoveryGuidance: recovery
    )
  }

  /// Extracts only the documented `error` enum value from an error body.
  static func upstreamErrorCode(in body: Data) -> String? {
    guard let value = try? WrikeValue.decodeJSON(body),
          let code = value["error"]?.stringValue,
          !code.isEmpty,
          code.count <= 64,
          code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })
    else {
      return nil
    }
    return code
  }

  static func retryAfterSeconds(in response: WrikeResponse) -> Int? {
    guard let raw = response.header("retry-after") else { return nil }
    guard let seconds = Int(raw.trimmingCharacters(in: .whitespaces)), seconds >= 0 else {
      return nil
    }
    return min(seconds, 300)
  }
}
