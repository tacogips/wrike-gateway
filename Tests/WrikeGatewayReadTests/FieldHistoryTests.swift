import Foundation
import Testing
import WrikeGatewayCore
import WrikeGatewayRead
import WrikeGatewayTestSupport

/// The three field-history capabilities are the only reader routes that address
/// several entities through one path segment and the only ones that take an
/// object-valued query filter. Both encodings are asserted here rather than in
/// the shared contract harness, which checks one canonical exercise per
/// capability.
@Suite("Reader field history")
struct FieldHistoryTests {
  private func runtime(_ transport: RecordingTransport) throws -> GraphQLRuntime {
    try ReaderCases.runtime(transport: transport)
  }

  private func succeeding(kind: String, data: String) -> RecordingTransport {
    RecordingTransport.succeeding(json: WrikeFixtures.envelope(kind: kind, data: data))
  }

  @Test("Each history route addresses its entities through one comma-separated segment")
  func joinsIdentifiers() async throws {
    let transport = succeeding(kind: "tasksHistory", data: WrikeFixtures.tasksHistory)
    let runtime = try runtime(transport)

    let response = await runtime.execute(
      document: """
        { tasksHistory(ids: ["IEAAAAAAKQAB5FNY", "IEAAAAAAKQAB5FNZ", "IEAAAAAAKQAB5FN2"]) \
        { id } }
        """
    )

    #expect(response.errors.isEmpty, "\(response.errors)")
    let recorded = try await transport.firstRequest()
    #expect(
      recorded.path
        == "/api/v4/tasks/IEAAAAAAKQAB5FNY,IEAAAAAAKQAB5FNZ,IEAAAAAAKQAB5FN2/tasks_history"
    )
    // The identifiers belong in the path, never as a repeated query parameter.
    #expect(recorded.queryItems.isEmpty)
  }

  @Test("A single identifier still produces a well-formed segment")
  func acceptsOneIdentifier() async throws {
    let transport = succeeding(kind: "contactsHistory", data: WrikeFixtures.contactsHistory)
    let runtime = try runtime(transport)

    _ = await runtime.execute(document: "{ contactsHistory(ids: [\"KUAAAAAA\"]) { id } }")

    #expect(try await transport.firstRequest().path == "/api/v4/contacts/KUAAAAAA/contacts_history")
  }

  @Test("An empty identifier list is rejected before transport")
  func rejectsEmptyIdentifierList() async throws {
    let transport = succeeding(kind: "tasksHistory", data: WrikeFixtures.tasksHistory)
    let runtime = try runtime(transport)

    let response = await runtime.execute(document: "{ tasksHistory(ids: []) { id } }")

    #expect(response.errors.first?.code == .validationError)
    // An empty segment would otherwise produce `/tasks//tasks_history`.
    #expect(await transport.requestCount == 0)
  }

  @Test("More identifiers than Wrike accepts are rejected before transport")
  func rejectsOversizedIdentifierList() async throws {
    let transport = succeeding(kind: "tasksHistory", data: WrikeFixtures.tasksHistory)
    let runtime = try runtime(transport)
    let overLimit = HistoryModels.maximumIdentifiers + 1
    let ids = (0..<overLimit)
      .map { "\"IEAAAAAAKQAB5F\(String(format: "%02d", $0 % 100))\"" }
      .joined(separator: ", ")

    let response = await runtime.execute(document: "{ tasksHistory(ids: [\(ids)]) { id } }")

    let error = try #require(response.errors.first)
    #expect(error.code == .validationError)
    #expect(error.message.contains("\(HistoryModels.maximumIdentifiers)"))
    #expect(await transport.requestCount == 0)
  }

  @Test("Exactly the documented maximum is accepted")
  func acceptsTheDocumentedMaximum() async throws {
    let transport = succeeding(kind: "tasksHistory", data: WrikeFixtures.tasksHistory)
    let runtime = try runtime(transport)
    let ids = (0..<HistoryModels.maximumIdentifiers)
      .map { "\"IEAAAAAAKQAB5F\(String(format: "%02d", $0 % 100))\"" }
      .joined(separator: ", ")

    let response = await runtime.execute(document: "{ tasksHistory(ids: [\(ids)]) { id } }")

    #expect(response.errors.isEmpty, "\(response.errors)")
    #expect(await transport.requestCount == 1)
  }

  @Test("An updatedDate range is sent as one JSON query parameter")
  func encodesInstantRange() async throws {
    let transport = succeeding(kind: "foldersHistory", data: WrikeFixtures.foldersHistory)
    let runtime = try runtime(transport)

    _ = await runtime.execute(
      document: """
        { foldersHistory(ids: ["IEAAAAAAI4AB5FNY"], updatedDate: \
        {start: "2026-01-01T00:00:00Z", end: "2026-06-30T00:00:00Z"}) { id } }
        """
    )

    let recorded = try await transport.firstRequest()
    #expect(
      recorded.query["updatedDate"]
        == "{\"end\":\"2026-06-30T00:00:00Z\",\"start\":\"2026-01-01T00:00:00Z\"}"
    )
    #expect(recorded.queryItems.count == 1, "the range must not expand into separate parameters")
  }

  @Test("An updatedDate with no bound carries no filter and is dropped")
  func dropsEmptyInstantRange() async throws {
    let transport = succeeding(kind: "foldersHistory", data: WrikeFixtures.foldersHistory)
    let runtime = try runtime(transport)

    _ = await runtime.execute(
      document: "{ foldersHistory(ids: [\"IEAAAAAAI4AB5FNY\"], updatedDate: {}) { id } }"
    )

    // Sending `updatedDate={}` would be a filter Wrike has to interpret; an
    // absent filter is unambiguous.
    #expect(try await transport.firstRequest().queryItems.isEmpty)
  }

  @Test("A field value the resource does not accept is rejected locally by name")
  func rejectsUnacceptedField() async throws {
    let transport = succeeding(kind: "tasksHistory", data: WrikeFixtures.tasksHistory)
    let runtime = try runtime(transport)

    // `budget` is a folder metric; tasks do not carry it.
    let response = await runtime.execute(
      document: "{ tasksHistory(ids: [\"IEAAAAAAKQAB5FNY\"], fields: [\"budget\"]) { id } }"
    )

    let error = try #require(response.errors.first)
    #expect(error.code == .validationError)
    #expect(error.message.contains("plannedCost"), "the error must name the accepted fields")
    #expect(await transport.requestCount == 0)
  }

  @Test("The same field value is accepted where the resource does carry it")
  func acceptsResourceSpecificField() async throws {
    let transport = succeeding(kind: "foldersHistory", data: WrikeFixtures.foldersHistory)
    let runtime = try runtime(transport)

    let response = await runtime.execute(
      document: "{ foldersHistory(ids: [\"IEAAAAAAI4AB5FNY\"], fields: [\"budget\"]) { id } }"
    )

    #expect(response.errors.isEmpty, "\(response.errors)")
  }

  @Test("Each resource publishes exactly the reviewed field set")
  func publishesReviewedFieldSets() {
    #expect(ContactCapabilities.historyFields == ["billRate", "costRate"])
    #expect(
      FolderCapabilities.historyFields
        == ["plannedCost", "plannedFees", "actualCost", "actualFees", "budget"]
    )
    #expect(
      TaskCapabilities.historyFields
        == ["plannedCost", "plannedFees", "actualCost", "actualFees"]
    )
  }

  @Test("A contact history projects both rate collections")
  func projectsContactRates() async throws {
    let transport = succeeding(kind: "contactsHistory", data: WrikeFixtures.contactsHistory)
    let runtime = try runtime(transport)

    let response = await runtime.execute(
      document: """
        { contactsHistory(ids: ["KUAAAAAA"]) \
        { id billRateHistory { rateValue startDate endDate rateSource } \
        costRateHistory { rateValue } } }
        """
    )

    #expect(response.errors.isEmpty, "\(response.errors)")
    let entries = try #require(response.data?["contactsHistory"]?.arrayValue)
    let first = try #require(entries.first)
    #expect(first["billRateHistory"]?.arrayValue?.first?["rateValue"]?.doubleValue == 120.0)
    #expect(first["billRateHistory"]?.arrayValue?.first?["rateSource"]?.stringValue == "JobRole")
    #expect(first["costRateHistory"]?.arrayValue?.first?["rateValue"]?.doubleValue == 80.0)
  }

  @Test("A folder history keeps its metrics under project, unlike a task history")
  func projectsFolderMetricsUnderProject() async throws {
    let folders = succeeding(kind: "foldersHistory", data: WrikeFixtures.foldersHistory)
    let folderResponse = await (try runtime(folders)).execute(
      document: """
        { foldersHistory(ids: ["IEAAAAAAI4AB5FNY"]) \
        { id project { budget { value startDate endDate } } } }
        """
    )
    #expect(folderResponse.errors.isEmpty, "\(folderResponse.errors)")
    let folder = try #require(folderResponse.data?["foldersHistory"]?.arrayValue?.first)
    #expect(folder["project"]?["budget"]?.arrayValue?.first?["value"]?.doubleValue == 5000.0)

    // The same nesting must not be accepted for tasks.
    let tasks = succeeding(kind: "tasksHistory", data: WrikeFixtures.tasksHistory)
    let taskResponse = await (try runtime(tasks)).execute(
      document: "{ tasksHistory(ids: [\"IEAAAAAAKQAB5FNY\"]) { id project { budget { value } } } }"
    )
    #expect(taskResponse.errors.first?.code == .validationError)
  }

  @Test("A budget metric without its required window is an upstream contract violation")
  func rejectsMetricWithoutWindow() async throws {
    let transport = succeeding(
      kind: "tasksHistory",
      data: "{\"id\":\"IEAAAAAAKQAB5FNY\",\"plannedCost\":[{\"value\":250.0}]}"
    )
    let runtime = try runtime(transport)

    let response = await runtime.execute(
      document: "{ tasksHistory(ids: [\"IEAAAAAAKQAB5FNY\"]) { id plannedCost { value } } }"
    )

    #expect(response.errors.first?.code == .upstreamResponseInvalid)
  }

  @Test("Every history capability is a GET-backed read that writes no local file")
  func historyCapabilitiesStayReadOnly() {
    for definition in [
      ContactCapabilities.history,
      FolderCapabilities.history,
      TaskCapabilities.history
    ] {
      #expect(definition.method == .get, "\(definition.id)")
      #expect(definition.operationClass == .read, "\(definition.id)")
      #expect(definition.tier == .reader, "\(definition.id)")
      #expect(!definition.result.isFileOutput, "\(definition.id)")
      #expect(definition.coherenceProblems().isEmpty, "\(definition.id)")
    }
  }
}
