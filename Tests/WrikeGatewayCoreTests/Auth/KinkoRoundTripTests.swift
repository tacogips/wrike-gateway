import Foundation
import Testing
import WrikeGatewayCore

/// Runs the store's production argv unchanged and appends only the two flags
/// that redirect kinko's state, so the round trip below reads and writes a
/// disposable vault instead of the operator's.
private struct KinkoDirectoryRunner: ProcessRunner {
  let isolation: [String]
  private let inner = SystemProcessRunner()

  init(isolation: [String]) {
    self.isolation = isolation
  }

  func run(executable: String, arguments: [String], standardInput: Data?) async throws -> ProcessResult {
    try await inner.run(executable: executable, arguments: arguments + isolation, standardInput: standardInput)
  }
}

/// A kinko vault created for one test run and destroyed afterwards.
///
/// The path scope is a temporary directory rather than the home directory the
/// production store pins, so no record this suite writes can collide with a
/// real one.
private struct DisposableVault {
  let executable: String
  let directory: URL
  let scope: URL

  /// Only ever protects synthetic records inside a temporary directory.
  private static let password = "wrike-gateway-disposable-vault"
  private let runner = SystemProcessRunner()

  /// Redirects both pieces of kinko state this suite would otherwise share with
  /// the operator.
  ///
  /// `--config` is not optional here: `kinko init --kinko-dir X` rewrites the
  /// bootstrap config at `~/.config/kinko/bootstrap.toml` so that every later
  /// kinko command defaults to `X`. Without the redirect, this suite would
  /// leave the operator's kinko pointing at a temporary directory that it then
  /// deletes, and `kinko status` would fail until the file was repaired by
  /// hand.
  var isolationFlags: [String] {
    ["--kinko-dir", directory.path, "--config", configPath.path]
  }

  var configPath: URL { directory.deletingLastPathComponent().appendingPathComponent("bootstrap.toml") }

  /// Global flags every command in this suite carries.
  private var scopeFlags: [String] {
    ["--path", scope.path, "--profile", "default"] + isolationFlags
  }

  /// `--keychain-preflight off` appears only here. It is what lets a vault be
  /// created without a provisioned keychain entry, and it is never part of the
  /// production argv the store builds.
  func initialize() async throws -> ProcessResult {
    try await runner.run(
      executable: executable,
      arguments: ["init"] + scopeFlags + ["--force", "--keychain-preflight", "off"],
      standardInput: Data("\(Self.password)\n\(Self.password)\n".utf8)
    )
  }

  func unlock() async throws -> ProcessResult {
    try await runner.run(
      executable: executable,
      arguments: ["unlock"] + scopeFlags + ["--force", "--keychain-preflight", "off"],
      standardInput: Data("\(Self.password)\n".utf8)
    )
  }

  func lock() async throws -> ProcessResult {
    try await runner.run(executable: executable, arguments: ["lock"] + scopeFlags, standardInput: nil)
  }

  /// Creates and unlocks a vault, runs `body`, then always locks the session
  /// and removes the vault, including when `body` throws.
  static func withDisposableVault(
    executable: String,
    _ body: (DisposableVault) async throws -> Void
  ) async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("wrike-gateway-kinko-roundtrip-\(UUID().uuidString)")
    let vault = DisposableVault(
      executable: executable,
      directory: root.appendingPathComponent("kinko-dir"),
      scope: root.appendingPathComponent("scope")
    )
    for directory in [vault.directory, vault.scope] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    // The operator's own bootstrap config must come back byte-identical; see
    // `isolationFlags`.
    let operatorConfig = URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent(".config/kinko/bootstrap.toml")
    let operatorConfigBefore = try? Data(contentsOf: operatorConfig)
    do {
      #expect(try await vault.initialize().exitCode == 0)
      #expect(try await vault.unlock().exitCode == 0)
      #expect((try? Data(contentsOf: operatorConfig)) == operatorConfigBefore, "kinko rewrote the operator's config")
      try await body(vault)
      #expect((try? Data(contentsOf: operatorConfig)) == operatorConfigBefore, "kinko rewrote the operator's config")
    } catch {
      // Ordering matters: the session outlives the directory, so it is closed
      // before the vault it belongs to is removed.
      _ = try? await vault.lock()
      try? FileManager.default.removeItem(at: root)
      throw error
    }
    _ = try? await vault.lock()
    try? FileManager.default.removeItem(at: root)
  }
}

