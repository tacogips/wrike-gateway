import Foundation
import GatewaySDKKit

/// The parsed command line, shared by all three executables so grammar cannot
/// drift between binaries.
public enum ParsedCommand: Sendable, Equatable {
  case help
  case version
  case graphQLQuery(document: String, variables: Data?, pretty: Bool)
  case graphQLQueryFile(path: String, variablesPath: String?, pretty: Bool)
  case graphQLSchema
  case graphQLSearch(pattern: String, kinds: [String]?, includeReferencedTypes: Bool, limit: Int?, pretty: Bool)
  case graphQLOperation(name: String, variables: Data?, variablesPath: String?, select: [String]?, pretty: Bool)
  case authOAuth2
  case authStatus
  case authLogout
}

public enum CommandParser {
  static let graphQLSearchKinds = ["query", "mutation", "object", "inputObject", "enumeration"]

  /// Parses arguments. Rejected flags include every override the initial
  /// contract forbids: redirect URI, identity label, certificate, trust bypass,
  /// mock transport, fixture path, and arbitrary host.
  public static let forbiddenFlags: [String] = [
    "--redirect-uri",
    "--callback-url",
    "--identity-label",
    "--keychain-label",
    "--certificate",
    "--private-key",
    "--insecure",
    "--allow-insecure",
    "--trust-bypass",
    "--no-verify",
    "--mock-transport",
    "--fixture",
    "--fixtures",
    "--test-mode",
    "--base-url",
    "--api-host",
    "--token",
    "--access-token",
    "--client-secret"
  ]

  public static func parse(_ arguments: [String]) throws -> ParsedCommand {
    guard !arguments.isEmpty else { return .help }

    var pretty = false
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []
    var index = 0

    while index < arguments.count {
      let argument = arguments[index]
      if let forbidden = forbiddenFlags.first(where: { argument == $0 || argument.hasPrefix("\($0)=") }) {
        throw GatewayError.validation(
          "The \(forbidden) option is not supported.",
          recovery: "This binary accepts no credential, host, certificate, or test-mode override."
        )
      }
      switch argument {
      case "--help", "-h":
        return .help
      case "--version":
        return .version
      case "--pretty":
        guard !flags.contains(argument) else {
          throw GatewayError.validation("Option \(argument) is supplied more than once.")
        }
        pretty = true
        flags.insert(argument)
      case "--variables", "--variables-file", "--kinds", "--limit", "--select":
        guard index + 1 < arguments.count else {
          throw GatewayError.validation("Option \(argument) requires a value.")
        }
        guard !arguments[index + 1].hasPrefix("--") else {
          throw GatewayError.validation("Option \(argument) requires a value.")
        }
        guard options[argument] == nil else {
          throw GatewayError.validation("Option \(argument) is supplied more than once.")
        }
        options[argument] = arguments[index + 1]
        index += 1
      case "--include-referenced-types":
        guard !flags.contains(argument) else {
          throw GatewayError.validation("Option \(argument) is supplied more than once.")
        }
        flags.insert(argument)
      default:
        if argument.hasPrefix("-") && argument != "-" {
          throw GatewayError.validation(
            "Unknown option \(argument).",
            recovery: "Run --help to see the supported commands."
          )
        }
        positional.append(argument)
      }
      index += 1
    }

    guard let command = positional.first else { return .help }
    switch command {
    case "graphql":
      return try parseGraphQL(Array(positional.dropFirst()), options: options, flags: flags, pretty: pretty)
    case "auth":
      guard options.isEmpty, flags.subtracting(["--pretty"]).isEmpty else {
        throw GatewayError.validation("The auth commands do not accept variable options.")
      }
      return try parseAuth(Array(positional.dropFirst()))
    default:
      throw GatewayError.validation(
        "Unknown command \(command).",
        recovery: "Supported commands are `graphql` and `auth`."
      )
    }
  }

