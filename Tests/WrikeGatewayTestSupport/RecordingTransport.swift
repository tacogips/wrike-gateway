import Foundation
import WrikeGatewayCore

/// An in-memory transport that records every prepared request and returns
/// queued canned responses.
///
/// It records `hasAuthorization` rather than the header text, so a test can
/// assert that a credential was applied without ever holding its value.
public actor RecordingTransport: WrikeTransport {
  /// A safe projection of a request. It deliberately has no field that can hold
  /// a token, so a snapshot of it cannot leak one.
  public struct RecordedRequest: Sendable, Equatable {
    public let method: HTTPMethod
    public let url: URL
    public let path: String
    public let queryItems: [WrikeQueryItem]
    public let headerNames: [String]
    public let hasAuthorization: Bool
    public let capabilityID: CapabilityID
    public let bodyDescription: String
    /// Recorded so a test can prove a capability asked for a file sink, and
    /// that no other capability ever does.
    public let responseSink: WrikeResponseSink

    public var query: [String: String] {
      queryItems.reduce(into: [:]) { $0[$1.name] = $1.value }
    }
  }

  public enum Outcome: Sendable {
    case response(WrikeResponse)
    case failure(TransportFailure)
  }

  private var queued: [Outcome]
  private var recorded: [RecordedRequest] = []
  /// Repeats the final outcome once the queue is drained, so a retry test does
  /// not need to enumerate every attempt.
  private let repeatsFinalOutcome: Bool

  public init(outcomes: [Outcome] = [], repeatsFinalOutcome: Bool = true) {
    self.queued = outcomes
    self.repeatsFinalOutcome = repeatsFinalOutcome
  }

  public static func succeeding(json: String, status: Int = 200, headers: [String: String] = [:]) -> RecordingTransport {
    RecordingTransport(outcomes: [
      .response(WrikeResponse(statusCode: status, headers: headers, body: Data(json.utf8)))
    ])
  }

  public func enqueue(_ outcome: Outcome) {
    queued.append(outcome)
  }

  public var requests: [RecordedRequest] { recorded }

  public var requestCount: Int { recorded.count }

  public func firstRequest() throws -> RecordedRequest {
    guard let first = recorded.first else {
      throw TestSupportError.noRequestRecorded
    }
    return first
  }

  public func send(_ request: PreparedRequest) async throws -> WrikeResponse {
    recorded.append(
      RecordedRequest(
        method: request.method,
        url: request.url,
        path: request.url.path,
        queryItems: (URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
          .map { WrikeQueryItem(name: $0.name, value: $0.value ?? "") },
        headerNames: request.headers.keys.sorted(),
        hasAuthorization: request.hasAuthorization,
        capabilityID: request.capabilityID,
        bodyDescription: Self.describe(request.body),
        responseSink: request.responseSink
      )
    )

    let outcome: Outcome
    if queued.count > 1 || !repeatsFinalOutcome {
      guard !queued.isEmpty else { throw TestSupportError.transportQueueExhausted }
      outcome = queued.removeFirst()
    } else {
      guard let last = queued.first else { throw TestSupportError.transportQueueExhausted }
      outcome = last
    }

    switch outcome {
    case .response(let response):
      // Canned responses are queued as in-memory bodies, so the sink is applied
      // here through the same core delivery the live transport uses. A test
      // therefore observes the production write rule, including the refusal to
      // overwrite and the refusal to write an error body.
      return try ResponseSinkDelivery.deliver(
        sink: request.responseSink,
        statusCode: response.statusCode,
        headers: response.headers,
        body: response.body
      )
    case .failure(let failure):
      throw failure
    }
  }

  /// Describes a body for assertions. An upload records only its file name and
  /// declared content type; bytes are never read here.
  static func describe(_ body: WrikeRequestBody) -> String {
    switch body {
    case .none:
      return "none"
    case .json(let value):
      return "json:" + value.encodedJSON(pretty: false)
    case .form(let items):
      return "form:" + items.map { "\($0.name)=\($0.value)" }.sorted().joined(separator: "&")
    case .file(let upload):
      return "file:\(upload.fileName):\(upload.contentType)"
    }
  }
}

public enum TestSupportError: Error, Equatable {
  case noRequestRecorded
  case transportQueueExhausted
  case unexpectedSuccess
}
