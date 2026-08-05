import Foundation
import WrikeGatewayCore

/// Reusable support for proving that the typed SDK path and the GraphQL path
/// select the same capability, the same adapter request, and the same error.
///
/// Every tier's test suite uses this, so parity is asserted the same way for
/// reads, writes, and deletes.
public enum ParityHarness {
  public struct Comparison: Sendable {
    public let sdkPlan: CapabilityPlan?
    public let graphQLPlan: CapabilityPlan?
    public let sdkError: GatewayError?
    public let graphQLError: GatewayError?

    /// True when both paths reached the same outcome: the same capability id
    /// and upstream request, or the same stable error code and message.
    public var isEquivalent: Bool {
      if let sdkPlan, let graphQLPlan {
        return sdkPlan.definition.id == graphQLPlan.definition.id
          && sdkPlan.request == graphQLPlan.request
      }
      if let sdkError, let graphQLError {
        return sdkError.code == graphQLError.code && sdkError.message == graphQLError.message
      }
      return false
    }

    public var summary: String {
      if let sdkPlan, let graphQLPlan {
        return "sdk=\(sdkPlan.request) graphql=\(graphQLPlan.request)"
      }
      return "sdk=\(String(describing: sdkError)) graphql=\(String(describing: graphQLError))"
    }
  }

  /// Plans the same operation through the SDK-style invocation and through a
  /// GraphQL document, then compares the two outcomes.
  public static func compare(
    planner: CapabilityPlanner,
    invocation: CapabilityInvocation,
    document: String,
    variables: [String: WrikeValue] = [:],
    grantedScopes: [String] = []
  ) throws -> Comparison {
    var sdkPlan: CapabilityPlan?
    var sdkError: GatewayError?
    do {
      sdkPlan = try planner.plan(invocation, grantedScopes: grantedScopes)
    } catch let error as GatewayError {
      sdkError = error
    }

    var graphQLPlan: CapabilityPlan?
    var graphQLError: GatewayError?
    do {
      let parsed = try GraphQLParser().parse(document)
      let field = parsed.operation.selections.first
      guard let field else {
        throw GatewayError.validation("The parity document selected no field.")
      }
      let definition = try planner.definition(
        field: field.name,
        isMutation: parsed.operation.type.isMutation
      )
      var arguments: [String: WrikeValue] = [:]
      for (name, value) in field.arguments {
        arguments[name] = try value.resolved(variables: variables, path: "\(field.name).\(name)")
      }
      try GraphQLSelectionProjection.validate(
        selections: field.selections,
        for: definition.result,
        fieldName: field.name
      )
      graphQLPlan = try planner.plan(
        CapabilityInvocation(capabilityID: definition.id, arguments: arguments),
        grantedScopes: grantedScopes
      )
    } catch let error as GatewayError {
      graphQLError = error
    }

    return Comparison(
      sdkPlan: sdkPlan,
      graphQLPlan: graphQLPlan,
      sdkError: sdkError,
      graphQLError: graphQLError
    )
  }
}

/// Canned Wrike response envelopes shared by every tier's contract tests.
public enum WrikeFixtures {
  public static func envelope(kind: String, data: String, nextPageToken: String? = nil) -> String {
    let token = nextPageToken.map { ",\"nextPageToken\":\"\($0)\"" } ?? ""
    return "{\"kind\":\"\(kind)\",\"data\":[\(data)]\(token)}"
  }

  public static let task = """
    {"id":"IEAAAAAAKQAB5FNY","accountId":"IEAAAAAA","title":"Prepare launch",\
    "status":"Active","importance":"Normal","createdDate":"2026-08-01T09:00:00Z",\
    "responsibleIds":["KUAAAAAA"],"permalink":"https://www.wrike.com/open.htm?id=1",\
    "dates":{"type":"Planned","duration":480,"start":"2026-08-01T09:00:00Z"}}
    """

  public static let folder = """
    {"id":"IEAAAAAAI4AB5FNY","accountId":"IEAAAAAA","title":"Launch",\
    "childIds":["IEAAAAAAI4AB5FNZ"],"scope":"WsFolder","project":{"authorId":"KUAAAAAA",\
    "ownerIds":["KUAAAAAA"],"status":"Green","startDate":"2026-08-01"}}
    """

  public static let contact = """
    {"id":"KUAAAAAA","firstName":"Alex","lastName":"Example","type":"Person",\
    "profiles":[{"accountId":"IEAAAAAA","email":"alex@example.test","role":"User",\
    "external":false,"admin":false,"owner":false}]}
    """

  public static let comment = """
    {"id":"IEAAAAAAIMAAAAAB","authorId":"KUAAAAAA","text":"Looks good",\
    "createdDate":"2026-08-02T10:00:00Z","taskId":"IEAAAAAAKQAB5FNY"}
    """

  public static let attachment = """
    {"id":"IEAAAAAAIYAAAAAB","authorId":"KUAAAAAA","name":"brief.pdf",\
    "createdDate":"2026-08-02T10:00:00Z","version":1,"type":"Wrike",\
    "contentType":"application/pdf","size":2048,"taskId":"IEAAAAAAKQAB5FNY"}
    """

  public static let timelog = """
    {"id":"IEAAAAAAJAAAAAAB","taskId":"IEAAAAAAKQAB5FNY","userId":"KUAAAAAA",\
    "hours":1.5,"trackedDate":"2026-08-02","comment":"Review"}
    """

  public static let webhook = """
    {"id":"IEAAAAAAJEAAAAAB","accountId":"IEAAAAAA",\
    "hookUrl":"https://example.test/hook","status":"Active","recursive":true}
    """

  public static let contactsHistory = """
    {"id":"KUAAAAAA",\
    "billRateHistory":[{"rateValue":120.0,"startDate":"2026-01-01T00:00:00Z",\
    "endDate":"2026-06-30T00:00:00Z","rateSource":"JobRole"}],\
    "costRateHistory":[{"rateValue":80.0,"startDate":"2026-01-01T00:00:00Z","rateSource":"User"}]}
    """

  public static let foldersHistory = """
    {"id":"IEAAAAAAI4AB5FNY","project":{\
    "plannedCost":[{"value":1000.0,"startDate":"2026-01-01T00:00:00Z"}],\
    "budget":[{"value":5000.0,"startDate":"2026-01-01T00:00:00Z",\
    "endDate":"2026-06-30T00:00:00Z"}]}}
    """

  public static let tasksHistory = """
    {"id":"IEAAAAAAKQAB5FNY",\
    "plannedCost":[{"value":250.0,"startDate":"2026-01-01T00:00:00Z"}],\
    "actualCost":[{"value":300.0,"startDate":"2026-02-01T00:00:00Z"}]}
    """

  public static let errorBody = "{\"error\":\"not_authorized\",\"errorDescription\":\"detail\"}"
}

/// A self-removing temporary directory for tests that must observe real file
/// creation, permissions, and refusal to overwrite.
public final class TemporaryDirectory: @unchecked Sendable {
  public let url: URL

  public init() throws {
    url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("wrike-gateway-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  /// A path inside the directory that does not exist yet.
  public func path(_ name: String) -> String {
    url.appendingPathComponent(name).path
  }

  deinit {
    try? FileManager.default.removeItem(at: url)
  }
}
