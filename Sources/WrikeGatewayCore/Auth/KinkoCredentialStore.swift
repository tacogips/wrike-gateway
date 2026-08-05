import Foundation

/// Runs an external process. Injected so credential-store tests never spawn a
/// real binary and never require a provisioned vault.
public protocol ProcessRunner: Sendable {
  func run(executable: String, arguments: [String], standardInput: Data?) async throws -> ProcessResult
}

public struct ProcessResult: Sendable, Equatable {
  public let exitCode: Int32
  public let standardOutput: Data
  public let standardError: Data

  public init(exitCode: Int32, standardOutput: Data, standardError: Data) {
    self.exitCode = exitCode
    self.standardOutput = standardOutput
    self.standardError = standardError
  }
}

public struct SystemProcessRunner: ProcessRunner {
  /// Collects the two output streams that are drained on separate threads.
  private final class StreamCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var output = Data()
    private var errorOutput = Data()

    func setOutput(_ data: Data) {
      lock.lock()
      defer { lock.unlock() }
      output = data
    }

    func setErrorOutput(_ data: Data) {
      lock.lock()
      defer { lock.unlock() }
      errorOutput = data
    }

    var streams: (output: Data, errorOutput: Data) {
      lock.lock()
      defer { lock.unlock() }
      return (output, errorOutput)
    }
  }

  public init() {}

  public func run(
    executable: String,
    arguments: [String],
    standardInput: Data?
  ) async throws -> ProcessResult {
    let process = Process()
    // The caller always passes an absolute path resolved by
    // `KinkoExecutableResolver`; `Process` itself never searches `PATH`.
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    let inputPipe = standardInput.map { _ in Pipe() }
    process.standardInput = inputPipe

    do {
      try process.run()
    } catch {
      throw GatewayError(
        code: .fileOperationFailed,
        message: "The credential-store command could not be started.",
        recoveryGuidance: "Reinstall kinko so that \(executable) is an executable file."
      )
    }

    // stdin, stdout, and stderr are serviced concurrently. Writing stdin or
    // draining one output stream to EOF before touching the other deadlocks as
    // soon as the child fills the pipe buffer nobody is reading: the child
    // blocks on its write and this side blocks on the stream the child is no
    // longer producing.
    let collector = StreamCollector()
    let group = DispatchGroup()
    let queue = DispatchQueue.global(qos: .userInitiated)

    if let standardInput, let inputHandle = inputPipe?.fileHandleForWriting {
      queue.async(group: group) {
        inputHandle.write(standardInput)
        inputHandle.closeFile()
      }
    }
    let outputHandle = outputPipe.fileHandleForReading
    queue.async(group: group) {
      collector.setOutput((try? outputHandle.readToEnd()) ?? Data())
    }
    let errorHandle = errorPipe.fileHandleForReading
    queue.async(group: group) {
      collector.setErrorOutput((try? errorHandle.readToEnd()) ?? Data())
    }
    await withCheckedContinuation { continuation in
      group.notify(queue: queue) { continuation.resume() }
    }

    process.waitUntilExit()
    let streams = collector.streams
    return ProcessResult(
      exitCode: process.terminationStatus,
      standardOutput: streams.output,
      standardError: streams.errorOutput
    )
  }
}

/// Finds the kinko executable.
///
/// `Process` does not search `PATH`, and kinko is installed under a different
/// prefix on Apple Silicon Homebrew (`/opt/homebrew/bin`), Intel Homebrew
/// (`/usr/local/bin`), and Nix (a `/nix/store` path exposed only through
/// `PATH`), so the absolute path is resolved here instead of being assumed.
public struct KinkoExecutableResolver: Sendable {
  /// Prefixes checked after `PATH`, so a Homebrew install is still found when
  /// the binary runs from a launch context with a minimal environment.
  public static let fallbackPaths = ["/opt/homebrew/bin/kinko", "/usr/local/bin/kinko"]

  private let searchPath: String?
  private let isExecutable: @Sendable (String) -> Bool

  public init(
    searchPath: String? = ProcessInfo.processInfo.environment["PATH"],
    isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
  ) {
    self.searchPath = searchPath
    self.isExecutable = isExecutable
  }

  public func resolve() -> String? {
    for directory in (searchPath ?? "").split(separator: ":", omittingEmptySubsequences: true) {
      let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("kinko").path
      if isExecutable(candidate) { return candidate }
    }
    return Self.fallbackPaths.first(where: isExecutable)
  }
}

