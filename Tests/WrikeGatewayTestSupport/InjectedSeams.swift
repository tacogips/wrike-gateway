import Foundation
import WrikeGatewayCore

/// A deterministic clock. Sleeps advance the clock instead of waiting, so retry
/// and expiry tests are exact and fast.
public final class TestClock: GatewayClock, @unchecked Sendable {
  private let lock = NSLock()
  private var current: Date
  private var sleeps: [Double] = []

  public init(now: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
    self.current = now
  }

  public var now: Date {
    lock.lock()
    defer { lock.unlock() }
    return current
  }

  public func sleep(seconds: Double) async throws {
    record(sleep: seconds)
  }

  private func record(sleep seconds: Double) {
    lock.lock()
    sleeps.append(seconds)
    current = current.addingTimeInterval(seconds)
    lock.unlock()
  }

  public func advance(by seconds: Double) {
    lock.lock()
    current = current.addingTimeInterval(seconds)
    lock.unlock()
  }

  public var recordedSleeps: [Double] {
    lock.lock()
    defer { lock.unlock() }
    return sleeps
  }
}

/// A fixed credential, used where credential resolution is not under test.
public struct StubCredentialProvider: CredentialProvider {
  private let credential: ResolvedCredential
  private let refreshed: ResolvedCredential?

  public init(
    token: String = "fake-access-token-for-tests",
    baseURL: String = "https://www.wrike.com/api/v4",
    grantedScopes: [String] = [],
    refreshed: ResolvedCredential? = nil
  ) {
    // A test fixture URL is validated the same way production input is.
    // swiftlint:disable:next force_unwrapping
    let url = URL(string: baseURL)!
    self.credential = ResolvedCredential(
      mode: .permanentToken,
      token: SecretValue(token),
      baseURL: url,
      grantedScopes: grantedScopes,
      expiresAt: nil
    )
    self.refreshed = refreshed
  }

  public func credential() async throws -> ResolvedCredential { credential }

  public func refreshedCredential(after stale: ResolvedCredential) async throws -> ResolvedCredential? {
    refreshed
  }
}

/// Replays a canned OAuth callback, recording that it was reached at all.
public struct StubCallbackListener: OAuthCallbackListener {
  public enum Behavior: Sendable {
    case callback(OAuthCallbackRequest)
    case timeout
  }

  private let behavior: Behavior
  public let started: Counter
  /// The port the flow asked the listener to bind, so a test can prove the
  /// configured port reached the service rather than only the redirect URI.
  public let boundPorts: PortRecorder

  public init(
    _ behavior: Behavior,
    started: Counter = Counter(),
    boundPorts: PortRecorder = PortRecorder()
  ) {
    self.behavior = behavior
    self.started = started
    self.boundPorts = boundPorts
  }

  public func awaitCallback(
    port: Int,
    timeoutSeconds: Double
  ) async throws -> OAuthCallbackRequest {
    started.increment()
    boundPorts.record(port)
    switch behavior {
    case .callback(let request):
      return request
    case .timeout:
      throw GatewayError.authentication(
        "The OAuth callback did not arrive before the timeout elapsed."
      )
    }
  }
}

/// Records browser launches without opening anything.
public struct StubBrowserOpener: BrowserOpener {
  public let opened: Counter
  public let shouldFail: Bool
  private let capture: SecretCapture

  public init(opened: Counter = Counter(), shouldFail: Bool = false, capture: SecretCapture = SecretCapture()) {
    self.opened = opened
    self.shouldFail = shouldFail
    self.capture = capture
  }

  public func open(_ authorizationURL: SecretValue) async throws {
    opened.increment()
    capture.record(authorizationURL)
    if shouldFail {
      throw GatewayError.authentication("The system browser could not be opened for authorization.")
    }
  }

  /// The authorization URL as the opener received it. Only a test may reveal it.
  public func capturedAuthorizationURL() -> String? { capture.revealed() }
}

/// Thread-safe call counter for asserting that a side effect did not happen.
/// Records the ports a listener was asked to bind.
public final class PortRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [Int] = []

  public init() {}

  public func record(_ port: Int) {
    lock.lock()
    values.append(port)
    lock.unlock()
  }

  public var ports: [Int] {
    lock.lock()
    defer { lock.unlock() }
    return values
  }
}

public final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  public init() {}

  public func increment() {
    lock.lock()
    value += 1
    lock.unlock()
  }

  public var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

/// Captures a `SecretValue` so a test can assert on the value the production
/// code passed along, without that value ever being printed by production code.
public final class SecretCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: SecretValue?

  public init() {}

  public func record(_ value: SecretValue) {
    lock.lock()
    stored = value
    lock.unlock()
  }

  public func revealed() -> String? {
    lock.lock()
    defer { lock.unlock() }
    return stored?.reveal()
  }
}

/// A fixed state generator so callback-state assertions are deterministic.
public struct FixedStateGenerator: StateGenerator {
  private let state: String

  public init(_ state: String = "fake-oauth-state-value") {
    self.state = state
  }

  public func makeState() -> SecretValue { SecretValue(state) }
}

/// Declares a fixed set of readable regular files and a fixed verdict for each
/// destination path, so destination validation can be exercised without
/// creating real directories.
public struct StubFileAccess: FileAccess {
  private let readable: Set<String>
  private let sizes: [String: Int]
  private let destinationProblems: [String: DestinationProblem]

  public init(
    readable: Set<String>,
    sizes: [String: Int] = [:],
    destinationProblems: [String: DestinationProblem] = [:]
  ) {
    self.readable = readable
    self.sizes = sizes
    self.destinationProblems = destinationProblems
  }

  public func isReadableRegularFile(atPath path: String) -> Bool {
    readable.contains(path)
  }

  public func fileSize(atPath path: String) -> Int? {
    sizes[path]
  }

  public func destinationProblem(atPath path: String) -> DestinationProblem? {
    destinationProblems[path]
  }
}

/// Returns queued process results, used for the kinko credential-store tests.
public actor StubProcessRunner: ProcessRunner {
  public struct Invocation: Sendable, Equatable {
    public let executable: String
    public let arguments: [String]
    /// Recorded so tests can pin the exact bytes a subcommand receives on
    /// stdin, not merely that stdin was used.
    public let standardInput: Data?

    public var hadStandardInput: Bool { standardInput != nil }
  }

  private var results: [ProcessResult]
  private var recorded: [Invocation] = []

  public init(results: [ProcessResult]) {
    self.results = results
  }

  public var invocations: [Invocation] { recorded }

  public func run(
    executable: String,
    arguments: [String],
    standardInput: Data?
  ) async throws -> ProcessResult {
    recorded.append(
      Invocation(
        executable: executable,
        arguments: arguments,
        standardInput: standardInput
      )
    )
    guard !results.isEmpty else {
      return ProcessResult(exitCode: 1, standardOutput: Data(), standardError: Data())
    }
    return results.removeFirst()
  }
}
