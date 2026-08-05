import Foundation

/// Generates unguessable OAuth state values. Injected so callback tests are
/// deterministic without weakening the production generator.
public protocol StateGenerator: Sendable {
  func makeState() -> SecretValue
}

public struct RandomStateGenerator: StateGenerator {
  public init() {}

  public func makeState() -> SecretValue {
    var bytes = [UInt8](repeating: 0, count: 32)
    for index in bytes.indices {
      bytes[index] = UInt8.random(in: UInt8.min...UInt8.max)
    }
    return SecretValue(Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: ""))
  }
}

/// Records which side effects the flow attempted, so tests can assert that a
/// failed identity check prevents both listener binding and browser launch.
public struct OAuthFlowTrace: Sendable, Equatable {
  public var identityLoaded = false
  public var listenerStarted = false
  public var browserOpened = false

  public init() {}
}

/// Orchestrates the OAuth2 authorization-code flow.
///
/// Ordering is a security requirement, not a convenience: the callback TLS
/// identity is validated first, so a missing or invalid identity fails before
/// any listener binds or any browser opens.
public struct OAuthLoginFlow: Sendable {
  private let client: OAuthClientConfiguration
  private let identityLoader: any CallbackTLSIdentityLoader
  private let listener: any OAuthCallbackListener
  private let browser: any BrowserOpener
  private let exchange: OAuthTokenExchange
  private let stateGenerator: any StateGenerator
  private let clock: any GatewayClock
  private let timeoutSeconds: Double
  private let requestedScopes: [String]
  /// The loopback port the callback service binds for this login. Resolved from
  /// the environment by the composition root so the redirect URI can match one
  /// registered for the Wrike application.
  private let callbackPort: Int

  public init(
    client: OAuthClientConfiguration,
    identityLoader: any CallbackTLSIdentityLoader,
    listener: any OAuthCallbackListener,
    browser: any BrowserOpener,
    exchange: OAuthTokenExchange,
    stateGenerator: any StateGenerator = RandomStateGenerator(),
    clock: any GatewayClock = SystemClock(),
    timeoutSeconds: Double = 180,
    requestedScopes: [String],
    callbackPort: Int = WrikeOAuthEndpoints.defaultCallbackPort
  ) {
    self.callbackPort = callbackPort
    self.client = client
    self.identityLoader = identityLoader
    self.listener = listener
    self.browser = browser
    self.exchange = exchange
    self.stateGenerator = stateGenerator
    self.clock = clock
    self.timeoutSeconds = timeoutSeconds
    self.requestedScopes = requestedScopes
  }

  /// Runs the flow and returns the committed token state plus a trace of the
  /// side effects that were attempted.
  public func authorize() async throws -> (state: OAuthTokenState, trace: OAuthFlowTrace) {
    var trace = OAuthFlowTrace()

    // Step 1: validate the fixed callback identity before anything else.
    let identity = try identityLoader.loadIdentity(label: WrikeOAuthEndpoints.callbackIdentityLabel)
    trace.identityLoaded = true

    let state = stateGenerator.makeState()
    let redirectURI = WrikeOAuthEndpoints.redirectURI(port: callbackPort)
    let authorizationURL = Self.authorizationURL(
      client: client,
      state: state,
      scopes: requestedScopes,
      redirectURI: redirectURI
    )

    // Step 2: bind the loopback listener using the validated identity. The
    // service lives only for this login and stops when the flow returns.
    async let callbackTask = listener.awaitCallback(
      identity: identity,
      port: callbackPort,
      timeoutSeconds: timeoutSeconds
    )
    trace.listenerStarted = true

    // Step 3: open the authorization URL. It is never written to stdout,
    // stderr, or logs because it embeds the client id and the OAuth state.
    do {
      try await browser.open(authorizationURL)
      trace.browserOpened = true
    } catch {
      _ = try? await callbackTask
      throw error
    }

    let callback = try await callbackTask
    let result = try OAuthCallbackValidator.validate(
      callback,
      expectedState: state,
      expectedPort: callbackPort
    )
    let tokenState = try await exchange.exchangeAuthorizationCode(
      result.code,
      client: client,
      redirectURI: redirectURI,
      now: clock.now
    )
    return (tokenState, trace)
  }

  /// Builds the authorization URL as a `SecretValue` so it cannot be printed.
  static func authorizationURL(
    client: OAuthClientConfiguration,
    state: SecretValue,
    scopes: [String],
    redirectURI: String = WrikeOAuthEndpoints.redirectURI(
      port: WrikeOAuthEndpoints.defaultCallbackPort
    )
  ) -> SecretValue {
    var components = URLComponents(string: WrikeOAuthEndpoints.authorizationURL)
    var items = [
      URLQueryItem(name: "client_id", value: client.clientID.reveal()),
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "redirect_uri", value: redirectURI),
      URLQueryItem(name: "state", value: state.reveal())
    ]
    if !scopes.isEmpty {
      items.append(URLQueryItem(name: "scope", value: scopes.joined(separator: ",")))
    }
    components?.queryItems = items
    return SecretValue(components?.url?.absoluteString ?? WrikeOAuthEndpoints.authorizationURL)
  }
}
