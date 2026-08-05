import Foundation
import Testing
import WrikeGatewayAdmin
import WrikeGatewayCore
import WrikeGatewayRead
import WrikeGatewayTestSupport
import WrikeGatewayWrite

private enum E2ERuntimeFactory {
  static func definitions(for tier: CapabilityTier) -> [CapabilityDefinition] {
    switch tier {
    case .reader: ReadCapabilities.all
    case .writer: WriteCapabilities.all
    case .admin: AdminCapabilities.all
    }
  }

  static func loopback(tier: CapabilityTier, server: LoopbackHTTPServer) throws -> GraphQLRuntime {
    GraphQLRuntime(
      executor: CapabilityExecutor(
        planner: CapabilityPlanner(
          registry: try CapabilityRegistry(tier: tier, definitions: definitions(for: tier)),
          coercer: ArgumentCoercer(fileAccess: SystemFileAccess())
        ),
        transport: URLSessionWrikeTransport(hostPolicy: server.hostPolicy),
        credentials: StubCredentialProvider(baseURL: server.baseURL.absoluteString),
        clock: TestClock(),
        retryPolicy: RetryPolicy(jitterFraction: 0)
      ),
      requestIDFactory: { "e2e-replay-request-id" }
    )
  }

  static func live(tier: CapabilityTier) throws -> GraphQLRuntime {
    let environment = ProcessEnvironmentReader()
    let resolver = CredentialResolver(
      environment: environment,
      store: KinkoCredentialStore(),
      clock: SystemClock()
    )
    return GraphQLRuntime(
      executor: CapabilityExecutor(
        planner: CapabilityPlanner(
          registry: try CapabilityRegistry(tier: tier, definitions: definitions(for: tier)),
          coercer: ArgumentCoercer(fileAccess: SystemFileAccess())
        ),
        transport: URLSessionWrikeTransport(),
        credentials: resolver,
        clock: SystemClock()
      )
    )
  }
}

private enum E2ERunnerSupport {
  static func variables(_ values: [String: String]) -> [String: WrikeValue] {
    values.mapValues(WrikeValue.string)
  }

  static func value(in root: WrikeValue?, at path: [String]) -> WrikeValue? {
    var current = root
    for component in path {
      guard let value = current else { return nil }
      if let index = Int(component) {
        guard let items = value.arrayValue, items.indices.contains(index) else { return nil }
        current = items[index]
      } else {
        current = value[component]
      }
    }
    return current
  }

  static func assertExpectation(_ expectation: E2EScenario.Expectation, response: GraphQLResponse) {
    switch expectation {
    case .succeeds(let field):
      #expect(response.errors.isEmpty, "Unexpected errors for \(field): \(response.errors)")
      #expect(response.data?[field] != nil, "Missing field \(field)")
    case .succeedsWithPageInfo(let field):
      #expect(response.errors.isEmpty, "Unexpected errors for \(field): \(response.errors)")
      #expect(response.data?[field]?["pageInfo"]?.objectValue != nil, "Missing pageInfo for \(field)")
    case .fails(let code):
      #expect(response.errors.first?.code == code, "Expected \(code), received \(response.errors)")
    }
  }

  static func captures(
    _ declarations: [E2ECapture],
    from response: GraphQLResponse,
    into captured: inout [String: String]
  ) {
    for declaration in declarations {
      if let value = value(in: response.data, at: declaration.path)?.stringValue {
        captured[declaration.key] = value
      }
    }
  }

  static func liveVariables(
    for scenario: E2EScenario,
    captured: [String: String]
  ) -> [String: WrikeValue]? {
    var values = scenario.variables
    for (variable, captureKey) in scenario.liveVariableKeys {
      guard let capturedValue = captured[captureKey] else { return nil }
      values[variable] = capturedValue
    }
    return variables(values)
  }

  static func isAuthorizationBlock(_ response: GraphQLResponse) -> Bool {
    !response.errors.isEmpty && response.errors.allSatisfy { $0.code == .authorizationFailed }
  }

