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
        recoveryGuidance: "Install kinko and ensure it is on PATH."
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

/// The required initial credential-store backend.
///
/// Records are written to kinko's protected storage through `kinko set-key` and
/// read through `kinko get`. No plaintext fallback exists: a kinko failure is
/// surfaced as `FILE_OPERATION_FAILED` rather than degrading to an unprotected
/// file. Neither the record body nor kinko's stderr is ever echoed, because both
/// may contain token material.
public struct KinkoCredentialStore: CredentialStore {
  private let runner: any ProcessRunner
  private let executablePath: String

  public init(runner: any ProcessRunner = SystemProcessRunner(), executablePath: String = "/opt/homebrew/bin/kinko") {
    self.runner = runner
    self.executablePath = executablePath
  }

  public func load(_ key: CredentialRecordKey) async throws -> OAuthTokenState? {
    let result = try await runner.run(
      executable: executablePath,
      arguments: ["get", key.storageName, "--quiet"],
      standardInput: nil
    )
    guard result.exitCode == 0 else { return nil }
    let payload = result.standardOutput
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
    let result = try await runner.run(
      executable: executablePath,
      arguments: ["set-key", key.storageName, "--stdin"],
      standardInput: payload
    )
    guard result.exitCode == 0 else {
      throw GatewayError(
        code: .fileOperationFailed,
        message: "The credential store did not accept the token record.",
        recoveryGuidance: "Run `kinko doctor` to check the local vault, then retry."
      )
    }
  }

  public func delete(_ key: CredentialRecordKey) async throws -> Bool {
    let result = try await runner.run(
      executable: executablePath,
      arguments: ["delete", key.storageName, "--quiet"],
      standardInput: nil
    )
    return result.exitCode == 0
  }

  public func hasRecord(_ key: CredentialRecordKey) async throws -> Bool {
    let result = try await runner.run(
      executable: executablePath,
      arguments: ["get", key.storageName, "--quiet"],
      standardInput: nil
    )
    return result.exitCode == 0 && !result.standardOutput.isEmpty
  }

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }()

  private static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()
}
