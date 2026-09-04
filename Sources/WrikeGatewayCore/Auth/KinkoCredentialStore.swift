import Foundation
import Darwin

/// Runs an external process. Injected so credential-store tests never spawn a
/// real binary and never require a provisioned vault.
public protocol ProcessRunner: Sendable {
  func run(executable: String, arguments: [String], standardInput: Data?) async throws -> ProcessResult
}

/// A process runner that accepts caller-owned environment and liveness policy.
/// `KinkoCredentialStore` uses this for its production runner; legacy custom
/// test runners remain source compatible with the original ProcessRunner API.
public protocol ConfigurableProcessRunner: ProcessRunner {
  func run(
    executable: String,
    arguments: [String],
    standardInput: Data?,
    options: ProcessExecutionOptions
  ) async throws -> ProcessResult
}

/// Execution controls for an injected external-process boundary.
///
/// A restricted environment is deliberately distinct from an empty inherited
/// environment: credential-store calls must never acquire ambient variables
/// from the embedding process.
public struct ProcessExecutionOptions: Sendable, Equatable {
  public let environment: [String: String]?
  public let timeoutSeconds: Double?

  public init(environment: [String: String]? = nil, timeoutSeconds: Double? = nil) {
    self.environment = environment
    self.timeoutSeconds = timeoutSeconds
  }

  public static let inherited = ProcessExecutionOptions()
}

/// Identifies the caller that owns a credential-store process boundary.
///
/// Command-line invocations retain the established PATH-based kinko discovery
/// contract. Facade calls run inside another host process, so they require a
/// fixed trusted executable location and a restricted child environment.
public enum KinkoCredentialStoreExecutionContext: Sendable, Equatable {
  case commandLine
  case facade
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

public struct SystemProcessRunner: ConfigurableProcessRunner {
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

  public func run(executable: String, arguments: [String], standardInput: Data?) async throws -> ProcessResult {
    try await run(
      executable: executable,
      arguments: arguments,
      standardInput: standardInput,
      options: .inherited
    )
  }

  public func run(
    executable: String,
    arguments: [String],
    standardInput: Data?,
    options: ProcessExecutionOptions
  ) async throws -> ProcessResult {
    let process = Process()
    // The caller always passes an absolute path resolved by
    // `KinkoExecutableResolver`; `Process` itself never searches `PATH`.
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = options.environment

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    let inputPipe = standardInput.map { _ in Pipe() }
    process.standardInput = inputPipe

    let collector = StreamCollector()
    let group = DispatchGroup()
    let queue = DispatchQueue.global(qos: .userInitiated)
    let completion = ProcessCompletion(process: process, collector: collector, streamGroup: group)
    process.terminationHandler = { _ in completion.processExited() }

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
    return try await completion.wait(timeoutSeconds: options.timeoutSeconds, queue: queue)
  }

  /// Protects Process and continuation state shared by cancellation, timeout,
  /// Foundation's termination callback, and the pipe-draining workers.
  private final class ProcessCompletion: @unchecked Sendable {
    private let process: Process
    private let collector: StreamCollector
    private let streamGroup: DispatchGroup
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ProcessResult, any Error>?
    private var terminalReason: TerminalReason?
    private var didExit = false

    private enum TerminalReason {
      case cancelled
      case timedOut
    }

    init(process: Process, collector: StreamCollector, streamGroup: DispatchGroup) {
      self.process = process
      self.collector = collector
      self.streamGroup = streamGroup
    }

    func wait(timeoutSeconds: Double?, queue: DispatchQueue) async throws -> ProcessResult {
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          install(continuation: continuation)
          if let timeoutSeconds {
            scheduleTimeout(after: timeoutSeconds, queue: queue)
          }
        }
      } onCancel: {
        cancel()
      }
    }

    func install(continuation: CheckedContinuation<ProcessResult, any Error>) {
      lock.lock()
      self.continuation = continuation
      let exited = didExit
      lock.unlock()
      if exited { finishAfterStreams() }
    }

    func scheduleTimeout(after seconds: Double, queue: DispatchQueue) {
      guard seconds > 0 else {
        timeout()
        return
      }
      queue.asyncAfter(deadline: .now() + seconds) { [self] in timeout() }
    }

    func cancel() {
      stop(reason: .cancelled)
    }

    func processExited() {
      lock.lock()
      didExit = true
      let hasContinuation = continuation != nil
      lock.unlock()
      if hasContinuation { finishAfterStreams() }
    }

    private func timeout() {
      stop(reason: .timedOut)
    }