/// Decides whether the round trip may run at all.
///
/// kinko 0.1.8 sessions are not isolated by `--kinko-dir` or `--path`: once
/// this suite unlocks its disposable vault, `kinko status` reports `unlocked`
/// for every scope, and the `lock` at the end of the run returns every scope to
/// `locked`. Running while a session is already open would therefore end a
/// session this suite did not start, so that case is not enabled rather than
/// silently tolerated.
private enum KinkoRoundTripPrecondition {
  static let isSatisfied: Bool = {
    guard ProcessInfo.processInfo.environment["WRIKE_GATEWAY_KINKO_ROUNDTRIP"] == "1",
      let executable = KinkoExecutableResolver().resolve() else { return false }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = ["status", "--path", NSHomeDirectory(), "--profile", "default"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    guard (try? process.run()) != nil else { return false }
    let output = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
    process.waitUntilExit()
    return String(data: output, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) == "locked"
  }()
}

/// Round-trips the credential store through a real kinko vault.
///
/// Opt in with `WRIKE_GATEWAY_KINKO_ROUNDTRIP=1 swift test`. This suite is
/// separate from `KinkoInterfaceIntegrationTests` because, unlike that
/// argv replay, it creates and unlocks a vault, and unlocking is a global side
/// effect in kinko 0.1.8. It writes only a synthetic record, into a temporary
/// vault directory under a temporary path scope, with kinko's bootstrap config
/// redirected to a temporary file, and it locks the session again before it
/// returns.
@Suite(
  "Kinko credential-store round trip",
  .enabled(if: KinkoRoundTripPrecondition.isSatisfied),
  .serialized
)
struct KinkoRoundTripTests {
  private static func state(accessToken: String, expiresAt: Date) -> OAuthTokenState {
    OAuthTokenState(
      accessToken: SecretValue(accessToken),
      refreshToken: SecretValue("synthetic-refresh"),
      expiresAt: expiresAt,
      grantedScopes: ["wsReadOnly", "wsReadWrite"],
      host: "www.wrike.com",
      clientID: SecretValue("synthetic-client")
    )
  }

  @Test("The store loads, replaces, and deletes a real record through kinko")
  func roundTrip() async throws {
    let executable = try #require(
      KinkoExecutableResolver().resolve(),
      "kinko is not installed; the round-trip switch requires it"
    )
    try await DisposableVault.withDisposableVault(executable: executable) { vault in
      let store = KinkoCredentialStore(
        runner: KinkoDirectoryRunner(isolation: vault.isolationFlags),
        executablePath: executable,
        scopePath: vault.scope.path
      )
      let key = CredentialRecordKey(clientID: SecretValue("synthetic-client"), host: "www.wrike.com")

      // An empty vault: no record, nothing to remove, and neither answer is a
      // thrown error.
      #expect(try await store.hasRecord(key) == false)
      #expect(try await store.load(key) == nil)
      #expect(try await store.delete(key) == false)

      // Second precision, because the record is serialised as ISO-8601 and a
      // sub-second component would not survive the round trip.
      let expiresAt = Date(timeIntervalSince1970: 1_900_000_000)
      let written = Self.state(accessToken: "synthetic-access", expiresAt: expiresAt)
      try await store.replace(written, for: key)
      #expect(try await store.hasRecord(key))
      #expect(try await store.load(key) == written)

      // A rotation overwrites in place rather than accumulating records.
      let rotated = Self.state(
        accessToken: "synthetic-access-rotated",
        expiresAt: expiresAt.addingTimeInterval(3600)
      )
      try await store.replace(rotated, for: key)
      #expect(try await store.load(key) == rotated)

      // Logout removes the record, and a repeated logout reports the no-op
      // rather than failing.
      #expect(try await store.delete(key))
      #expect(try await store.load(key) == nil)
      #expect(try await store.hasRecord(key) == false)
      #expect(try await store.delete(key) == false)
    }
  }
}
