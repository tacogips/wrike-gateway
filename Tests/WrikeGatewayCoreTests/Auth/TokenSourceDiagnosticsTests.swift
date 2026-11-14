import Foundation
import Testing
@testable import WrikeGatewayCore
import WrikeGatewayTestSupport

@Test func storedLoginCredentialRemainsHiddenUntilEnvironmentOverrideIsRemoved() async throws {
  let store = InMemoryCredentialStore()
  let client: [GatewayEnvironmentKey: String] = [.clientID: "test-client", .clientSecret: "test-secret"]
  let environment = StaticEnvironmentReader(client.merging([
    .accessToken: "stale-environment-token", .apiBaseURL: "https://www.wrike.com/api/v4"
  ]) { _, selected in selected })
  let resolver = CredentialResolver(environment: environment, store: store)
  let state = OAuthTokenState(
    accessToken: SecretValue("new-stored-token"), refreshToken: SecretValue("new-refresh-token"),
    expiresAt: Date().addingTimeInterval(3_600), grantedScopes: ["wsReadOnly"],
    host: "www.wrike.com", clientID: SecretValue("test-client")
  )
  try await resolver.commit(state)
  #expect(try await resolver.credential().mode == .permanentToken)
  let report = try await resolver.status().stableValue.encodedJSON(pretty: false)
  #expect(report.contains("ENVIRONMENT_TOKEN"))
  #expect(report.contains("WRIKE_GATEWAY_ACCESS_TOKEN"))
  #expect(!report.contains("stale-environment-token"))
  let selected = CredentialResolver(environment: StaticEnvironmentReader(client), store: store)
  #expect(try await selected.credential().mode == .oauth2)
  let error = GatewayError.authentication("Rejected").withCredentialSource(.permanentToken)
  #expect(error.message.contains("WRIKE_GATEWAY_ACCESS_TOKEN"))
  #expect(error.recoveryGuidance?.contains("Unset WRIKE_GATEWAY_ACCESS_TOKEN") == true)
}
