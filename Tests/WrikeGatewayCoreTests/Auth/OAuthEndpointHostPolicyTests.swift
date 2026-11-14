import Foundation
import Testing
import WrikeGatewayCore

/// Cover for the host policy the OAuth token exchange runs under.
///
/// The token endpoint lives on the login host under `/oauth2/token`, so the API
/// policy rejects it on both the host and the `/api/v4` prefix. A live
/// authorization-code exchange failed with "request host is not an approved
/// Wrike host" because the exchange ran under the API policy, which no unit
/// test caught: they all injected a transport rather than exercising the policy
/// the composition root actually wires.
@Suite("OAuth endpoint host policy")
struct OAuthEndpointHostPolicyTests {
  @Test("The OAuth policy admits the login host")
  func oauthPolicyAdmitsLoginHost() {
    #expect(WrikeHostPolicy.oauth.allows(host: WrikeHostPolicy.approvedLoginHost))
    #expect(WrikeHostPolicy.oauth.allows(host: "LOGIN.WRIKE.COM"))
  }

  @Test("The documented token endpoint passes the policy it runs under")
  func tokenEndpointPassesItsPolicy() throws {
    let url = try #require(URL(string: WrikeOAuthEndpoints.tokenURL))
    #expect(WrikeHostPolicy.oauth.allows(host: url.host))
    #expect(url.scheme == "https")
    #expect(
      !WrikeHostPolicy.production.allows(host: url.host),
      "The API policy must keep refusing the login host"
    )
  }

  @Test("The OAuth policy admits no API data-center host")
  func oauthPolicyRefusesAPIHosts() {
    for host in WrikeHostPolicy.approvedAPIHosts {
      #expect(
        !WrikeHostPolicy.oauth.allows(host: host),
        "The credential-bearing login policy must not widen to API hosts"
      )
    }
  }

  @Test("The API policy admits no login host and still requires the API prefix")
  func apiPolicyStaysNarrow() {
    #expect(!WrikeHostPolicy.production.allows(host: WrikeHostPolicy.approvedLoginHost))
    #expect(WrikeHostPolicy.production.requiresAPIPathPrefix)
    #expect(!WrikeHostPolicy.oauth.requiresAPIPathPrefix)
  }

  @Test("Both policies require HTTPS")
  func bothPoliciesRequireHTTPS() {
    #expect(WrikeHostPolicy.production.requiresHTTPS)
    #expect(WrikeHostPolicy.oauth.requiresHTTPS)
  }

  @Test("Neither policy admits an unrelated host", arguments: [
    "wrike.com.attacker.example",
    "attacker.example",
    "login.wrike.com.attacker.example",
    "localhost"
  ])
  func neitherPolicyAdmitsAnUnrelatedHost(host: String) {
    #expect(!WrikeHostPolicy.oauth.allows(host: host))
    #expect(!WrikeHostPolicy.production.allows(host: host))
  }

  @Test("The two policies cover the two different hosts the exchange touches")
  func theExchangeTouchesTwoHosts() throws {
    // The request goes to the login host and is gated by the transport's
    // policy. The response names a data-center host, which is validated
    // against the API policy. Applying one policy to both ends breaks the
    // other end: that is exactly how the live failure and its first attempted
    // fix each went wrong.
    let requestHost = try #require(URL(string: WrikeOAuthEndpoints.tokenURL)?.host)
    #expect(WrikeHostPolicy.oauth.allows(host: requestHost))

    for responseHost in WrikeHostPolicy.approvedAPIHosts {
      #expect(WrikeHostPolicy.production.allows(host: responseHost))
      #expect(!WrikeHostPolicy.oauth.allows(host: responseHost))
    }

    let transport = URLSessionWrikeTransport(hostPolicy: .oauth)
    #expect(throws: Never.self) {
      _ = try OAuthTokenExchange(transport: transport)
    }
  }
}