/// The required initial credential-store backend.
///
/// Every invocation below was verified against `kinko version` 0.1.8 by reading
/// `kinko get --help`, `kinko set-key --help`, and `kinko delete --help`:
///
/// - `get KEY` accepts `--reveal` (plaintext) and no `--quiet`; without
///   `--reveal` it prints a masked value, which is enough for an existence
///   check that never decrypts token material.
/// - `set-key KEY` accepts `--value` and, per its own diagnostic
///   ("set-key requires --value or stdin value"), a value piped on stdin. The
///   record is written over stdin because `--value` would place token material
///   in the process listing, where any local user can read it.
/// - `delete KEY` accepts `-y/--yes` and no `--quiet`; `--all` is never passed.
/// - The global `--force` overrides kinko's non-tty guardrail ("sensitive
///   output blocked for non-tty/redirection (use --force)"), which would
///   otherwise block every read made through a pipe, and the global
///   `--confirm=false` keeps a write from waiting on a terminal prompt.
/// - The global `--path` defaults to the current working directory and
///   `--profile` defaults to `default` (overridable by `KINKO_PROFILE`), so
///   both are pinned explicitly; otherwise a token stored from one directory
///   would be invisible to the same binary run from another.
///
/// No plaintext fallback exists: a kinko failure is surfaced as
/// `FILE_OPERATION_FAILED` rather than degrading to an unprotected file.
/// Neither the record body nor kinko's stderr is ever echoed, because both may
/// contain token material.
public struct KinkoCredentialStore: CredentialStore {
  /// One way kinko reports that it could not open the vault at all.
  private struct StoreUnavailableMarker: Sendable {
    let exitCode: Int32
    /// kinko's trimmed stderr. Each of these is a fixed, non-secret status
    /// line, so matching it exactly never risks echoing a record.
    let standardError: String
    let message: String
  }

  /// The one answer that means "this key is not in the vault" rather than "this
  /// command failed".
  ///
  /// Verified on 2026-08-05 against an unlocked disposable vault at
  /// `kinko version` 0.1.8: a key that does not exist answers exit 1 with
  /// stderr `secret not found` on both `get` and `delete`. It shares exit 1
  /// with the locked-vault marker, so the stderr line is matched as well.
  ///
  /// Everything outside this marker and `storeUnavailableMarkers` is a thrown
  /// error, never a missing record. Treating an unrecognised failure as "no
  /// record" is what lets `auth logout` report `removedLocalRecord: false`
  /// while the refresh token is still stored.
  private static let recordMissingMarker = (exitCode: Int32(1), standardError: "secret not found")

  /// Every store-unavailable answer kinko 0.1.8 gives, per subcommand.
  ///
  /// Verified on 2026-08-05 by running the commands: against the operator's
  /// real locked vault (`kinko status` -> `locked`) with a key that does not
  /// exist, and against an empty temporary `--kinko-dir`.
  ///
  /// | Command | Locked vault | No vault at that dir |
  /// | --- | --- | --- |
  /// | `get` | exit 1, `locked` | exit 1, `open .../vault/meta.v1.json: no such file or directory` |
  /// | `set-key` | exit 1, `locked` | exit 12, `Vault mutation in progress.` |
  /// | `delete` | exit 13, `Failed to load vault.` | exit 13, `Failed to load vault.` |
  ///
  /// `delete` never prints `locked`, so classifying on that one marker would
  /// misclassify exactly the path where a wrong answer silently strands a
  /// refresh token. The exit code is matched alongside the text so an
  /// unrelated failure that happens to mention a vault is not swallowed here.
  private static let storeUnavailableMarkers = [
    StoreUnavailableMarker(exitCode: 1, standardError: "locked", message: "The credential store is locked."),
    StoreUnavailableMarker(
      exitCode: 13,
      standardError: "Failed to load vault.",
      message: "The credential store could not be opened."
    ),
    StoreUnavailableMarker(
      exitCode: 12,
      standardError: "Vault mutation in progress.",
      message: "The credential store is not available for writing."
    )
  ]

  /// `delete` cannot tell a locked vault from an absent one, so the guidance
  /// names both recoveries rather than asserting which one applies.
  private static let unavailableGuidance =
    "Run `kinko unlock` (or `kinko init` if no vault exists yet), then retry."

  /// The OAuth record belongs to the user, not to a checkout, so the path scope
  /// is pinned to the home directory instead of the working directory.
  public static var defaultScopePath: String { NSHomeDirectory() }
  public static let defaultProfile = "default"

  private let runner: any ProcessRunner
  private let executablePath: String?
  private let resolver: KinkoExecutableResolver
  private let scopePath: String
  private let profile: String

  public init(
    runner: any ProcessRunner = SystemProcessRunner(),
    executablePath: String? = nil,
    resolver: KinkoExecutableResolver = KinkoExecutableResolver(),
    scopePath: String = KinkoCredentialStore.defaultScopePath,
    profile: String = KinkoCredentialStore.defaultProfile
  ) {
    self.runner = runner
    self.executablePath = executablePath
    self.resolver = resolver
    self.scopePath = scopePath
    self.profile = profile
  }

