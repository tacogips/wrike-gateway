import Foundation
import Testing
import WrikeGatewayCore

/// A destination path and a file result are two halves of one contract, and the
/// registry refuses to build if a registration holds only one half. Because the
/// registry is constructed at binary startup, a mis-declared capability cannot
/// ship: it fails before the first command runs, not at the first download.
@Suite("File output registration contract")
struct FileOutputContractTests {
  private func definition(
    id: String = "widgets.download",
    field: String = "downloadWidget",
    tier: CapabilityTier = .reader,
    operationClass: OperationClass = .read,
    method: HTTPMethod = .get,
    arguments: [ArgumentDefinition],
    result: ResultShape
  ) -> CapabilityDefinition {
    CapabilityDefinition(
      id: CapabilityID(id),
      field: field,
      tier: tier,
      operationClass: operationClass,
      method: method,
      pathTemplate: "/widgets/{widgetId}/download",
      arguments: arguments,
      result: result,
      scopes: .workspaceRead,
      summary: "Downloads a widget."
    )
  }

  private let identifier = ArgumentDefinition(
    "id",
    .identifier,
    .path("widgetId"),
    required: true
  )

  @Test("A well-formed file-output capability registers")
  func acceptsAWellFormedRegistration() throws {
    let valid = definition(
      arguments: [
        identifier,
        ArgumentDefinition("destination", .string, .destinationPath, required: true)
      ],
      result: .fileOutput(FileOutputShape.shape)
    )
    #expect(valid.coherenceProblems().isEmpty)
    #expect(throws: Never.self) {
      _ = try CapabilityRegistry(tier: .reader, definitions: [valid])
    }
  }

  @Test("A file result without a destination argument is rejected")
  func rejectsFileResultWithoutDestination() {
    let invalid = definition(
      arguments: [identifier],
      result: .fileOutput(FileOutputShape.shape)
    )
    #expect(!invalid.coherenceProblems().isEmpty)
    #expect(throws: GatewayError.self) {
      _ = try CapabilityRegistry(tier: .reader, definitions: [invalid])
    }
  }

  @Test("A destination argument without a file result is rejected")
  func rejectsDestinationWithoutFileResult() {
    // This is the dangerous half: the request would select a file sink and
    // write bytes the caller never asked to receive.
    let invalid = definition(
      arguments: [
        identifier,
        ArgumentDefinition("destination", .string, .destinationPath, required: true)
      ],
      result: .single(FileOutputShape.shape)
    )
    #expect(!invalid.coherenceProblems().isEmpty)
    #expect(throws: GatewayError.self) {
      _ = try CapabilityRegistry(tier: .reader, definitions: [invalid])
    }
  }

  @Test("An optional destination argument is rejected")
  func rejectsOptionalDestination() {
    let invalid = definition(
      arguments: [
        identifier,
        ArgumentDefinition("destination", .string, .destinationPath)
      ],
      result: .fileOutput(FileOutputShape.shape)
    )
    #expect(!invalid.coherenceProblems().isEmpty)
  }

  @Test("Two destination arguments are rejected")
  func rejectsTwoDestinations() {
    let invalid = definition(
      arguments: [
        identifier,
        ArgumentDefinition("destination", .string, .destinationPath, required: true),
        ArgumentDefinition("second", .string, .destinationPath, required: true)
      ],
      result: .fileOutput(FileOutputShape.shape)
    )
    #expect(!invalid.coherenceProblems().isEmpty)
  }

  @Test("A mutation may not write a local file")
  func rejectsMutationFileOutput() {
    let invalid = definition(
      id: "widgets.create",
      field: "createWidget",
      tier: .writer,
      operationClass: .create,
      method: .post,
      arguments: [
        identifier,
        ArgumentDefinition("destination", .string, .destinationPath, required: true)
      ],
      result: .fileOutput(FileOutputShape.shape)
    )
    #expect(!invalid.coherenceProblems().isEmpty)
    #expect(throws: GatewayError.self) {
      _ = try CapabilityRegistry(tier: .writer, definitions: [invalid])
    }
  }
}
