import Foundation
import Testing
import WrikeGatewayCore
import WrikeGatewayTestSupport

/// A minimal reader-shaped capability used to exercise transport behavior
/// without depending on the read module.
enum TransportTestCapabilities {
  static let widget = ModelShape(
    typeName: "Widget",
    fields: [
      ModelField("id", .identifier, required: true),
      ModelField("title", .string)
    ]
  )

  static let get = CapabilityDefinition(
    id: CapabilityID("widgets.get"),
    field: "widget",
    tier: .reader,
    operationClass: .read,
    method: .get,
    pathTemplate: "/widgets/{widgetId}",
    arguments: [ArgumentDefinition("id", .identifier, .path("widgetId"), required: true)],
    result: .single(widget),
    scopes: .workspaceRead,
    summary: "Returns one widget."
  )

  static let list = CapabilityDefinition(
    id: CapabilityID("widgets.list"),
    field: "widgets",
    tier: .reader,
    operationClass: .read,
    method: .get,
    pathTemplate: "/widgets",
    arguments: [ArgumentDefinition("page", .page, .page)],
    result: .connection(widget),
    scopes: .workspaceRead,
    maximumPageSize: 100,
    summary: "Lists widgets."
  )

  static let create = CapabilityDefinition(
    id: CapabilityID("widgets.create"),
    field: "createWidget",
    tier: .writer,
    operationClass: .create,
    method: .post,
    pathTemplate: "/widgets",
    arguments: [
      ArgumentDefinition(
        "input",
        .inputObject(InputObjectShape(
          typeName: "CreateWidgetInput",
          fields: [ArgumentDefinition("title", .string, .bodyForm("title"), required: true)]
        )),
        .container,
        required: true
      )
    ],
    result: .payload(field: "widget", widget),
    scopes: .workspaceReadWrite,
    summary: "Creates a widget."
  )

  static func executor(
    transport: RecordingTransport,
    tier: CapabilityTier = .writer,
    clock: TestClock = TestClock(),
    retryPolicy: RetryPolicy = RetryPolicy(jitterFraction: 0),
    credentials: any CredentialProvider = StubCredentialProvider()
  ) throws -> CapabilityExecutor {
    let registry = try CapabilityRegistry(tier: tier, definitions: [get, list, create])
    return CapabilityExecutor(
      planner: CapabilityPlanner(registry: registry),
      transport: transport,
      credentials: credentials,
      clock: clock,
      retryPolicy: retryPolicy,
      requestIDFactory: { "fixed-request-id" }
    )
  }

  static func invocation(_ id: String = "IEAAAAAAKQAB5FNY") -> CapabilityInvocation {
    CapabilityInvocation(capabilityID: get.id, arguments: ["id": .string(id)])
  }
}

@Suite("Transport request mapping")
struct TransportRequestMappingTests {
  @Test("A read request maps to its exact method, path, and base URL")
  func mapsRequest() async throws {
    let transport = RecordingTransport.succeeding(
      json: WrikeFixtures.envelope(kind: "widgets", data: "{\"id\":\"W1\",\"title\":\"One\"}")
    )
    let executor = try TransportTestCapabilities.executor(transport: transport)
    _ = try await executor.execute(TransportTestCapabilities.invocation("W1"))

    let recorded = try await transport.firstRequest()
    #expect(recorded.method == .get)
    #expect(recorded.path == "/api/v4/widgets/W1")
    #expect(recorded.capabilityID == CapabilityID("widgets.get"))
    #expect(recorded.url.host == "www.wrike.com")
  }

  @Test("The authorization credential is applied but never exposed as a header value")
  func appliesAuthorization() async throws {
    let transport = RecordingTransport.succeeding(
      json: WrikeFixtures.envelope(kind: "widgets", data: "{\"id\":\"W1\"}")
    )
    let executor = try TransportTestCapabilities.executor(transport: transport)
    _ = try await executor.execute(TransportTestCapabilities.invocation("W1"))

    let recorded = try await transport.firstRequest()
    #expect(recorded.hasAuthorization)
    // The recorded request has no field capable of holding the header text.
    #expect(!recorded.headerNames.contains("Authorization"))
  }

  @Test("Pagination arguments become explicit query parameters")
  func mapsPagination() async throws {
    let transport = RecordingTransport.succeeding(
      json: WrikeFixtures.envelope(
        kind: "widgets",
        data: "{\"id\":\"W1\"}",
        nextPageToken: "opaque-token"
      )
    )
    let executor = try TransportTestCapabilities.executor(transport: transport)
    let result = try await executor.execute(CapabilityInvocation(
      capabilityID: TransportTestCapabilities.list.id,
      arguments: ["page": .object(["pageSize": .int(50)])]
    ))

    let recorded = try await transport.firstRequest()
    #expect(recorded.query["pageSize"] == "50")
    #expect(result["pageInfo"]?["nextPageToken"]?.stringValue == "opaque-token")
    #expect(result["pageInfo"]?["resultCount"]?.intValue == 1)
  }