    private func stop(reason: TerminalReason) {
      lock.lock()
      guard process.isRunning else {
        lock.unlock()
        return
      }
      if terminalReason == nil { terminalReason = reason }
      lock.unlock()
      process.terminate()
      // A process may ignore SIGTERM. Escalate after a brief cleanup grace so
      // timeout and task cancellation cannot leave a credential operation
      // indefinitely pending.
      DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.2) { [self] in
        lock.lock()
        let stillRunning = process.isRunning
        lock.unlock()
        if stillRunning { kill(process.processIdentifier, SIGKILL) }
      }
    }

    private func finishAfterStreams() {
      streamGroup.notify(queue: .global(qos: .userInitiated)) { [self] in
        lock.lock()
        guard let continuation else {
          lock.unlock()
          return
        }
        self.continuation = nil
        let reason = terminalReason
        let status = process.terminationStatus
        lock.unlock()
        switch reason {
        case .cancelled:
          continuation.resume(throwing: CancellationError())
        case .timedOut:
          continuation.resume(
            throwing: GatewayError(
              code: .fileOperationFailed,
              message: "The credential-store command timed out.",
              recoveryGuidance: "Check kinko, then retry the operation."
            )
          )
        case nil:
          let streams = collector.streams
          continuation.resume(
            returning: ProcessResult(
              exitCode: status,
              standardOutput: streams.output,
              standardError: streams.errorOutput
            )
          )
        }
      }
    }
  }
}

/// Finds the kinko executable.
///
/// The command line preserves PATH discovery for existing installations. The
/// production facade supplies this resolver with a nil search path, so a host
/// process can never choose its credential executable through ambient PATH.
public struct KinkoExecutableResolver: Sendable {
  /// Fixed absolute locations used after command-line PATH discovery and as
  /// the complete trusted set for facade execution.
  public static let fallbackPaths = ["/opt/homebrew/bin/kinko", "/usr/local/bin/kinko"]

  private let searchPath: String?
  private let trustedPaths: [String]
  private let isExecutable: @Sendable (String) -> Bool

  public init(
    searchPath: String? = ProcessInfo.processInfo.environment["PATH"],
    trustedPaths: [String] = KinkoExecutableResolver.fallbackPaths,
    isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
  ) {
    self.searchPath = searchPath
    self.trustedPaths = trustedPaths.filter { $0.hasPrefix("/") }
    self.isExecutable = isExecutable
  }

  public func resolve() -> String? {
    for directory in (searchPath ?? "").split(separator: ":", omittingEmptySubsequences: true) {
      let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("kinko").path
      if isExecutable(candidate) { return candidate }
    }
    return trustedPaths.first(where: isExecutable)
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
  /// A credential-store process must not be able to hold an SDK call forever.
  public static let defaultProcessTimeoutSeconds = 15.0

  private let runner: any ProcessRunner
  private let executablePath: String?
  private let resolver: KinkoExecutableResolver
  private let scopePath: String
  private let profile: String
  private let processTimeoutSeconds: Double
  private let executionContext: KinkoCredentialStoreExecutionContext

  public init(
    runner: any ProcessRunner = SystemProcessRunner(),
    executablePath: String? = nil,
    resolver: KinkoExecutableResolver? = nil,
    scopePath: String = KinkoCredentialStore.defaultScopePath,
    profile: String = KinkoCredentialStore.defaultProfile,
    processTimeoutSeconds: Double = KinkoCredentialStore.defaultProcessTimeoutSeconds,
    executionContext: KinkoCredentialStoreExecutionContext = .commandLine
  ) {
    self.runner = runner
    self.executablePath = executablePath
    self.resolver = resolver ?? KinkoExecutableResolver(
      searchPath: executionContext == .commandLine ? ProcessInfo.processInfo.environment["PATH"] : nil
    )
    self.scopePath = scopePath
    self.profile = profile
    self.processTimeoutSeconds = processTimeoutSeconds
    self.executionContext = executionContext
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
    do {
      let executable = try executable()
      let arguments = arguments + ["--path", scopePath, "--profile", profile]
      let options = ProcessExecutionOptions(
        environment: executionContext == .facade ? ["HOME": scopePath, "LC_ALL": "C"] : nil,
        timeoutSeconds: processTimeoutSeconds
      )
      if let configurableRunner = runner as? any ConfigurableProcessRunner {
        return try await configurableRunner.run(
          executable: executable,
          arguments: arguments,
          standardInput: standardInput,
          options: options
        )
      }
      return try await runner.run(executable: executable, arguments: arguments, standardInput: standardInput)
    } catch is CancellationError {
      throw GatewayError(
        code: .fileOperationFailed,
        message: "The credential-store command was cancelled.",
        recoveryGuidance: "Confirm the credential-store state before retrying."
      )
    }
  }

  private func executable() throws -> String {
    if let executablePath {
      guard executablePath.hasPrefix("/") else {
        throw GatewayError(
          code: .fileOperationFailed,
          message: "The kinko credential-store executable path is not absolute.",
          recoveryGuidance: "Configure an absolute trusted kinko executable path."
        )
      }
      return executablePath
    }
    guard let resolved = resolver.resolve() else {
      let recoveryGuidance: String
      switch executionContext {
      case .commandLine:
        recoveryGuidance = "Install kinko on PATH, or at "
          + KinkoExecutableResolver.fallbackPaths.joined(separator: " or ") + "."
      case .facade:
        recoveryGuidance = "Install kinko at "
          + KinkoExecutableResolver.fallbackPaths.joined(separator: " or ") + "."
      }
      throw GatewayError(
        code: .fileOperationFailed,
        message: "The kinko credential-store executable was not found.",
        recoveryGuidance: recoveryGuidance
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
