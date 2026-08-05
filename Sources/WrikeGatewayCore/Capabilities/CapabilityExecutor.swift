import Foundation

/// Executes planned capabilities against Wrike.
///
/// It is the only component that joins a plan, a credential, and a transport.
/// Because both the typed SDK and the GraphQL runtime call `execute(_:)` with a
/// `CapabilityPlan` produced by `CapabilityPlanner`, neither can select a
/// different capability, adapter, validation outcome, or error mapping.
public struct CapabilityExecutor: Sendable {
  public let planner: CapabilityPlanner
  private let transport: any WrikeTransport
  private let credentials: any CredentialProvider
  private let clock: any GatewayClock
  private let retryPolicy: RetryPolicy
  private let requestIDFactory: @Sendable () -> String

  public init(
    planner: CapabilityPlanner,
    transport: any WrikeTransport,
    credentials: any CredentialProvider,
    clock: any GatewayClock = SystemClock(),
    retryPolicy: RetryPolicy = RetryPolicy(),
    requestIDFactory: @escaping @Sendable () -> String = { UUID().uuidString }
  ) {
    self.planner = planner
    self.transport = transport
    self.credentials = credentials
    self.clock = clock
    self.retryPolicy = retryPolicy
    self.requestIDFactory = requestIDFactory
  }

  /// Plans and executes an invocation, returning the full stable result.
  ///
  /// Planning runs first and is entirely local, so unsupported fields, unknown
  /// arguments, malformed identifiers, and oversized page sizes all fail before
  /// any credential is resolved. The scope check needs the credential, so it
  /// runs immediately after resolution and still before transport.
  public func execute(
    _ invocation: CapabilityInvocation
  ) async throws -> WrikeValue {
    let plan = try planner.plan(invocation)
    let credential = try await credentials.credential()
    try planner.validateScopes(
      for: plan.definition,
      grantedScopes: credential.grantedScopes
    )
    return try await execute(plan, credential: credential)
  }

  /// Executes an already-planned capability.
  public func execute(
    _ plan: CapabilityPlan,
    credential: ResolvedCredential? = nil
  ) async throws -> WrikeValue {
    let resolved: ResolvedCredential
    if let credential {
      resolved = credential
    } else {
      resolved = try await credentials.credential()
    }
    let requestID = requestIDFactory()
    let response = try await send(plan: plan, credential: resolved, requestID: requestID)
    do {
      return try ResponseProjection.result(
        for: plan.definition,
        response: response,
        validatedDeletionIdentifier: plan.validatedDeletionIdentifier
      )
    } catch let error as GatewayError {
      throw error.withContext(requestID: requestID, capabilityID: plan.capabilityID)
    }
  }

  private func send(
    plan: CapabilityPlan,
    credential: ResolvedCredential,
    requestID: String
  ) async throws -> WrikeResponse {
    var currentCredential = credential
    var didRefresh = false
    var attempt = 0
    let started = clock.now

    while true {
      attempt += 1
      let prepared = try Self.prepare(
        plan.request,
        credential: currentCredential,
        requestID: requestID
      )

      let response: WrikeResponse
      do {
        response = try await transport.send(prepared)
      } catch let failure as TransportFailure {
        let elapsed = clock.now.timeIntervalSince(started)
        if failure.isTransient,
           let delay = retryPolicy.delayBeforeRetry(
             attempt: attempt,
             method: plan.request.method,
             retryAfterSeconds: nil,
             elapsedSeconds: elapsed
           ) {
          try await clock.sleep(seconds: delay)
          continue
        }
        throw Self.transportError(
          failure,
          plan: plan,
          requestID: requestID
        )
      }

      if let outcome = UpstreamErrorMapper.classify(response) {
        // A 401 permits exactly one refresh attempt; a second 401 is returned.
        if outcome.code == .authenticationFailed, !didRefresh,
           let refreshed = try await credentials.refreshedCredential(after: currentCredential) {
          didRefresh = true
          currentCredential = refreshed
          continue
        }

        let elapsed = clock.now.timeIntervalSince(started)
        if RetryPolicy.isRetryable(status: response.statusCode),
           let delay = retryPolicy.delayBeforeRetry(
             attempt: attempt,
             method: plan.request.method,
             retryAfterSeconds: outcome.retryAfterSeconds,
             elapsedSeconds: elapsed
           ) {
          try await clock.sleep(seconds: delay)
          continue
        }

        throw UpstreamErrorMapper.error(
          from: outcome,
          status: response.statusCode,
          capability: plan.capabilityID,
          requestID: requestID,
          method: plan.request.method
        ).withRecoveryGuidance(plan.definition.rejectionGuidance(for: outcome.code))
      }

      return response
    }
  }

  /// Maps a transport failure. Non-idempotent methods report an unknown
  /// outcome because the transport cannot prove Wrike did not apply the change.
  static func transportError(
    _ failure: TransportFailure,
    plan: CapabilityPlan,
    requestID: String
  ) -> GatewayError {
    if case .localIO(let detail) = failure {
      return GatewayError(
        code: .fileOperationFailed,
        message: "A local file operation failed: \(detail).",
        requestID: requestID,
        capabilityID: plan.capabilityID
      )
    }
    let outcomeUnknown = !plan.request.method.isAutomaticallyRetryable && failure != .cancelled
    return GatewayError(
      code: .transportFailed,
      message: failure.safeSummary,
      requestID: requestID,
      capabilityID: plan.capabilityID,
      outcomeUnknown: outcomeUnknown,
      recoveryGuidance: outcomeUnknown
        ? "The request was not automatically retried. Confirm the current state in Wrike before retrying."
        : nil
    )
  }

  /// Resolves the relative request against the credential's validated base URL.
  public static func prepare(
    _ request: WrikeRequest,
    credential: ResolvedCredential,
    requestID: String
  ) throws -> PreparedRequest {
    var components = URLComponents(
      url: credential.baseURL,
      resolvingAgainstBaseURL: false
    )
    components?.path = credential.baseURL.path + request.path
    if !request.queryItems.isEmpty {
      components?.queryItems = request.queryItems.map { URLQueryItem(name: $0.name, value: $0.value) }
    }
    guard let url = components?.url else {
      throw GatewayError.internalFailure("The capability request could not be resolved to a URL.")
    }
    return PreparedRequest(
      url: url,
      method: request.method,
      headers: request.headers,
      bearerToken: credential.token,
      body: request.body,
      timeout: request.timeout,
      capabilityID: request.capabilityID,
      requestID: requestID,
      responseSink: request.responseSink
    )
  }
}

private extension CapabilityPlan {
  /// Delete capabilities are registry-validated to accept one input object
  /// containing one required identifier. Extracting that already-coerced value
  /// avoids parsing a path or trusting an unvalidated caller value.
  var validatedDeletionIdentifier: String? {
    guard case .deletion = definition.result,
          case .object(let fields)? = validatedArguments["input"]
    else {
      return nil
    }
    let identifiers = fields.values.compactMap { value -> String? in
      guard case .identifier(let identifier) = value else { return nil }
      return identifier.rawValue
    }
    return identifiers.count == 1 ? identifiers[0] : nil
  }
}