  @Test("A page size above the capability maximum is rejected, not clamped")
  func rejectsOversizedPage() async throws {
    let transport = RecordingTransport.succeeding(json: "{}")
    let executor = try TransportTestCapabilities.executor(transport: transport)
    await #expect(throws: GatewayError.self) {
      _ = try await executor.execute(CapabilityInvocation(
        capabilityID: TransportTestCapabilities.list.id,
        arguments: ["page": .object(["pageSize": .int(5000)])]
      ))
    }
    #expect(await transport.requestCount == 0)
  }
}

@Suite("Transport failure classification")
struct TransportFailureClassificationTests {
  static let statusCases: [(Int, GatewayErrorCode)] = [
    (400, .validationError),
    (401, .authenticationFailed),
    (403, .authorizationFailed),
    (404, .notFound),
    (429, .rateLimited),
    (500, .upstreamUnavailable)
  ]

  @Test("Each upstream status maps to its stable error code", arguments: statusCases)
  func mapsStatus(status: Int, expected: GatewayErrorCode) async throws {
    let transport = RecordingTransport(outcomes: [
      .response(WrikeResponse(statusCode: status, body: Data(WrikeFixtures.errorBody.utf8)))
    ])
    // Retry is disabled so a retryable status still surfaces its mapped code.
    let executor = try TransportTestCapabilities.executor(
      transport: transport,
      retryPolicy: .disabled
    )

    do {
      _ = try await executor.execute(TransportTestCapabilities.invocation())
      Issue.record("Expected status \(status) to fail")
    } catch let error as GatewayError {
      #expect(error.code == expected)
      #expect(error.httpStatus == status)
      #expect(error.requestID == "fixed-request-id")
      // Only the documented upstream error code is forwarded, never the
      // errorDescription text.
      #expect(error.message.contains("not_authorized"))
      #expect(!error.message.contains("detail"))
    }
  }

  @Test("A local connectivity failure is TRANSPORT_FAILED, distinct from UPSTREAM_UNAVAILABLE")
  func transportFailedIsDistinct() async throws {
    let transport = RecordingTransport(outcomes: [.failure(.connectivity("offline"))])
    let executor = try TransportTestCapabilities.executor(
      transport: transport,
      retryPolicy: .disabled
    )

    do {
      _ = try await executor.execute(TransportTestCapabilities.invocation())
      Issue.record("Expected a transport failure")
    } catch let error as GatewayError {
      #expect(error.code == .transportFailed)
      #expect(error.code != .upstreamUnavailable)
      #expect(error.httpStatus == nil)
      #expect(error.exitCode == .transientUpstream)
    }
  }

  @Test("A malformed success payload is UPSTREAM_RESPONSE_INVALID")
  func malformedPayload() async throws {
    let transport = RecordingTransport.succeeding(json: "{\"kind\":\"widgets\"}")
    let executor = try TransportTestCapabilities.executor(transport: transport)

    do {
      _ = try await executor.execute(TransportTestCapabilities.invocation())
      Issue.record("Expected a decoding failure")
    } catch let error as GatewayError {
      #expect(error.code == .upstreamResponseInvalid)
    }
  }

  @Test("A field of the wrong upstream type fails instead of silently emptying")
  func wrongFieldType() async throws {
    let transport = RecordingTransport.succeeding(
      json: WrikeFixtures.envelope(kind: "widgets", data: "{\"id\":\"W1\",\"title\":42}")
    )
    let executor = try TransportTestCapabilities.executor(transport: transport)

    do {
      _ = try await executor.execute(TransportTestCapabilities.invocation("W1"))
      Issue.record("Expected a projection failure")
    } catch let error as GatewayError {
      #expect(error.code == .upstreamResponseInvalid)
      #expect(error.message.contains("Widget.title"))
    }
  }

  @Test("An empty single-entity result is NOT_FOUND")
  func emptySingleResult() async throws {
    let transport = RecordingTransport.succeeding(json: "{\"kind\":\"widgets\",\"data\":[]}")
    let executor = try TransportTestCapabilities.executor(transport: transport)

    do {
      _ = try await executor.execute(TransportTestCapabilities.invocation())
      Issue.record("Expected NOT_FOUND")
    } catch let error as GatewayError {
      #expect(error.code == .notFound)
    }
  }
}

@Suite("Retry policy")
struct RetryPolicyTests {
  @Test("A GET retries a 500 within its bound and then succeeds")
  func retriesGet() async throws {
    let transport = RecordingTransport(
      outcomes: [
        .response(WrikeResponse(statusCode: 500, body: Data("{}".utf8))),
        .response(WrikeResponse(
          statusCode: 200,
          body: Data(WrikeFixtures.envelope(kind: "widgets", data: "{\"id\":\"W1\"}").utf8)
        ))
      ],
      repeatsFinalOutcome: false
    )
    let clock = TestClock()
    let executor = try TransportTestCapabilities.executor(transport: transport, clock: clock)

    let result = try await executor.execute(TransportTestCapabilities.invocation("W1"))
    #expect(result["id"]?.stringValue == "W1")
    #expect(await transport.requestCount == 2)
    #expect(clock.recordedSleeps.count == 1)
  }

