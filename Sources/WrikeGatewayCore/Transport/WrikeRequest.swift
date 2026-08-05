import Foundation

public enum HTTPMethod: String, Sendable, Equatable, CaseIterable {
  case get = "GET"
  case post = "POST"
  case put = "PUT"
  case delete = "DELETE"

  /// Only GET is automatically retried. Every other method requires a reviewed
  /// idempotency guarantee that the initial contract does not provide.
  public var isAutomaticallyRetryable: Bool { self == .get }
}

public struct WrikeQueryItem: Sendable, Equatable {
  public let name: String
  public let value: String

  public init(name: String, value: String) {
    self.name = name
    self.value = value
  }
}

/// A local file selected for a streamed upload. Only a path is retained; bytes
/// are read by the transport and never held in a diagnosable value.
public struct FileUploadBody: Sendable, Equatable {
  public let path: String
  public let fileName: String
  public let contentType: String

  public init(path: String, fileName: String, contentType: String) {
    self.path = path
    self.fileName = fileName
    self.contentType = contentType
  }
}

public enum WrikeRequestBody: Sendable, Equatable {
  case none
  case json(WrikeValue)
  case form([WrikeQueryItem])
  case file(FileUploadBody)
}

/// A capability-scoped request expressed in relative terms. Public SDK and
/// GraphQL callers never supply a raw URL, method, or query parameter; the
/// capability adapter is the only producer of this value.
public struct WrikeRequest: Sendable, Equatable {
  public let capabilityID: CapabilityID
  public let method: HTTPMethod
  /// Relative to the resolved `/api/v4` base URL and always leading-slashed.
  public let path: String
  public let queryItems: [WrikeQueryItem]
  public let headers: [String: String]
  public let body: WrikeRequestBody
  public let timeout: TimeInterval

  public init(
    capabilityID: CapabilityID,
    method: HTTPMethod,
    path: String,
    queryItems: [WrikeQueryItem] = [],
    headers: [String: String] = [:],
    body: WrikeRequestBody = .none,
    timeout: TimeInterval = 60
  ) {
    self.capabilityID = capabilityID
    self.method = method
    self.path = path
    self.queryItems = queryItems
    self.headers = headers
    self.body = body
    self.timeout = timeout
  }
}

/// A request resolved against a base URL and decorated with credentials, ready
/// for a `WrikeTransport`.
///
/// The bearer token is carried as a `SecretValue` rather than a formatted
/// header so that a recording transport can assert that authorization was
/// applied without ever holding the header text.
public struct PreparedRequest: Sendable {
  public let url: URL
  public let method: HTTPMethod
  public let headers: [String: String]
  public let bearerToken: SecretValue?
  public let body: WrikeRequestBody
  public let timeout: TimeInterval
  public let capabilityID: CapabilityID
  public let requestID: String

  public init(
    url: URL,
    method: HTTPMethod,
    headers: [String: String],
    bearerToken: SecretValue?,
    body: WrikeRequestBody,
    timeout: TimeInterval,
    capabilityID: CapabilityID,
    requestID: String
  ) {
    self.url = url
    self.method = method
    self.headers = headers
    self.bearerToken = bearerToken
    self.body = body
    self.timeout = timeout
    self.capabilityID = capabilityID
    self.requestID = requestID
  }

  public var hasAuthorization: Bool { bearerToken != nil }
}

public struct WrikeResponse: Sendable, Equatable {
  public let statusCode: Int
  /// Header names are lowercased so lookups do not depend on server casing.
  public let headers: [String: String]
  public let body: Data

  public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
    self.statusCode = statusCode
    self.headers = headers.reduce(into: [:]) { result, entry in
      result[entry.key.lowercased()] = entry.value
    }
    self.body = body
  }

  public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

/// Failures raised before an HTTP status is available.
public enum TransportFailure: Error, Sendable, Equatable {
  case cancelled
  case timedOut
  case connectivity(String)
  case tls(String)
  case malformedResponse(String)
  case localIO(String)

  /// Bounded automatic retry applies only to transient network conditions and
  /// only when the request method allows it.
  public var isTransient: Bool {
    switch self {
    case .timedOut, .connectivity:
      return true
    case .cancelled, .tls, .malformedResponse, .localIO:
      return false
    }
  }

  public var safeSummary: String {
    switch self {
    case .cancelled: return "The request was cancelled."
    case .timedOut: return "The request to Wrike timed out."
    case .connectivity(let detail): return "Could not reach Wrike: \(detail)."
    case .tls(let detail): return "TLS validation failed: \(detail)."
    case .malformedResponse(let detail): return "Wrike returned an unreadable response: \(detail)."
    case .localIO(let detail): return "A local file operation failed: \(detail)."
    }
  }
}

/// The injectable transport boundary. Adapters depend on this protocol rather
/// than on `URLSession`, global state, or a singleton client.
public protocol WrikeTransport: Sendable {
  func send(_ request: PreparedRequest) async throws -> WrikeResponse
}
