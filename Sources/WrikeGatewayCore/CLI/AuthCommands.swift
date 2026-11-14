import Foundation

/// Implements `auth oauth2`, `auth status`, and `auth logout`.
///
/// These commands are available in all three executables because they manage
/// local credential state, not Wrike resources. `auth logout` removes the local
/// OAuth record only; it never calls a Wrike DELETE endpoint.
public struct AuthCommands: Sendable {
  private let resolver: CredentialResolver
  private let environment: any EnvironmentReader
  private let makeLoginFlow: @Sendable (OAuthClientConfiguration, CapabilityTier) throws -> OAuthLoginFlow?

  public init(
    resolver: CredentialResolver,
    environment: any EnvironmentReader,
    makeLoginFlow: @escaping @Sendable (OAuthClientConfiguration, CapabilityTier) throws -> OAuthLoginFlow?
  ) {
    self.resolver = resolver
    self.environment = environment
    self.makeLoginFlow = makeLoginFlow
  }

  /// Scopes requested for a tier. Reader asks for read-only access so a reader
  /// deployment cannot be granted more than it can execute.
  public static func requestedScopes(for tier: CapabilityTier) -> [String] {
    switch tier {
    case .reader:
      return ["wsReadOnly"]
    case .writer:
      return ["wsReadWrite"]
    case .admin:
      return ["wsReadWrite", "amReadWriteGroup"]
    }
  }

  public func login(role: RoleDescriptor) async throws -> CommandOutcome {
    guard let client = OAuthClientConfiguration.resolve(from: environment) else {
      let error = GatewayError.authentication(
        "OAuth client configuration is not available.",
        recovery: "Export \(GatewayEnvironmentKey.clientID.rawValue) and \(GatewayEnvironmentKey.clientSecret.rawValue) through kinko."
      )
      return Self.failure(error)
    }
    guard let flow = try makeLoginFlow(client, role.tier) else {
      return Self.failure(
        GatewayError.authentication("The OAuth login flow is not available in this build.")
      )
    }

    do {
      let (state, _) = try await flow.authorize()
      try await resolver.commit(state)
      let report = AuthStatusReport(
        mode: .oauth2,
        host: state.host,
        scopes: state.grantedScopes,
        expiresAt: state.expiresAt,
        isExpired: false,
        hasRefreshState: true,
        hasClientConfiguration: true
      )
      return Self.success(.object(["authorized": .bool(true), "status": report.stableValue]))
    } catch let error as GatewayError {
      return Self.failure(error)
    }
  }

  public func status() async -> CommandOutcome {
    do {
      // A credential store that cannot answer is not an empty store. Surfacing
      // the error keeps the `kinko unlock` guidance intact instead of reporting
      // a locked vault as "no credential is configured".
      let report = try await resolver.status()
      return Self.success(report.stableValue)
    } catch let error as GatewayError {
      return Self.failure(error)
    } catch {
      return Self.failure(
        GatewayError(code: .fileOperationFailed, message: "The credential store could not be read.")
      )
    }
  }

  public func logout() async throws -> CommandOutcome {
    do {
      let removed = try await resolver.logout()
      return Self.success(.object(["removedLocalRecord": .bool(removed)]))
    } catch let error as GatewayError {
      return Self.failure(error)
    }
  }

  private static func success(_ value: WrikeValue) -> CommandOutcome {
    let envelope = WrikeValue.object(["data": value])
    return CommandOutcome(
      standardOutput: envelope.encodedJSON(pretty: false) + "\n",
      standardError: "",
      exitCode: .success
    )
  }

  private static func failure(_ error: GatewayError) -> CommandOutcome {
    let envelope = WrikeValue.object([
      "data": .null,
      "errors": .array([.object([
        "message": .string(error.message),
        "extensions": error.extensions
      ])])
    ])
    return CommandOutcome(
      standardOutput: envelope.encodedJSON(pretty: false) + "\n",
      standardError: "",
      exitCode: error.exitCode
    )
  }
}