  @Test("A GET honours Retry-After for a 429")
  func honoursRetryAfter() async throws {
    let transport = RecordingTransport(
      outcomes: [
        .response(WrikeResponse(
          statusCode: 429,
          headers: ["Retry-After": "3"],
          body: Data("{}".utf8)
        )),
        .response(WrikeResponse(
          statusCode: 200,
          body: Data(WrikeFixtures.envelope(kind: "widgets", data: "{\"id\":\"W1\"}").utf8)
        ))
      ],
      repeatsFinalOutcome: false
    )
    let clock = TestClock()
    let executor = try TransportTestCapabilities.executor(transport: transport, clock: clock)

    _ = try await executor.execute(TransportTestCapabilities.invocation("W1"))
    #expect(clock.recordedSleeps == [3])
  }

  @Test("Retry is bounded by the attempt limit")
  func boundedRetry() async throws {
    let transport = RecordingTransport(outcomes: [
      .response(WrikeResponse(statusCode: 500, body: Data("{}".utf8)))
    ])
    let clock = TestClock()
    let executor = try TransportTestCapabilities.executor(
      transport: transport,
      clock: clock,
      retryPolicy: RetryPolicy(maximumAttempts: 3, jitterFraction: 0)
    )

    await #expect(throws: GatewayError.self) {
      _ = try await executor.execute(TransportTestCapabilities.invocation())
    }
    #expect(await transport.requestCount == 3)
  }

  /// A refresh replaces a credential the upstream refused; it is not one of the
  /// attempts budgeted for transient upstream conditions. Charging it to the
  /// retry budget silently shortens every retry sequence that follows a token
  /// expiry, which is the ordinary case for a long-lived OAuth session.
  @Test("A credential refresh does not spend one of the budgeted retry attempts")
  func refreshDoesNotConsumeARetry() async throws {
    let success = WrikeResponse(
      statusCode: 200,
      body: Data(WrikeFixtures.envelope(kind: "widgets", data: "{\"id\":\"W1\"}").utf8)
    )
    let transport = RecordingTransport(
      outcomes: [
        .response(WrikeResponse(statusCode: 401, body: Data(WrikeFixtures.errorBody.utf8))),
        .response(WrikeResponse(statusCode: 500, body: Data("{}".utf8))),
        .response(WrikeResponse(statusCode: 500, body: Data("{}".utf8))),
        .response(success)
      ],
      repeatsFinalOutcome: false
    )
    let refreshed = ResolvedCredential(
      mode: .oauth2,
      token: SecretValue("fake-refreshed"),
      // A fixed valid fixture base URL.
      // swiftlint:disable:next force_unwrapping
      baseURL: URL(string: "https://www.wrike.com/api/v4")!,
      grantedScopes: [],
      expiresAt: nil
    )
    let clock = TestClock()
    let executor = try TransportTestCapabilities.executor(
      transport: transport,
      clock: clock,
      retryPolicy: RetryPolicy(maximumAttempts: 3, jitterFraction: 0),
      credentials: StubCredentialProvider(refreshed: refreshed)
    )

    let result = try await executor.execute(TransportTestCapabilities.invocation("W1"))
    #expect(result["id"]?.stringValue == "W1")
    #expect(
      await transport.requestCount == 4,
      "One refused attempt, one refreshed attempt, and the two retries the policy budgets"
    )
    #expect(clock.recordedSleeps.count == 2, "Only the two 500 responses are backed off")
  }

  @Test("A mutation never retries and reports an unknown outcome")
  func mutationsDoNotRetry() async throws {
    let transport = RecordingTransport(outcomes: [.failure(.timedOut)])
    let executor = try TransportTestCapabilities.executor(transport: transport)

    do {
      _ = try await executor.execute(CapabilityInvocation(
        capabilityID: TransportTestCapabilities.create.id,
        arguments: ["input": .object(["title": .string("One")])]
      ))
      Issue.record("Expected the mutation to fail")
    } catch let error as GatewayError {
      #expect(error.code == .transportFailed)
      #expect(error.outcomeUnknown)
      #expect(error.recoveryGuidance?.contains("not automatically retried") == true)
    }
    #expect(await transport.requestCount == 1)
  }

  @Test("A mutation that meets a 500 does not retry and is outcome-unknown")
  func mutationServerErrorIsUnknown() async throws {
    let transport = RecordingTransport(outcomes: [
      .response(WrikeResponse(statusCode: 500, body: Data("{}".utf8)))
    ])
    let executor = try TransportTestCapabilities.executor(transport: transport)

    do {
      _ = try await executor.execute(CapabilityInvocation(
        capabilityID: TransportTestCapabilities.create.id,
        arguments: ["input": .object(["title": .string("One")])]
      ))
      Issue.record("Expected the mutation to fail")
    } catch let error as GatewayError {
      #expect(error.code == .upstreamUnavailable)
      #expect(error.outcomeUnknown)
    }
    #expect(await transport.requestCount == 1)
  }
}