  static func lifecycleProblems(_ lifecycle: E2ELifecycle) -> [String] {
    let createdKeys = lifecycle.steps.compactMap { step in
      step.isCleanup ? nil : step.captures?.key
    }
    let cleanupKeys = lifecycle.steps.filter(\.isCleanup).flatMap { step in
      E2ELifecycle.unresolvedPlaceholders(in: step.document)
    }
    var problems: [String] = []
    if Set(createdKeys) != Set(cleanupKeys) {
      problems.append("created and cleanup identifier sets differ")
    }
    if Set(createdKeys).count != createdKeys.count {
      problems.append("a created identifier key is duplicated")
    }
    if lifecycle.steps.last?.field != "deleteFolder" {
      problems.append("the container is not the final cleanup step")
    }
    return problems
  }
}

@Suite("E2E scenario replay", .serialized)
struct E2EScenarioReplayTests {
  @Test("Every replayable catalog scenario runs through the loopback server")
  func replaysCatalog() async throws {
    for scenario in E2EScenarioCatalog.allScenarios where scenario.isReplayable {
      let server = try LoopbackHTTPServer(
        responses: scenario.replayResponses.map { .init(body: $0) }
      )
      try await server.start()
      let runtime = try E2ERuntimeFactory.loopback(tier: scenario.tier, server: server)
      let response = await runtime.execute(
        document: scenario.document,
        variables: E2ERunnerSupport.variables(scenario.variables)
      )
      server.stop()

      E2ERunnerSupport.assertExpectation(scenario.expectation, response: response)
      #expect(
        server.observedRequests.count == scenario.replayResponses.count,
        "\(scenario.name) made an unexpected number of requests"
      )
    }
  }

  @Test("The replay lifecycle captures, interpolates, and cleans every created id")
  func replaysLifecycle() async throws {
    let directory = try TemporaryDirectory()
    let uploadPath = directory.path("verification.txt")
    try Data("sanitized verification attachment".utf8).write(to: URL(fileURLWithPath: uploadPath))
    var captured = [
      "rootFolderId": "IEAAAAAAI7777777",
      "uploadFilePath": uploadPath
    ]
    let lifecycle = E2EScenarioCatalog.lifecycle
    let server = try LoopbackHTTPServer(
      responses: lifecycle.steps.map { .init(body: $0.replayResponse) }
    )
    try await server.start()
    defer { server.stop() }

    for step in lifecycle.steps {
      let document = E2ELifecycle.interpolate(step.document, with: captured)
      #expect(E2ELifecycle.unresolvedPlaceholders(in: document).isEmpty, "\(step.name)")
      let runtime = try E2ERuntimeFactory.loopback(tier: step.tier, server: server)
      let response = await runtime.execute(document: document)

      #expect(response.errors.isEmpty, "\(step.name): \(response.errors)")
      let result = response.data?[step.field]
      #expect(result != nil, "\(step.name) did not return \(step.field)")
      if let capture = step.captures,
         let value = E2ERunnerSupport.value(in: result, at: capture.path)?.stringValue {
        captured[capture.key] = value
      }
    }

    #expect(E2ERunnerSupport.lifecycleProblems(lifecycle).isEmpty)
    #expect(server.observedRequests.count == lifecycle.steps.count)
  }

  @Test("The catalog covers all twelve areas and declares resolvable live variables")
  func catalogInventory() {
    #expect(Set(E2EScenarioCatalog.readScenarios.map(\.area)) == Set(E2EScenarioCatalog.requiredAreas))
    var availableCaptures = Set<String>()
    for scenario in E2EScenarioCatalog.readScenarios {
      #expect(
        Set(scenario.liveVariableKeys.values).isSubset(of: availableCaptures),
        "\(scenario.name) references a capture that is not declared earlier"
      )
      availableCaptures.formUnion(scenario.captures.map(\.key))
    }
  }
}