  public func load(_ key: CredentialRecordKey) async throws -> OAuthTokenState? {
    let result = try await run(["get", key.storageName, "--reveal", "--force"])
    guard result.exitCode == 0 else {
      try requireMissingRecord(result, otherwise: "The credential store did not return the token record.")
      return nil
    }
    let payload = Self.trimmed(result.standardOutput)
    guard !payload.isEmpty else { return nil }
    do {
      return try Self.decoder.decode(OAuthTokenState.self, from: payload)
    } catch {
      throw GatewayError(
        code: .fileOperationFailed,
        message: "The stored credential record could not be decoded.",
        recoveryGuidance: "Run `auth logout` and then `auth oauth2` to re-create the record."
      )
    }
  }

  public func replace(_ state: OAuthTokenState, for key: CredentialRecordKey) async throws {
    let payload: Data
    do {
      payload = try Self.encoder.encode(state)
    } catch {
      throw GatewayError(code: .fileOperationFailed, message: "The credential record could not be encoded.")
    }
    // kinko performs the write atomically; a non-zero exit means nothing was
    // committed, so the caller must not claim login success.
    let result = try await run(["set-key", key.storageName, "--confirm=false"], standardInput: payload)
    guard result.exitCode == 0 else {
      try throwIfStoreUnavailable(result)
      throw GatewayError(
        code: .fileOperationFailed,
        message: "The credential store did not accept the token record.",
        recoveryGuidance: "Run `kinko doctor` to check the local vault, then retry."
      )
    }
  }

  public func delete(_ key: CredentialRecordKey) async throws -> Bool {
    // A single invocation. `delete` reports a missing key itself, so there is
    // no existence check to race against, and "nothing to remove" is answered
    // by the same command that would have removed it.
    let result = try await run(["delete", key.storageName, "--yes"])
    guard result.exitCode == 0 else {
      try requireMissingRecord(result, otherwise: "The credential store did not remove the token record.")
      return false
    }
    return true
  }

  public func hasRecord(_ key: CredentialRecordKey) async throws -> Bool {
    // `--reveal` is deliberately omitted, so this check never decrypts the
    // token. Existence is decided from the exit status and the missing-record
    // marker; the masked body kinko prints on success is not part of any
    // contract this tool should depend on.
    let result = try await run(["get", key.storageName, "--force"])
    guard result.exitCode == 0 else {
      try requireMissingRecord(result, otherwise: "The credential store did not answer the existence check.")
      return false
    }
    return true
  }

  private func run(_ arguments: [String], standardInput: Data? = nil) async throws -> ProcessResult {
    try await runner.run(
      executable: try executable(),
      arguments: arguments + ["--path", scopePath, "--profile", profile],
      standardInput: standardInput
    )
  }

  private func executable() throws -> String {
    if let executablePath { return executablePath }
    guard let resolved = resolver.resolve() else {
      throw GatewayError(
        code: .fileOperationFailed,
        message: "The kinko credential-store executable was not found.",
        recoveryGuidance: "Install kinko so that it is on PATH, or at "
          + KinkoExecutableResolver.fallbackPaths.joined(separator: " or ") + "."
      )
    }
    return resolved
  }

  /// Returns normally only when kinko reported that the record does not exist.
  ///
  /// Every other non-zero exit throws: an unopenable vault as its own
  /// actionable state, and anything unrecognised as `otherwise`. A caller may
  /// therefore treat a normal return as "no record" without the risk that a
  /// failure it did not anticipate is reported as an empty store.
  private func requireMissingRecord(_ result: ProcessResult, otherwise message: String) throws {
    let marker = String(data: Self.trimmed(result.standardError), encoding: .utf8) ?? ""
    if result.exitCode == Self.recordMissingMarker.exitCode,
      marker == Self.recordMissingMarker.standardError {
      return
    }
    try throwIfStoreUnavailable(result, marker: marker)
    throw GatewayError(
      code: .fileOperationFailed,
      message: message,
      recoveryGuidance: "Run `kinko doctor` to check the local vault, then retry."
    )
  }

  /// A vault that could not be opened is an actionable operator state, not a
  /// missing record, so it must not be reported as "no credential is
  /// available".
  private func throwIfStoreUnavailable(_ result: ProcessResult, marker: String? = nil) throws {
    let marker = marker ?? String(data: Self.trimmed(result.standardError), encoding: .utf8) ?? ""
    guard let match = Self.storeUnavailableMarkers.first(where: {
      $0.exitCode == result.exitCode && $0.standardError == marker
    }) else { return }
    throw GatewayError(
      code: .fileOperationFailed,
      message: match.message,
      recoveryGuidance: Self.unavailableGuidance
    )
  }

  private static func trimmed(_ data: Data) -> Data {
    var slice = data[...]
    while let first = slice.first, first == 0x20 || first == 0x09 || first == 0x0a || first == 0x0d {
      slice = slice.dropFirst()
    }
    while let last = slice.last, last == 0x20 || last == 0x09 || last == 0x0a || last == 0x0d {
      slice = slice.dropLast()
    }
    return Data(slice)
  }

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    // Without this the key order varies between encodes, so the same record
    // would be written as different bytes on every refresh.
    encoder.outputFormatting = .sortedKeys
    return encoder
  }()

  private static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()
}
