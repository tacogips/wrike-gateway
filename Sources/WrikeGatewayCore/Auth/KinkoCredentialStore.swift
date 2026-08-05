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
    if standardInput != nil {
      process.standardInput = Pipe()
    }

    do {
      try process.run()
    } catch {
      throw GatewayError(
        code: .fileOperationFailed,
        message: "The credential-store command could not be started.",
        recoveryGuidance: "Reinstall kinko so that \(executable) is an executable file."
      )
    }

    if let standardInput, let inputPipe = process.standardInput as? Pipe {
      inputPipe.fileHandleForWriting.write(standardInput)
      inputPipe.fileHandleForWriting.closeFile()
    }

    let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
    let errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return ProcessResult(
      exitCode: process.terminationStatus,
      standardOutput: output,
      standardError: errorOutput
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
  /// kinko's own marker for a vault that has not been unlocked. It is a fixed,
  /// non-secret status word, so matching it exactly never risks echoing a
  /// record.
  private static let lockedMarker = "locked"

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
      try throwIfLocked(result)
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
      try throwIfLocked(result)
      throw GatewayError(
        code: .fileOperationFailed,
        message: "The credential store did not accept the token record.",
        recoveryGuidance: "Run `kinko doctor` to check the local vault, then retry."
      )
    }
  }

  public func delete(_ key: CredentialRecordKey) async throws -> Bool {
    let result = try await run(["delete", key.storageName, "--yes"])
    guard result.exitCode == 0 else {
      try throwIfLocked(result)
      return false
    }
    return true
  }

  public func hasRecord(_ key: CredentialRecordKey) async throws -> Bool {
    // `--reveal` is deliberately omitted, so this check never decrypts the
    // token. Existence is decided from the exit code alone: kinko exits
    // non-zero for a missing key, and the masked body it prints on success is
    // not part of any contract this tool should depend on.
    let result = try await run(["get", key.storageName, "--force"])
    guard result.exitCode == 0 else {
      try throwIfLocked(result)
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

  /// A locked vault is an actionable operator state, not a missing record, so
  /// it must not be reported as "no credential is available".
  private func throwIfLocked(_ result: ProcessResult) throws {
    let marker = String(data: Self.trimmed(result.standardError), encoding: .utf8)
    guard marker == Self.lockedMarker else { return }
    throw GatewayError(
      code: .fileOperationFailed,
      message: "The credential store is locked.",
      recoveryGuidance: "Run `kinko unlock`, then retry."
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