private enum LiveE2EPrecondition {
  static let isSatisfied: Bool = {
    let environment = ProcessInfo.processInfo.environment
    guard environment["WRIKE_GATEWAY_LIVE_E2E"] == "1" else { return false }
    for name in ["WRIKE_GATEWAY_ACCESS_TOKEN", "WRIKE_GATEWAY_API_BASE_URL"] {
      guard let value = environment[name], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        return false
      }
    }
    return true
  }()
}

private struct LiveE2ERuntimes {
  let reader: GraphQLRuntime
  let writer: GraphQLRuntime
  let admin: GraphQLRuntime

  init() throws {
    reader = try E2ERuntimeFactory.live(tier: .reader)
    writer = try E2ERuntimeFactory.live(tier: .writer)
    admin = try E2ERuntimeFactory.live(tier: .admin)
  }

  func runtime(for tier: CapabilityTier) -> GraphQLRuntime {
    switch tier {
    case .reader: reader
    case .writer: writer
    case .admin: admin
    }
  }
}

@Suite(
  "Live E2E scenarios",
  .serialized,
  .enabled(if: LiveE2EPrecondition.isSatisfied)
)
struct LiveE2EScenarioTests {
  @Test("The live account executes the shared read and boundary catalog")
  func readsAndBoundaries() async throws {
    var captured: [String: String] = [:]
    for scenario in E2EScenarioCatalog.allScenarios {
      guard scenario.liveOnlyReason == nil,
            let variables = E2ERunnerSupport.liveVariables(for: scenario, captured: captured)
      else {
        continue
      }
      let runtime = try E2ERuntimeFactory.live(tier: scenario.tier)
      let response = await runtime.execute(document: scenario.document, variables: variables)

      if E2ERunnerSupport.isAuthorizationBlock(response) {
        continue
      }
      E2ERunnerSupport.assertExpectation(scenario.expectation, response: response)
      E2ERunnerSupport.captures(scenario.captures, from: response, into: &captured)
    }
  }

  @Test("The live mutation lifecycle stays inside and removes its dedicated container")
  func mutationLifecycle() async throws {
    // Every operation that can throw is prepared before the first remote
    // mutation. Once the container exists, the function always reaches the
    // cleanup loop even when a live response is an error.
    let lifecycle = E2EScenarioCatalog.lifecycle
    let lifecycleProblems = E2ERunnerSupport.lifecycleProblems(lifecycle)
    guard lifecycleProblems.isEmpty else {
      Issue.record("Unsafe live lifecycle: \(lifecycleProblems.joined(separator: "; "))")
      return
    }
    let runtimes = try LiveE2ERuntimes()
    let root = await liveRootFolderID(runtime: runtimes.reader)
    guard let root else { return }

    let directory = try TemporaryDirectory()
    let uploadPath = directory.path("verification.txt")
    try Data("wrike-gateway live verification".utf8).write(to: URL(fileURLWithPath: uploadPath))
    var captured = ["rootFolderId": root, "uploadFilePath": uploadPath]
    var createdIDs = Set<String>()
    for step in lifecycle.steps where !step.isCleanup {
      let document = E2ELifecycle.interpolate(step.document, with: captured)
      guard E2ELifecycle.unresolvedPlaceholders(in: document).isEmpty else { continue }
      let runtime = runtimes.runtime(for: step.tier)
      let response = await runtime.execute(document: document)
      if E2ERunnerSupport.isAuthorizationBlock(response) { continue }
      if !response.errors.isEmpty {
        Issue.record("\(step.name) failed: \(response.errors)")
        continue
      }
      guard let result = response.data?[step.field] else {
        Issue.record("\(step.name) returned no \(step.field)")
        continue
      }
      if let capture = step.captures {
        guard let value = E2ERunnerSupport.value(in: result, at: capture.path)?.stringValue else {
          Issue.record("\(step.name) returned no identifier at \(capture.path.joined(separator: "."))")
          continue
        }
        captured[capture.key] = value
        createdIDs.insert(value)
      }
      verifyCreationContainment(step: step, result: result, captured: captured)
    }

    for step in lifecycle.steps where step.isCleanup {
      let placeholderKeys = E2ELifecycle.unresolvedPlaceholders(in: step.document)
      guard placeholderKeys.count == 1,
            let identifier = captured[placeholderKeys[0]]
      else {
        continue
      }
      guard createdIDs.contains(identifier) else {
        Issue.record("\(step.name) targeted an id not created by this lifecycle")
        continue
      }
      guard await verifyOwnership(
        key: placeholderKeys[0],
        identifier: identifier,
        captured: captured,
        runtime: runtimes.reader
      ) else {
        Issue.record(
          "\(step.name) could not verify containment for created id \(identifier); delete was not sent"
        )
        continue
      }

      let document = E2ELifecycle.interpolate(step.document, with: captured)
      let runtime = runtimes.runtime(for: step.tier)
      let response = await runtime.execute(document: document)
      if !response.errors.isEmpty {
        Issue.record("\(step.name) failed for created id \(identifier): \(response.errors)")
        continue
      }
      if response.data?[step.field]?["deletedId"]?.stringValue != identifier {
        Issue.record("\(step.name) did not confirm created id \(identifier)")
      }
    }
  }

