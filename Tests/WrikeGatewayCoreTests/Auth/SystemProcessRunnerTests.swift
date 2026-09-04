import Foundation
import Darwin
import Testing
import WrikeGatewayCore

/// The process seam the credential store runs kinko through.
///
/// These tests spawn `/bin/sh`, never kinko, so they touch no vault and need no
/// credential.
@Suite("System process runner streams")
struct SystemProcessRunnerTests {
  /// Comfortably larger than the 64 KiB pipe buffer on Darwin, so each stream
  /// blocks its writer unless the reader is draining it concurrently.
  private static let chunkSize = 256 * 1024

  private static func shellQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\\"'\\\"'"))'"
  }

  private static func waitForChildPID(at fileURL: URL) async throws -> pid_t {
    for _ in 0..<100 {
      if let value = try? String(contentsOf: fileURL, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
        let rawValue = Int32(value) {
        return pid_t(rawValue)
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw GatewayError(code: .fileOperationFailed, message: "The test child did not report its process ID.")
  }

  private static func isRunning(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
  }

  @Test("A child that fills both output pipes and reads a large stdin does not deadlock", .timeLimit(.minutes(1)))
  func concurrentDrainsSurviveFullPipeBuffers() async throws {
    // The child writes past the buffer on stderr, then past it on stdout, and
    // only then reads stdin. Draining either stream to EOF before the other, or
    // writing stdin before draining anything, blocks both sides forever: the
    // child waits for a reader that is waiting for the child.
    let script = "head -c \(Self.chunkSize) /dev/zero | tr '\\000' 'E' >&2;"
      + " head -c \(Self.chunkSize) /dev/zero | tr '\\000' 'O';"
      + " cat > /dev/null"
    let standardInput = Data(repeating: UInt8(ascii: "I"), count: Self.chunkSize)

    let result = try await SystemProcessRunner().run(
      executable: "/bin/sh",
      arguments: ["-c", script],
      standardInput: standardInput
    )

    #expect(result.exitCode == 0)
    #expect(result.standardOutput.count == Self.chunkSize)
    #expect(result.standardError.count == Self.chunkSize)
    #expect(result.standardOutput.allSatisfy { $0 == UInt8(ascii: "O") })
    #expect(result.standardError.allSatisfy { $0 == UInt8(ascii: "E") })
  }

  @Test("Both streams are returned separately with the exit status")
  func separatesStreams() async throws {
    let result = try await SystemProcessRunner().run(
      executable: "/bin/sh",
      arguments: ["-c", "printf out; printf err >&2; exit 13"],
      standardInput: nil
    )
    #expect(result.exitCode == 13)
    #expect(String(data: result.standardOutput, encoding: .utf8) == "out")
    #expect(String(data: result.standardError, encoding: .utf8) == "err")
  }

  @Test("A missing executable is an actionable failure rather than a crash")
  func missingExecutable() async throws {
    do {
      _ = try await SystemProcessRunner().run(
        executable: "/nonexistent/wrike-gateway-probe",
        arguments: [],
        standardInput: nil
      )
      Issue.record("Expected the missing executable to surface")
    } catch let error as GatewayError {
      #expect(error.code == .fileOperationFailed)
    }
  }

  @Test("A restricted process environment does not inherit host values")
  func restrictedEnvironmentDoesNotInheritHostValues() async throws {
    let result = try await SystemProcessRunner().run(
      executable: "/bin/sh",
      arguments: ["-c", "printf '%s' \"${WRIKE_GATEWAY_UNRELATED-unset}\""],
      standardInput: nil,
      options: ProcessExecutionOptions(environment: ["HOME": "/safe", "LC_ALL": "C"], timeoutSeconds: 1)
    )
    #expect(result.exitCode == 0)
    #expect(String(data: result.standardOutput, encoding: .utf8) == "unset")
  }

  @Test("A timed-out child is terminated and returns promptly")
  func timeoutTerminatesChild() async throws {
    let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: pidFile) }
    let started = Date()
    let task = Task {
      try await SystemProcessRunner().run(
        executable: "/bin/sh",
        arguments: ["-c", "echo $$ > \(Self.shellQuote(pidFile.path)); trap '' TERM; while :; do :; done"],
        standardInput: nil,
        options: ProcessExecutionOptions(timeoutSeconds: 0.2)
      )
    }
    let pid = try await Self.waitForChildPID(at: pidFile)
    await #expect(throws: GatewayError.self) {
      _ = try await task.value
    }
    #expect(Date().timeIntervalSince(started) < 3)
    #expect(!Self.isRunning(pid))
  }

  @Test("Cancelling a child process waits for cleanup and returns cancellation")
  func cancellationTerminatesChild() async throws {
    let runner = SystemProcessRunner()
    let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: pidFile) }
    let task = Task {
      try await runner.run(
        executable: "/bin/sh",
        arguments: ["-c", "echo $$ > \(Self.shellQuote(pidFile.path)); trap '' TERM; while :; do :; done"],
        standardInput: nil,
        options: ProcessExecutionOptions(timeoutSeconds: 5)
      )
    }
    let pid = try await Self.waitForChildPID(at: pidFile)
    task.cancel()
    await #expect(throws: CancellationError.self) {
      _ = try await task.value
    }
    #expect(!Self.isRunning(pid))
  }

  @Test("Timeout terminates a parent despite descendant-held output descriptors")
  func timeoutDoesNotWaitForDescendantEOF() async throws {
    let started = Date()
    await #expect(throws: GatewayError.self) {
      _ = try await SystemProcessRunner().run(
        executable: "/bin/sh",
        arguments: ["-c", "(sleep 5) & trap '' TERM; while :; do :; done"],
        standardInput: nil,
        options: ProcessExecutionOptions(timeoutSeconds: 0.05)
      )
    }
    #expect(Date().timeIntervalSince(started) < 3)
  }

  @Test("An exited child is not relabeled by a later timeout")
  func exitedChildIsNotRelabeledByTimeout() async throws {
    let result = try await SystemProcessRunner().run(
      executable: "/bin/sh",
      arguments: ["-c", "(sleep 1) & exit 0"],
      standardInput: nil,
      options: ProcessExecutionOptions(timeoutSeconds: 0.05)
    )
    #expect(result.exitCode == 0)
  }

  @Test("Output beyond the credential-process limit terminates the child")
  func excessiveOutputFailsWithoutGrowingUnbounded() async throws {
    await #expect(throws: GatewayError.self) {
      _ = try await SystemProcessRunner().run(
        executable: "/bin/sh",
        arguments: ["-c", "head -c \(SystemProcessRunner.maximumOutputBytes + 1) /dev/zero"],
        standardInput: nil,
        options: ProcessExecutionOptions(timeoutSeconds: 5)
      )
    }
  }
}
