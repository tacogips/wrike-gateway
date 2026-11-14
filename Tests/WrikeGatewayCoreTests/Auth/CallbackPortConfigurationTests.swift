import Foundation
import Testing
import WrikeGatewayCore
import WrikeGatewayTestSupport

/// Cover for the configurable OAuth callback port.
///
/// The redirect URI has to match one registered for the Wrike application, and
/// the registered port differs per deployment, so the port is configurable
/// while the scheme, host, and path stay fixed. A login binds the callback
/// service on that port for the duration of one authorization and nothing is
/// left listening afterwards.
@Suite("OAuth callback port configuration")
struct CallbackPortConfigurationTests {
  private func environment(_ port: String?) -> StaticEnvironmentReader {
    var values: [GatewayEnvironmentKey: String] = [:]
    if let port { values[.oauthCallbackPort] = port }
    return StaticEnvironmentReader(values)
  }

  @Test("An unset port falls back to the documented default")
  func unsetPortUsesDefault() throws {
    let port = try WrikeOAuthEndpoints.resolveCallbackPort(from: environment(nil))
    #expect(port == WrikeOAuthEndpoints.defaultCallbackPort)
    #expect(port == 8765)
  }

  @Test("An empty or blank port falls back rather than failing")
  func blankPortUsesDefault() throws {
    for raw in ["", "   "] {
      let port = try WrikeOAuthEndpoints.resolveCallbackPort(from: environment(raw))
      #expect(port == WrikeOAuthEndpoints.defaultCallbackPort)
    }
  }

  @Test("A configured port is honoured", arguments: [1, 1024, 8765, 49152, 65535])
  func configuredPortIsHonoured(port: Int) throws {
    let resolved = try WrikeOAuthEndpoints.resolveCallbackPort(from: environment("\(port)"))
    #expect(resolved == port)
  }

  @Test("Surrounding whitespace is tolerated")
  func whitespaceIsTrimmed() throws {
    #expect(try WrikeOAuthEndpoints.resolveCallbackPort(from: environment(" 9000 ")) == 9000)
  }

  @Test(
    "An invalid port fails locally rather than silently reverting to the default",
    arguments: ["0", "-1", "65536", "99999", "eight", "80.5", "8765abc", "0x22"]
  )
  func invalidPortFails(raw: String) {
    #expect(throws: GatewayError.self) {
      _ = try WrikeOAuthEndpoints.resolveCallbackPort(from: environment(raw))
    }
  }

  @Test("The failure names the variable and the default without leaking anything else")
  func failureGuidanceIsUseful() {
    do {
      _ = try WrikeOAuthEndpoints.resolveCallbackPort(from: environment("not-a-port"))
      Issue.record("Expected an invalid port to be rejected")
    } catch let error as GatewayError {
      let combined = error.message + (error.recoveryGuidance ?? "")
      #expect(combined.contains(GatewayEnvironmentKey.oauthCallbackPort.rawValue))
      #expect(combined.contains("8765"))
      #expect(!combined.contains("not-a-port"), "The rejected value is not echoed back")
    } catch {
      Issue.record("Unexpected error type")
    }
  }

  @Test("Only the port varies; the scheme, host, and path stay fixed")
  func onlyThePortVaries() throws {
    for port in [8765, 3000, 49152] {
      let uri = WrikeOAuthEndpoints.redirectURI(port: port)
      #expect(uri.hasPrefix("http://localhost:"))
      #expect(uri.hasSuffix("/callback"))
      let components = try #require(WrikeOAuthEndpoints.components(ofRedirectURI: uri))
      #expect(components.host == "localhost")
      #expect(components.path == "/callback")
      #expect(components.port == port)
    }
  }
}