  private func liveRootFolderID(runtime: GraphQLRuntime) async -> String? {
    guard let scenario = E2EScenarioCatalog.readScenarios.first(where: { $0.name == "account" })
    else {
      Issue.record("The catalog has no account scenario")
      return nil
    }
    let response = await runtime.execute(document: scenario.document)
    if E2ERunnerSupport.isAuthorizationBlock(response) { return nil }
    #expect(response.errors.isEmpty)
    return E2ERunnerSupport.value(in: response.data, at: ["account", "rootFolderId"])?.stringValue
  }

  private func verifyCreationContainment(
    step: E2ELifecycle.Step,
    result: WrikeValue,
    captured: [String: String]
  ) {
    switch step.captures?.key {
    case "containerId":
      #expect(result["folder"]?["parentIds"]?.arrayValue?.contains(.string(captured["rootFolderId"] ?? "")) == true)
    case "taskId":
      #expect(result["task"]?["parentIds"]?.arrayValue?.contains(.string(captured["containerId"] ?? "")) == true)
    case "commentId":
      #expect(result["comment"]?["taskId"]?.stringValue == captured["taskId"])
    case "timelogId":
      #expect(result["timelog"]?["taskId"]?.stringValue == captured["taskId"])
    case "attachmentId":
      #expect(result["attachment"]?["taskId"]?.stringValue == captured["taskId"])
    default:
      break
    }
  }

  private func verifyOwnership(
    key: String,
    identifier: String,
    captured: [String: String],
    runtime: GraphQLRuntime
  ) async -> Bool {
    let document: String
    let path: [String]
    let expected: String
    switch key {
    case "containerId":
      document = "{ folder(id: \"\(identifier)\") { id parentIds } }"
      path = ["folder", "parentIds"]
      expected = captured["rootFolderId"] ?? ""
    case "taskId":
      document = "{ task(id: \"\(identifier)\") { id parentIds } }"
      path = ["task", "parentIds"]
      expected = captured["containerId"] ?? ""
    case "commentId":
      document = "{ comment(id: \"\(identifier)\") { id taskId } }"
      path = ["comment", "taskId"]
      expected = captured["taskId"] ?? ""
    case "timelogId":
      document = "{ timelog(id: \"\(identifier)\") { id taskId } }"
      path = ["timelog", "taskId"]
      expected = captured["taskId"] ?? ""
    case "attachmentId":
      document = "{ attachment(id: \"\(identifier)\") { id taskId } }"
      path = ["attachment", "taskId"]
      expected = captured["taskId"] ?? ""
    default:
      return false
    }

    let response = await runtime.execute(document: document)
    guard response.errors.isEmpty, let value = E2ERunnerSupport.value(in: response.data, at: path)
    else {
      return false
    }
    if let identifiers = value.arrayValue {
      return identifiers.contains(.string(expected))
    }
    return value.stringValue == expected
  }
}
