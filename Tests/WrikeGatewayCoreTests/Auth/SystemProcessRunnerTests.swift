import Foundation
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
}
