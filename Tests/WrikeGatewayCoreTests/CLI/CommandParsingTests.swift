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
