import Foundation
import Testing
import WrikeGatewayAdmin
import WrikeGatewayCore
import WrikeGatewayRead
import WrikeGatewayTestSupport
import WrikeGatewayWrite

@Suite("SDKCommandTests")
struct SDKCommandTests {
  @Test("Schema search is local, tier-filtered, and deterministic")
  func search() async throws {
    let transport = RecordingTransport.succeeding(
      json: WrikeFixtures.envelope(kind: "tasks", data: WrikeFixtures.task)
    )
    let frame = try makeFrame(transport: transport)
    let result = await frame.run(arguments: [
      "graphql", "search", "task", "--kinds", "query,object", "--limit", "1"
    ])
    #expect(result.exitCode == .success)
    #expect(result.standardOutput.hasPrefix("{\"count\":1,\"matches\":["))
    #expect(await transport.requestCount == 0)
    let repeated = await frame.run(arguments: [
      "graphql", "search", "task", "--kinds", "query,object", "--limit", "1"
    ])
    #expect(repeated.standardOutput == result.standardOutput)
  }

  @Test("Operation builds a selected document and reads file variables")
  func operation() async throws {
    let transport = RecordingTransport.succeeding(
      json: WrikeFixtures.envelope(kind: "tasks", data: WrikeFixtures.task)
    )
    let frame = try makeFrame(
      transport: transport,
      files: ["/tmp/task-vars.json": "{\"id\":\"IEAAAAAAKQAB5FNY\"}"]
    )
    let result = await frame.run(arguments: [
      "graphql", "operation", "task", "--variables-file", "/tmp/task-vars.json", "--select", "id,title"
    ])
    #expect(result.exitCode == .success)
    #expect(result.standardOutput.contains("\"title\":\"Prepare launch\""))
    #expect(!result.standardOutput.contains("\"accountId\""))
    #expect(try await transport.firstRequest().path == "/api/v4/tasks/IEAAAAAAKQAB5FNY")
  }

  @Test("SDK command errors and help preserve the command contract")
  func errorsAndHelp() async throws {
    let frame = try makeFrame(transport: RecordingTransport())
    for kind in ["command", "scalar"] {
      let result = await frame.run(arguments: ["graphql", "search", "task", "--kinds", kind])
      #expect(result.exitCode == .usage)
    }
    let unknown = await frame.run(arguments: ["graphql", "operation", "notAnOperation"])
    #expect(unknown.exitCode == .usage)
    let help = await frame.run(arguments: ["--help"])
    #expect(help.standardOutput.contains("graphql search <regex>"))
    #expect(help.standardOutput.contains("graphql operation <name>"))
  }

  @Test("Search validates regexes, expands references, and preserves pretty JSON")
  func searchValidationAndRendering() async throws {
    let transport = RecordingTransport()
    let frame = try makeFrame(transport: transport)
    let invalid = await frame.run(arguments: ["graphql", "search", "["])
    #expect(invalid.exitCode == .usage)
    #expect(invalid.standardError.contains("VALIDATION_ERROR"))

    let started = Date()
    let expensive = await frame.run(arguments: ["graphql", "search", "(.+)+Z", "--limit", "1"])
    #expect(expensive.exitCode == .usage)
    #expect(expensive.standardError.contains("unbounded quantifier"))
    #expect(Date().timeIntervalSince(started) < 1)

    let overlappingStarted = Date()
    let overlapping = await frame.run(arguments: [
      "graphql", "search", ".*.*.*.*.*.*.*.*Z", "--limit", "1"
    ])
    #expect(overlapping.exitCode == .usage)
    #expect(overlapping.standardError.contains("at most one unbounded quantifier"))
    #expect(Date().timeIntervalSince(overlappingStarted) < 1)

    let oversized = await frame.run(arguments: [
      "graphql", "search", String(repeating: "a", count: 257), "--limit", "1"
    ])
    #expect(oversized.exitCode == .usage)
    #expect(oversized.standardError.contains("must not exceed 256 UTF-8 bytes"))

    let result = await frame.run(arguments: [
      "--pretty", "graphql", "search", "^task$", "--kinds", "query", "--include-referenced-types", "--limit", "2"
    ])
    #expect(result.exitCode == .success)
    #expect(result.standardOutput.hasPrefix("{\n"))
    #expect(result.standardOutput.contains("\"count\": 2"))
    #expect(result.standardOutput.contains("\"referenced-by:task\""))
    #expect(await transport.requestCount == 0)
  }

  @Test("Operation reports variable errors and leaves existing commands compatible")
  func operationErrorsAndCommandRegressions() async throws {
    let transport = RecordingTransport.succeeding(
      json: WrikeFixtures.envelope(kind: "tasks", data: WrikeFixtures.task)
    )
    let frame = try makeFrame(
      transport: transport,
      files: [
        "/tmp/task.graphql": "query T($id: ID!) { task(id: $id) { id title } }",
        "/tmp/task-vars.json": "{\"id\":\"IEAAAAAAKQAB5FNY\"}",
        "/tmp/invalid-vars.json": "[]"
      ]
    )
    let missing = await frame.run(arguments: ["graphql", "operation", "task"])
    #expect(missing.exitCode == .usage)
    let malformed = await frame.run(arguments: ["graphql", "operation", "task", "--variables-file", "/tmp/invalid-vars.json"])
    #expect(malformed.exitCode == .usage)
    let missingOptionValue = await frame.run(arguments: [
      "graphql", "operation", "task", "--variables-file", "--include-referenced-types"
    ])
    #expect(missingOptionValue.exitCode == .usage)
    #expect(missingOptionValue.standardError.contains("requires a value"))

    let operation = await frame.run(arguments: [
      "--pretty", "graphql", "operation", "task", "--variables-file", "/tmp/task-vars.json", "--select", "id,title"
    ])
    #expect(operation.exitCode == .success)
    #expect(operation.standardOutput.hasPrefix("{\n"))
    #expect(operation.standardOutput.contains("\"title\": \"Prepare launch\""))

    let query = await frame.run(arguments: ["graphql", "query", "{ task(id: \"IEAAAAAAKQAB5FNY\") { id } }"])
    let queryFile = await frame.run(arguments: ["graphql", "query-file", "/tmp/task.graphql", "--variables-file", "/tmp/task-vars.json"])
    let schema = await frame.run(arguments: ["graphql", "schema"])
    let status = await frame.run(arguments: ["auth", "status"])
    #expect(query.exitCode == .success)
    #expect(queryFile.exitCode == .success)
    #expect(schema.exitCode == .success)
    #expect(status.exitCode == .success)
  }

  private func makeFrame(
    transport: RecordingTransport,
    files: [String: String] = [:]
  ) throws -> CommandFrame {
    let runtime = GraphQLRuntime(
      executor: CapabilityExecutor(
        planner: CapabilityPlanner(registry: try ReadCapabilities.registry()),
        transport: transport,
        credentials: StubCredentialProvider(),
        clock: TestClock()
      ),
      requestIDFactory: { "sdk-command-request" }
    )
    let environment = StaticEnvironmentReader()
    let auth = AuthCommands(
      resolver: CredentialResolver(environment: environment, store: InMemoryCredentialStore()),
      environment: environment,
      makeLoginFlow: { _, _ in nil }
    )
    return CommandFrame(
      role: .reader,
      runtime: runtime,
      authCommands: auth,
      readFile: { fileName in
        guard let contents = files[fileName] else {
          throw GatewayError(code: .fileOperationFailed, message: "The file at the supplied path could not be read.")
        }
        return Data(contents.utf8)
      }
    )
  }
}
