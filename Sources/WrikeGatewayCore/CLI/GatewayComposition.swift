import Foundation

/// Builds the production object graph for one executable role.
///
/// The composition root exposes no mock transport, fixture path, alternate
/// host, or test-mode selector. Where credentials are read from is injectable
/// so a library host can scope them to one call, but the transport, the
/// capability registry, and the credential store are fixed. Tests build their
/// own graph by calling the individual initializers directly; nothing in this
/// type reads a flag or an undocumented environment variable to change
/// behavior.
public enum GatewayComposition {
  /// All facade-created runtimes in this process coordinate refresh-token
  /// rotation by credential-record identity. The actor is owned by the
  /// composition root rather than by an individual resolver instance.
  private static let refreshCoordinator = OAuthRefreshCoordinator()

  private struct ComposedGraph {
    let runtime: GraphQLRuntime
    let resolver: CredentialResolver
    let exchange: OAuthTokenExchange
    let clock: SystemClock
  }

  /// Composes the dispatch graph without resolving login-only callback settings.
  public static func makeRuntime(
    role: RoleDescriptor,
    definitions: [CapabilityDefinition],
    environment: any EnvironmentReader = ProcessEnvironmentReader()
  ) throws -> GraphQLRuntime {
    try compose(
      role: role,
      definitions: definitions,
      environment: environment,
      store: KinkoCredentialStore(executionContext: .commandLine)
    ).runtime
  }

  /// Composes one caller-scoped SDK runtime.
  ///
  /// The facade must not inherit an embedding application's PATH or arbitrary
  /// environment when it reaches the credential store. Command-line entry
  /// points continue to use `makeRuntime`, preserving their established kinko
  /// discovery behavior.
  static func makeFacadeRuntime(
    role: RoleDescriptor,
    definitions: [CapabilityDefinition],
    environment: any EnvironmentReader
  ) throws -> GraphQLRuntime {
    try makeFacadeRuntime(
      role: role,
      definitions: definitions,
      environment: environment,
      makeCredentialStore: { context in KinkoCredentialStore(executionContext: context) }
    )
  }

  /// Test seam for proving the facade selects the isolated credential boundary
  /// without permitting transport or host-policy replacement.
  static func makeFacadeRuntime(
    role: RoleDescriptor,
    definitions: [CapabilityDefinition],
    environment: any EnvironmentReader,
    makeCredentialStore: @escaping @Sendable (KinkoCredentialStoreExecutionContext) -> any CredentialStore
  ) throws -> GraphQLRuntime {
    try compose(
      role: role,
      definitions: definitions,
      environment: environment,
      store: makeCredentialStore(.facade)
    ).runtime
  }

  /// - Parameter environment: where credentials and endpoint overrides are
  ///   read from. Defaults to the process environment. A host that embeds this
  ///   package as a library (rather than running the executable) passes a
  ///   caller-scoped reader so one call's credentials never have to be written
  ///   into the host process's own environment.
  public static func makeCommandFrame(
    role: RoleDescriptor,
    definitions: [CapabilityDefinition],
    environment: any EnvironmentReader = ProcessEnvironmentReader()
  ) throws -> CommandFrame {
    let graph = try compose(
      role: role,
      definitions: definitions,
      environment: environment,
      store: KinkoCredentialStore(executionContext: .commandLine)
    )
    // Resolved once, at command composition, so a malformed port fails before a login
    // starts rather than after a listener has already bound.
    let callbackPort = try WrikeOAuthEndpoints.resolveCallbackPort(from: environment)
    let authCommands = AuthCommands(
      resolver: graph.resolver,
      environment: environment,
      makeLoginFlow: { client, tier in
        OAuthLoginFlow(
          client: client,
          listener: LoopbackCallbackListener(),
          browser: SystemBrowserOpener(),
          exchange: graph.exchange,
          clock: graph.clock,
          requestedScopes: AuthCommands.requestedScopes(for: tier),
          callbackPort: callbackPort
        )
      }
    )
    return CommandFrame(role: role, runtime: graph.runtime, authCommands: authCommands)
  }

  private static func compose(
    role: RoleDescriptor,
    definitions: [CapabilityDefinition],
    environment: any EnvironmentReader,
    store: any CredentialStore
  ) throws -> ComposedGraph {
    let registry = try CapabilityRegistry(tier: role.tier, definitions: definitions)
    let planner = CapabilityPlanner(registry: registry)
    let transport = URLSessionWrikeTransport()
    let clock = SystemClock()
    // The token endpoint is on the login host with an `/oauth2` path, which the
    // API transport's policy refuses on both counts, so the exchange gets its
    // own transport rather than a widened API policy.
    let exchange = try OAuthTokenExchange(
      transport: URLSessionWrikeTransport(hostPolicy: .oauth)
    )
    let resolver = CredentialResolver(
      environment: environment,
      store: store,
      clock: clock,
      exchange: exchange,
      refreshCoordinator: refreshCoordinator
    )
    let executor = CapabilityExecutor(
      planner: planner,
      transport: transport,
      credentials: resolver,
      clock: clock
    )
    return ComposedGraph(
      runtime: GraphQLRuntime(executor: executor),
      resolver: resolver,
      exchange: exchange,
      clock: clock
    )
  }

  /// Runs a role's command line and terminates with the documented exit code.
  ///
  /// Business JSON goes to stdout; usage diagnostics go to stderr.
  public static func runMain(role: RoleDescriptor, definitions: [CapabilityDefinition]) async -> Never {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let outcome: CommandOutcome
    do {
      let frame = try makeCommandFrame(role: role, definitions: definitions)
      outcome = await frame.run(arguments: arguments)
    } catch let error as GatewayError {
      outcome = CommandOutcome(
        standardOutput: "",
        standardError: error.description + "\n",
        exitCode: error.exitCode
      )
    } catch {
      outcome = CommandOutcome(
        standardOutput: "",
        standardError: "An unexpected internal failure occurred.\n",
        exitCode: .internalFailure
      )
    }

    if !outcome.standardOutput.isEmpty {
      FileHandle.standardOutput.write(Data(outcome.standardOutput.utf8))
    }
    if !outcome.standardError.isEmpty {
      FileHandle.standardError.write(Data(outcome.standardError.utf8))
    }
    exit(outcome.exitCode.rawValue)
  }
}
