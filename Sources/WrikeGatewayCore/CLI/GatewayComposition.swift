import Foundation

/// Builds the production object graph for one executable role.
///
/// The composition root exposes no mock transport, fixture path, alternate
/// host, or test-mode selector. Tests build their own graph by calling the
/// individual initializers directly; nothing in this type reads a flag or an
/// undocumented environment variable to change behavior.
public enum GatewayComposition {
  public static func makeCommandFrame(
    role: RoleDescriptor,
    definitions: [CapabilityDefinition]
  ) throws -> CommandFrame {
    let registry = try CapabilityRegistry(tier: role.tier, definitions: definitions)
    let planner = CapabilityPlanner(registry: registry)
    let transport = URLSessionWrikeTransport()
    let environment = ProcessEnvironmentReader()
    let store = KinkoCredentialStore()
    let clock = SystemClock()
    let exchange = try OAuthTokenExchange(transport: transport)
    let resolver = CredentialResolver(
      environment: environment,
      store: store,
      clock: clock,
      exchange: exchange
    )
    let executor = CapabilityExecutor(
      planner: planner,
      transport: transport,
      credentials: resolver,
      clock: clock
    )
    let identityLoader = KeychainTLSIdentityLoader()
    let authCommands = AuthCommands(
      resolver: resolver,
      environment: environment,
      identityLoader: identityLoader,
      makeLoginFlow: { client, tier in
        OAuthLoginFlow(
          client: client,
          identityLoader: identityLoader,
          listener: LoopbackCallbackListener(),
          browser: SystemBrowserOpener(),
          exchange: exchange,
          clock: clock,
          requestedScopes: AuthCommands.requestedScopes(for: tier)
        )
      }
    )
    return CommandFrame(
      role: role,
      runtime: GraphQLRuntime(executor: executor),
      authCommands: authCommands
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
