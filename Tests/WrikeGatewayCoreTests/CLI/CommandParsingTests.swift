import Foundation
import Testing
import WrikeGatewayCore

@Suite("Command grammar")
struct CommandGrammarTests {
  @Test("No arguments prints help")
  func noArguments() throws {
    #expect(try CommandParser.parse([]) == .help)
  }

  @Test("Help and version are recognized")
  func helpAndVersion() throws {
    #expect(try CommandParser.parse(["--help"]) == .help)
    #expect(try CommandParser.parse(["-h"]) == .help)
    #expect(try CommandParser.parse(["--version"]) == .version)
  }

  @Test("An inline query with variables parses")
  func inlineQuery() throws {
    let parsed = try CommandParser.parse([
      "--pretty", "graphql", "query", "{ account { id } }", "--variables", "{\"a\":1}"
    ])
    guard case .graphQLQuery(let document, let variables, let pretty) = parsed else {
      Issue.record("Expected an inline query")
      return
    }
    #expect(document == "{ account { id } }")
    #expect(pretty)
    #expect(variables == Data("{\"a\":1}".utf8))
  }

  @Test("A query file with a variables file parses")
  func queryFile() throws {
    let parsed = try CommandParser.parse([
      "graphql", "query-file", "/tmp/q.graphql", "--variables-file", "/tmp/v.json"
    ])
    #expect(parsed == .graphQLQueryFile(
      path: "/tmp/q.graphql",
      variablesPath: "/tmp/v.json",
      pretty: false
    ))
  }

  @Test("The auth subcommands parse")
  func authSubcommands() throws {
    #expect(try CommandParser.parse(["auth", "oauth2"]) == .authOAuth2)
    #expect(try CommandParser.parse(["auth", "status"]) == .authStatus)
    #expect(try CommandParser.parse(["auth", "logout"]) == .authLogout)
  }

  @Test("SDK schema commands parse with their isolated options")
  func sdkCommands() throws {
    #expect(try CommandParser.parse([
      "graphql", "search", "task", "--kinds", "query,object", "--limit", "2"
    ]) == .graphQLSearch(
      pattern: "task", kinds: ["object", "query"], includeReferencedTypes: false, limit: 2, pretty: false
    ))
    #expect(try CommandParser.parse([
      "graphql", "operation", "task", "--variables", "{\"id\":\"x\"}", "--select", "id,title"
    ]) == .graphQLOperation(
      name: "task", variables: Data("{\"id\":\"x\"}".utf8), variablesPath: nil, select: ["id", "title"], pretty: false
    ))
    #expect(throws: GatewayError.self) {
      _ = try CommandParser.parse(["graphql", "schema", "--kinds", "query"])
    }
    for unsupported in ["command", "scalar"] {
      #expect(throws: GatewayError.self) {
        _ = try CommandParser.parse(["graphql", "search", "task", "--kinds", unsupported])
      }
    }
  }

  static let sdkUsageErrors: [(String, [String])] = [
    ("duplicate search kind", ["graphql", "search", "task", "--kinds", "query", "--kinds", "object"]),
    ("duplicate search limit", ["graphql", "search", "task", "--limit", "1", "--limit", "2"]),
    ("duplicate referenced types", ["graphql", "search", "task", "--include-referenced-types", "--include-referenced-types"]),
    ("missing search kinds", ["graphql", "search", "task", "--kinds"]),
    ("missing search limit", ["graphql", "search", "task", "--limit"]),
    ("empty search kinds", ["graphql", "search", "task", "--kinds", "query,"]),
    ("unknown search kind", ["graphql", "search", "task", "--kinds", "unknown"]),
    ("non-positive search limit", ["graphql", "search", "task", "--limit", "0"]),
    ("invalid search limit", ["graphql", "search", "task", "--limit", "many"]),
    ("irrelevant search select", ["graphql", "search", "task", "--select", "id"]),
    ("extra search positional", ["graphql", "search", "task", "extra"]),
    ("mutually exclusive operation variables", ["graphql", "operation", "task", "--variables", "{}", "--variables-file", "/tmp/v"]),
    ("duplicate operation variables", ["graphql", "operation", "task", "--variables", "{}", "--variables", "{}"]),
    ("duplicate operation variable file", ["graphql", "operation", "task", "--variables-file", "/tmp/a", "--variables-file", "/tmp/b"]),
    ("missing operation variables", ["graphql", "operation", "task", "--variables"]),
    ("missing operation variable file", ["graphql", "operation", "task", "--variables-file"]),
    ("duplicate operation selection", ["graphql", "operation", "task", "--select", "id", "--select", "title"]),
    ("missing operation selection", ["graphql", "operation", "task", "--select"]),
    ("empty operation selection", ["graphql", "operation", "task", "--select", "id,"]),
    ("irrelevant operation limit", ["graphql", "operation", "task", "--limit", "1"]),
    ("extra operation positional", ["graphql", "operation", "task", "extra"])
  ]

  @Test("SDK command grammar rejects every option-boundary error", arguments: sdkUsageErrors)
  func rejectsSDKUsageErrors(name: String, arguments: [String]) {
    #expect(throws: GatewayError.self) {
      _ = try CommandParser.parse(arguments)
    }
  }

  static let usageErrors: [(String, [String])] = [
    ("unknown command", ["frobnicate"]),
    ("unknown subcommand", ["graphql", "introspect"]),
    ("unknown auth subcommand", ["auth", "revoke"]),
    ("unknown option", ["graphql", "schema", "--verbose"]),
    ("two documents", ["graphql", "query", "{a}", "{b}"]),
    ("no document", ["graphql", "query"]),
    ("schema with extra argument", ["graphql", "schema", "extra"]),
    ("variables on query-file", ["graphql", "query-file", "/tmp/q", "--variables", "{}"]),
    ("variables-file on query", ["graphql", "query", "{a}", "--variables-file", "/tmp/v"]),
    ("duplicate variables", ["graphql", "query", "{a}", "--variables", "{}", "--variables", "{}"]),
    ("missing option value", ["graphql", "query", "{a}", "--variables"]),
    ("auth with two subcommands", ["auth", "status", "logout"])
  ]

  @Test("Usage errors are rejected", arguments: usageErrors)
  func rejectsUsageErrors(name: String, arguments: [String]) throws {
    do {
      _ = try CommandParser.parse(arguments)
      Issue.record("Expected \(name) to be rejected")
    } catch let error as GatewayError {
      #expect(error.code == .validationError)
      #expect(error.exitCode == .usage)
    }
  }

  @Test(
    "Every credential, host, certificate, and test-mode override is rejected",
    arguments: CommandParser.forbiddenFlags
  )
  func rejectsForbiddenFlags(flag: String) throws {
    do {
      _ = try CommandParser.parse(["graphql", "query", "{ account { id } }", flag, "value"])
      Issue.record("Expected \(flag) to be rejected")
    } catch let error as GatewayError {
      #expect(error.code == .validationError)
      #expect(error.message.contains(flag))
    }

    // The `--flag=value` form is rejected too.
    #expect(throws: GatewayError.self) {
      _ = try CommandParser.parse(["graphql", "schema", "\(flag)=value"])
    }
  }

  @Test("Malformed variables JSON is a usage error")
  func malformedVariables() throws {
    #expect(throws: GatewayError.self) {
      _ = try CommandFrame.decodeVariables(Data("not json".utf8), source: "--variables")
    }
    #expect(throws: GatewayError.self) {
      _ = try CommandFrame.decodeVariables(Data("[1,2]".utf8), source: "--variables")
    }
    #expect(try CommandFrame.decodeVariables(nil, source: "--variables").isEmpty)
  }
}

@Suite("Exit code mapping")
struct ExitCodeMappingTests {
  static let expected: [(GatewayErrorCode, GatewayExitCode)] = [
    (.validationError, .usage),
    (.capabilityDenied, .usage),
    (.authenticationFailed, .credential),
    (.authorizationFailed, .credential),
    (.notFound, .rejectedRequest),
    (.upstreamResponseInvalid, .rejectedRequest),
    (.rateLimited, .transientUpstream),
    (.upstreamUnavailable, .transientUpstream),
    (.transportFailed, .transientUpstream),
    (.fileOperationFailed, .localResource),
    (.internalError, .internalFailure)
  ]

  @Test("Each stable code maps to its documented exit code", arguments: expected)
  func mapsExitCodes(code: GatewayErrorCode, exit: GatewayExitCode) {
    #expect(code.exitCode == exit)
  }

  @Test("Every stable code has an exit-code mapping")
  func coversEveryCode() {
    #expect(Set(Self.expected.map(\.0)) == Set(GatewayErrorCode.allCases))
  }
}
