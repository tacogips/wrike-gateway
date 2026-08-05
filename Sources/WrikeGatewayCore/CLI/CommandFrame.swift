import Foundation

/// The captured result of running a command.
public struct CommandOutcome: Sendable, Equatable {
  public let standardOutput: String
  public let standardError: String
  public let exitCode: GatewayExitCode

  public init(standardOutput: String, standardError: String, exitCode: GatewayExitCode) {
    self.standardOutput = standardOutput
    self.standardError = standardError
    self.exitCode = exitCode
  }
}

/// The identity of the running executable.
public struct RoleDescriptor: Sendable {
  public let executableName: String
  public let tier: CapabilityTier

  public init(executableName: String, tier: CapabilityTier) {
    self.executableName = executableName
    self.tier = tier
  }

  public static let reader = RoleDescriptor(executableName: "wrike-gateway-reader", tier: .reader)
  public static let writer = RoleDescriptor(executableName: "wrike-gateway-writer", tier: .writer)
  public static let admin = RoleDescriptor(executableName: "wrike-gateway-admin", tier: .admin)
}

/// The shared command frame.
///
/// Each executable's entry point selects a role and delegates here, so parsing,
/// validation, output shaping, and exit-code mapping cannot drift between
/// binaries.
public struct CommandFrame: Sendable {
  private let role: RoleDescriptor
  private let runtime: GraphQLRuntime
  private let authCommands: AuthCommands
  private let readFile: @Sendable (String) throws -> Data

  public init(
    role: RoleDescriptor,
    runtime: GraphQLRuntime,
    authCommands: AuthCommands,
    readFile: @escaping @Sendable (String) throws -> Data = CommandFrame.readFileFromDisk
  ) {
    self.role = role
    self.runtime = runtime
    self.authCommands = authCommands
    self.readFile = readFile
  }

  public static let readFileFromDisk: @Sendable (String) throws -> Data = { path in
    guard let data = FileManager.default.contents(atPath: path) else {
      throw GatewayError(
        code: .fileOperationFailed,
        message: "The file at the supplied path could not be read.",
        recoveryGuidance: "Check that the path names a readable file."
      )
    }
    return data
  }

  public func run(arguments: [String]) async -> CommandOutcome {
    do {
      let command = try CommandParser.parse(arguments)
      return try await execute(command)
    } catch let error as GatewayError {
      return CommandOutcome(
        standardOutput: "",
        standardError: "\(error.description)\n\(usage)\n",
        exitCode: error.exitCode
      )
    } catch {
      return CommandOutcome(
        standardOutput: "",
        standardError: "An unexpected internal failure occurred.\n",
        exitCode: .internalFailure
      )
    }
  }

  private func execute(_ command: ParsedCommand) async throws -> CommandOutcome {
    switch command {
    case .help:
      return CommandOutcome(standardOutput: usage + "\n", standardError: "", exitCode: .success)
    case .version:
      return CommandOutcome(
        standardOutput: GatewayVersion.current + "\n",
        standardError: "",
        exitCode: .success
      )
    case .graphQLSchema:
      return CommandOutcome(
        standardOutput: runtime.printedSchema(),
        standardError: "",
        exitCode: .success
      )
    case .graphQLQuery(let document, let variables, let pretty):
      let decoded = try Self.decodeVariables(variables, source: "--variables")
      return await runGraphQL(document: document, variables: decoded, pretty: pretty)
    case .graphQLQueryFile(let path, let variablesPath, let pretty):
      let documentData = try readFile(path)
      guard let document = String(data: documentData, encoding: .utf8) else {
        throw GatewayError(
          code: .fileOperationFailed,
          message: "The query file is not valid UTF-8 text."
        )
      }
      let variablesData = try variablesPath.map { try readFile($0) }
      let decoded = try Self.decodeVariables(variablesData, source: "--variables-file")
      return await runGraphQL(document: document, variables: decoded, pretty: pretty)
    case .authOAuth2:
      return try await authCommands.login(role: role)
    case .authStatus:
      return await authCommands.status()
    case .authLogout:
      return try await authCommands.logout()
    }
  }

  private func runGraphQL(
    document: String,
    variables: [String: WrikeValue],
    pretty: Bool
  ) async -> CommandOutcome {
    let response = await runtime.execute(document: document, variables: variables)
    return CommandOutcome(
      standardOutput: response.rendered(pretty: pretty) + "\n",
      standardError: "",
      exitCode: response.exitCode
    )
  }

  static func decodeVariables(_ data: Data?, source: String) throws -> [String: WrikeValue] {
    guard let data, !data.isEmpty else { return [:] }
    return try WrikeValue.decodeJSONObject(data, context: source)
  }

  /// Help text names only the commands linked into this binary.
  public var usage: String {
    var lines = [
      "Usage: \(role.executableName) [--pretty] <command>",
      "",
      "Capability tier: \(role.tier.rawValue)",
      "",
      "Commands:",
      "  graphql query '<document>' [--variables '<json-object>']",
      "  graphql query-file <path> [--variables-file <path>]",
      "  graphql schema",
      "  auth oauth2",
      "  auth status",
      "  auth logout",
      "  --help",
      "  --version",
      "",
      "Operations:"
    ]
    let registry = runtime.registry
    lines.append("  Query fields:    \(registry.queryDefinitions.count)")
    if registry.mutationDefinitions.isEmpty {
      lines.append("  Mutation fields: none (this binary is read-only)")
    } else {
      let destructive = registry.mutationDefinitions.filter(\.isDestructive).count
      lines.append(
        "  Mutation fields: \(registry.mutationDefinitions.count) (\(destructive) destructive)"
      )
    }
    lines.append("")
    lines.append("Environment:")
    for key in GatewayEnvironmentKey.allCases.map(\.rawValue).sorted() {
      lines.append("  \(key)")
    }
    lines.append("")
    lines.append("Exit codes: 0 success, 2 usage, 3 credential, 4 rejected, 5 transient, 6 local, 70 internal")
    return lines.joined(separator: "\n")
  }
}

public enum GatewayVersion {
  public static let current = "0.1.0"
}