  private static func parseGraphQL(
    _ positional: [String],
    options: [String: String],
    flags: Set<String>,
    pretty: Bool
  ) throws -> ParsedCommand {
    guard let subcommand = positional.first else {
      throw GatewayError.validation(
        "The graphql command requires a subcommand.",
        recovery: "Use `graphql query`, `graphql query-file`, or `graphql schema`."
      )
    }
    let rest = Array(positional.dropFirst())
    switch subcommand {
    case "query":
      guard rest.count == 1, let document = rest.first else {
        throw GatewayError.validation("`graphql query` accepts exactly one document argument.")
      }
      try validate(options: options, flags: flags, allowed: ["--variables"], command: "graphql query")
      guard options["--variables-file"] == nil else {
        throw GatewayError.validation("`graphql query` uses --variables, not --variables-file.")
      }
      let variables = options["--variables"].map { Data($0.utf8) }
      return .graphQLQuery(document: document, variables: variables, pretty: pretty)
    case "query-file":
      guard rest.count == 1, let path = rest.first else {
        throw GatewayError.validation("`graphql query-file` accepts exactly one path argument.")
      }
      try validate(options: options, flags: flags, allowed: ["--variables-file"], command: "graphql query-file")
      guard options["--variables"] == nil else {
        throw GatewayError.validation("`graphql query-file` uses --variables-file, not --variables.")
      }
      return .graphQLQueryFile(
        path: path,
        variablesPath: options["--variables-file"],
        pretty: pretty
      )
    case "schema":
      guard rest.isEmpty else {
        throw GatewayError.validation("`graphql schema` accepts no additional arguments.")
      }
      try validate(options: options, flags: flags, allowed: [], command: "graphql schema")
      return .graphQLSchema
    case "search":
      guard rest.count == 1, let pattern = rest.first else {
        throw GatewayError.validation("`graphql search` accepts exactly one regex argument.")
      }
      try validate(options: options, flags: flags, allowed: ["--kinds", "--limit", "--include-referenced-types"], command: "graphql search")
      let kinds = try splitCSV(options["--kinds"], option: "--kinds", allowed: graphQLSearchKinds)
      let limit: Int?
      if let raw = options["--limit"] {
        guard let value = Int(raw), value > 0 else {
          throw GatewayError.validation("`--limit` must be a positive integer.")
        }
        limit = value
      } else {
        limit = nil
      }
      return .graphQLSearch(
        pattern: pattern,
        kinds: kinds,
        includeReferencedTypes: flags.contains("--include-referenced-types"),
        limit: limit,
        pretty: pretty
      )
    case "operation":
      guard rest.count == 1, let name = rest.first else {
        throw GatewayError.validation("`graphql operation` accepts exactly one operation name.")
      }
      try validate(options: options, flags: flags, allowed: ["--variables", "--variables-file", "--select"], command: "graphql operation")
      guard !(options["--variables"] != nil && options["--variables-file"] != nil) else {
        throw GatewayError.validation("`graphql operation` accepts either --variables or --variables-file, not both.")
      }
      let select = try splitCSV(options["--select"], option: "--select", allowed: nil)
      return .graphQLOperation(
        name: name,
        variables: options["--variables"].map { Data($0.utf8) },
        variablesPath: options["--variables-file"],
        select: select,
        pretty: pretty
      )
    default:
      throw GatewayError.validation(
        "Unknown graphql subcommand \(subcommand).",
        recovery: "Use `graphql query`, `graphql query-file`, or `graphql schema`."
      )
    }
  }

  private static func validate(
    options: [String: String],
    flags: Set<String>,
    allowed: Set<String>,
    command: String
  ) throws {
    let used = Set(options.keys).union(flags.subtracting(["--pretty"]))
    guard used.isSubset(of: allowed) else {
      throw GatewayError.validation("`\(command)` does not accept \(used.subtracting(allowed).sorted().joined(separator: ", ")).")
    }
  }

  private static func splitCSV(_ raw: String?, option: String, allowed: [String]?) throws -> [String]? {
    guard let raw else { return nil }
    let values = raw.split(separator: ",", omittingEmptySubsequences: false).map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard !values.isEmpty, values.allSatisfy({ !$0.isEmpty }) else {
      throw GatewayError.validation("\(option) requires a non-empty comma-separated list.")
    }
    if let allowed, !values.allSatisfy({ allowed.contains($0) }) {
      throw GatewayError.validation("\(option) accepts: \(allowed.sorted().joined(separator: ", ")).")
    }
    return Array(Set(values)).sorted()
  }

  private static func parseAuth(_ positional: [String]) throws -> ParsedCommand {
    guard let subcommand = positional.first, positional.count == 1 else {
      throw GatewayError.validation(
        "The auth command requires exactly one subcommand.",
        recovery: "Use `auth oauth2`, `auth status`, or `auth logout`."
      )
    }
    switch subcommand {
    case "oauth2": return .authOAuth2
    case "status": return .authStatus
    case "logout": return .authLogout
    default:
      throw GatewayError.validation(
        "Unknown auth subcommand \(subcommand).",
        recovery: "Use `auth oauth2`, `auth status`, or `auth logout`."
      )
    }
  }
}
