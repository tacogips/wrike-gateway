import Foundation
import Testing
import WrikeGatewayAdmin
import WrikeGatewayCore
import WrikeGatewayRead
import WrikeGatewayWrite

/// Locates and runs the built executables.
///
/// `WrikeGatewayCLITests` depends on the three executable targets, so
/// `swift test` builds them before these tests run.
enum BuiltProducts {
  static let reader = "wrike-gateway-reader"
  static let writer = "wrike-gateway-writer"
  static let admin = "wrike-gateway-admin"
  static let all = [reader, writer, admin]

  /// The package root, derived from this file's location.
  static var packageRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  /// The build directory holding the executables, preferring the most recently
  /// written configuration so `swift test -c release` also works.
  static func binaryURL(_ name: String) throws -> URL {
    let candidates = ["debug", "release"].map {
      packageRoot.appendingPathComponent(".build/\($0)/\(name)")
    }
    let existing = candidates.filter { FileManager.default.isExecutableFile(atPath: $0.path) }
    guard !existing.isEmpty else {
      throw CLITestError.binaryNotFound(name)
    }
    return existing.max { lhs, rhs in
      modificationDate(lhs) < modificationDate(rhs)
    } ?? existing[0]
  }

  private static func modificationDate(_ url: URL) -> Date {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes?[.modificationDate] as? Date) ?? .distantPast
  }

  struct RunResult {
    let standardOutput: String
    let standardError: String
    let exitCode: Int32
  }

  /// Runs a built binary with a deliberately empty credential environment so no
  /// developer machine's real credentials can influence a test.
  static func run(_ name: String, _ arguments: [String]) throws -> RunResult {
    let process = Process()
    process.executableURL = try binaryURL(name)
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    for key in GatewayEnvironmentKey.allCases {
      environment.removeValue(forKey: key.rawValue)
    }
    process.environment = environment

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    try process.run()

    let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
    let errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    return RunResult(
      standardOutput: String(data: output, encoding: .utf8) ?? "",
      standardError: String(data: errorOutput, encoding: .utf8) ?? "",
      exitCode: process.terminationStatus
    )
  }

  /// Reads the mangled Swift symbol names linked into a binary.
  static func linkedSymbols(_ name: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/nm")
    process.arguments = ["-a", try binaryURL(name).path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
  }
}

enum CLITestError: Error, CustomStringConvertible {
  case binaryNotFound(String)

  var description: String {
    switch self {
    case .binaryNotFound(let name):
      return "The \(name) executable was not found under .build. Run `swift build` first."
    }
  }
}

@Suite("Executable link boundaries")
struct ExecutableLinkBoundaryTests {
  /// Swift mangles module names into symbol names, so a module's absence from
  /// the symbol table proves it was not linked into the binary.
  @Test("The reader binary links neither the write nor the admin module")
  func readerExcludesHigherTiers() throws {
    let symbols = try BuiltProducts.linkedSymbols(BuiltProducts.reader)
    #expect(symbols.contains("WrikeGatewayRead"), "Sanity check: the read module must be linked")
    #expect(!symbols.contains("WrikeGatewayWrite"), "Reader must not link WrikeGatewayWrite")
    #expect(!symbols.contains("WrikeGatewayAdmin"), "Reader must not link WrikeGatewayAdmin")
  }

  @Test("The writer binary links the write module but not the admin module")
  func writerExcludesAdmin() throws {
    let symbols = try BuiltProducts.linkedSymbols(BuiltProducts.writer)
    #expect(symbols.contains("WrikeGatewayWrite"), "Sanity check: the write module must be linked")
    #expect(!symbols.contains("WrikeGatewayAdmin"), "Writer must not link WrikeGatewayAdmin")
  }

  @Test("Only the admin binary links the admin module")
  func adminLinksAdmin() throws {
    let symbols = try BuiltProducts.linkedSymbols(BuiltProducts.admin)
    #expect(symbols.contains("WrikeGatewayAdmin"))
  }

  @Test("No binary links the test-support module")
  func noTestSupportInProduction() throws {
    for name in BuiltProducts.all {
      let symbols = try BuiltProducts.linkedSymbols(name)
      #expect(!symbols.contains("WrikeGatewayTestSupport"), "\(name) must not link test support")
      #expect(!symbols.contains("RecordingTransport"), "\(name) must not link a mock transport")
      #expect(!symbols.contains("LoopbackHTTPServer"), "\(name) must not link a mock server")
    }
  }

  @Test("The manifest declares the same tier boundaries the binaries enforce")
  func manifestDeclaresBoundaries() throws {
    let manifest = try String(
      contentsOf: BuiltProducts.packageRoot.appendingPathComponent("Package.swift"),
      encoding: .utf8
    )

    func dependencies(ofTarget name: String) throws -> String {
      guard let range = manifest.range(of: "name: \"\(name)\"") else {
        throw CLITestError.binaryNotFound(name)
      }
      let remainder = manifest[range.upperBound...]
      guard let close = remainder.range(of: "]") else { return "" }
      return String(remainder[remainder.startIndex..<close.lowerBound])
    }

    let reader = try dependencies(ofTarget: "WrikeGatewayReaderCLI")
    #expect(reader.contains("WrikeGatewayRead"))
    #expect(!reader.contains("WrikeGatewayWrite"))
    #expect(!reader.contains("WrikeGatewayAdmin"))

    let writer = try dependencies(ofTarget: "WrikeGatewayWriterCLI")
    #expect(writer.contains("WrikeGatewayWrite"))
    #expect(!writer.contains("WrikeGatewayAdmin"))

    let admin = try dependencies(ofTarget: "WrikeGatewayAdminCLI")
    #expect(admin.contains("WrikeGatewayAdmin"))
  }
}

/// A minimal reader over a printed SDL document, used to prove the schema is
/// self-contained. It only needs to find type names, so it works line by line
/// rather than parsing GraphQL.
enum SchemaDocument {
  /// Names introduced by a `type X`, `input X`, or `enum X` block header.
  static func definedTypeNames(in document: String) -> [String] {
    document.components(separatedBy: "\n").compactMap { line in
      let parts = line.split(separator: " ")
      guard parts.count >= 2, ["type", "input", "enum"].contains(String(parts[0])) else {
        return nil
      }
      return String(parts[1].prefix { $0 != "{" })
    }
  }

  /// Names used in a field's type position or an argument's type position.
  /// Documentation lines are skipped so prose cannot be mistaken for a type.
  static func referencedTypeNames(in document: String) -> [String] {
    var names: [String] = []
    for line in document.components(separatedBy: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard !trimmed.hasPrefix("#"), !trimmed.hasPrefix("\"\"\""),
            let colon = trimmed.firstIndex(of: ":")
      else {
        continue
      }
      // Everything after the first colon is type syntax: names, brackets,
      // exclamation marks, commas, and argument names before their own colons.
      let tail = trimmed[trimmed.index(after: colon)...]
      names.append(contentsOf: typeNames(in: String(tail)))
    }
    return names
  }

  private static func typeNames(in text: String) -> [String] {
    var names: [String] = []
    var current = ""
    var isArgumentName = false
    for character in text {
      if character.isLetter || character.isNumber || character == "_" {
        current.append(character)
        continue
      }
      // A `name:` inside an argument list is an argument, not a type.
      isArgumentName = character == ":"
      if !current.isEmpty, !isArgumentName, current.first?.isUppercase == true {
        names.append(current)
      }
      current = ""
    }
    if !current.isEmpty, current.first?.isUppercase == true {
      names.append(current)
    }
    return names
  }
}

@Suite("Cross-tier schema and help")
struct CrossTierSchemaTests {
  @Test("Each binary prints only its linked tier's schema")
  func schemasMatchTiers() throws {
    let reader = try BuiltProducts.run(BuiltProducts.reader, ["graphql", "schema"])
    let writer = try BuiltProducts.run(BuiltProducts.writer, ["graphql", "schema"])
    let admin = try BuiltProducts.run(BuiltProducts.admin, ["graphql", "schema"])

    for result in [reader, writer, admin] {
      #expect(result.exitCode == 0)
      #expect(result.standardError.isEmpty)
      #expect(result.standardOutput.contains("type Query {"))
    }

    #expect(!reader.standardOutput.contains("type Mutation {"), "Reader has no mutations")
    #expect(writer.standardOutput.contains("type Mutation {"))
    #expect(admin.standardOutput.contains("type Mutation {"))

    for field in CapabilityCatalog.writerMutationFields {
      #expect(!reader.standardOutput.contains("\(field)("), "Reader exposes \(field)")
      #expect(writer.standardOutput.contains("\(field)("), "Writer is missing \(field)")
      #expect(admin.standardOutput.contains("\(field)("), "Admin is missing \(field)")
    }
    for field in CapabilityCatalog.adminMutationFields {
      #expect(!reader.standardOutput.contains("\(field)("), "Reader exposes \(field)")
      #expect(!writer.standardOutput.contains("\(field)("), "Writer exposes \(field)")
      #expect(admin.standardOutput.contains("\(field)("), "Admin is missing \(field)")
    }
    #expect(!writer.standardOutput.contains("DeletionPayload"))
    #expect(admin.standardOutput.contains("DeletionPayload"))
  }

  @Test("Tiers are cumulative: every reader query field appears in all three schemas")
  func cumulativeQueryFields() throws {
    let schemas = try BuiltProducts.all.map {
      try BuiltProducts.run($0, ["graphql", "schema"]).standardOutput
    }
    for definition in try ReadCapabilities.registry().queryDefinitions {
      for (index, schema) in schemas.enumerated() {
        #expect(
          schema.contains("Capability: \(definition.id.rawValue)"),
          "\(BuiltProducts.all[index]) is missing \(definition.id)"
        )
      }
    }
  }

  @Test("The printed schema matches the linked capability metadata exactly")
  func schemaMatchesMetadata() throws {
    let expected: [(String, CapabilityRegistry)] = [
      (BuiltProducts.reader, try ReadCapabilities.registry()),
      (BuiltProducts.writer, try WriteCapabilities.registry()),
      (BuiltProducts.admin, try AdminCapabilities.registry())
    ]
    for (name, registry) in expected {
      let printed = try BuiltProducts.run(name, ["graphql", "schema"]).standardOutput
      #expect(printed == GraphQLSchemaPrinter(registry: registry).print(), "\(name)")
      for definition in registry.definitions {
        #expect(printed.contains("Capability: \(definition.id.rawValue)"), "\(name) \(definition.id)")
      }
    }
  }

  /// A printed schema that names a type it never defines is not a usable
  /// document, and matching the printer against itself cannot detect that: both
  /// sides would be equally wrong. This walks every type reference instead.
  @Test("Every type named in a printed schema is defined in the same document")
  func schemaDefinesEveryTypeItNames() throws {
    let builtInScalars: Set<String> = ["ID", "String", "Int", "Float", "Boolean"]
    for name in BuiltProducts.all {
      let printed = try BuiltProducts.run(name, ["graphql", "schema"]).standardOutput
      let defined = Set(SchemaDocument.definedTypeNames(in: printed))
      let referenced = Set(SchemaDocument.referencedTypeNames(in: printed))
      let undefined = referenced.subtracting(defined).subtracting(builtInScalars)
      #expect(undefined.isEmpty, "\(name) names undefined types: \(undefined.sorted())")
      #expect(defined.contains("Query"), "\(name)")
    }
  }

  @Test("Help names only the commands linked into each binary")
  func helpIsTierScoped() throws {
    for name in BuiltProducts.all {
      let result = try BuiltProducts.run(name, ["--help"])
      #expect(result.exitCode == 0, "\(name)")
      #expect(result.standardOutput.contains("Usage: \(name)"), "\(name)")
      #expect(result.standardOutput.contains("graphql query"), "\(name)")
      #expect(result.standardOutput.contains("auth oauth2"), "\(name)")
      for key in GatewayEnvironmentKey.allCases {
        #expect(result.standardOutput.contains(key.rawValue), "\(name) \(key.rawValue)")
      }
    }

    let reader = try BuiltProducts.run(BuiltProducts.reader, ["--help"]).standardOutput
    #expect(reader.contains("Capability tier: reader"))
    #expect(reader.contains("Mutation fields: none (this binary is read-only)"))

    let writer = try BuiltProducts.run(BuiltProducts.writer, ["--help"]).standardOutput
    #expect(writer.contains("Capability tier: writer"))
    #expect(writer.contains("(0 destructive)"))

    let admin = try BuiltProducts.run(BuiltProducts.admin, ["--help"]).standardOutput
    #expect(admin.contains("Capability tier: admin"))
    #expect(admin.contains("(9 destructive)"))
  }

  @Test("Running a binary with no arguments prints its help and exits 0")
  func noArgumentsPrintsHelp() throws {
    for name in BuiltProducts.all {
      let result = try BuiltProducts.run(name, [])
      #expect(result.exitCode == 0, "\(name)")
      #expect(result.standardOutput.contains("Usage: \(name)"), "\(name)")
    }
  }

  @Test("--version prints a single semantic version line")
  func versionIsSingleLine() throws {
    for name in BuiltProducts.all {
      let result = try BuiltProducts.run(name, ["--version"])
      #expect(result.exitCode == 0, "\(name)")
      let lines = result.standardOutput.split(separator: "\n")
      #expect(lines.count == 1, "\(name)")
      #expect(lines.first == "0.1.0", "\(name)")
    }
  }
}

@Suite("Executable capability boundaries at runtime")
struct ExecutableRuntimeBoundaryTests {
  @Test("The reader refuses a write mutation with CAPABILITY_DENIED and exit 2")
  func readerRefusesWrite() throws {
    let result = try BuiltProducts.run(BuiltProducts.reader, [
      "graphql", "query",
      "mutation { createTask(input: {folderId: \"IEAAAAAAI4\", title: \"X\"}) { task { id } } }"
    ])
    #expect(result.exitCode == 2)
    #expect(result.standardOutput.contains("CAPABILITY_DENIED"))
    #expect(result.standardOutput.contains("\"requiredTier\":\"writer\""))
  }

  @Test("The reader refuses a delete mutation and names the admin tier")
  func readerRefusesDelete() throws {
    let result = try BuiltProducts.run(BuiltProducts.reader, [
      "graphql", "query",
      "mutation { deleteTask(input: {taskId: \"IEAAAAAAKQAB5FNY\"}) { deletedId } }"
    ])
    #expect(result.exitCode == 2)
    #expect(result.standardOutput.contains("CAPABILITY_DENIED"))
    #expect(result.standardOutput.contains("\"requiredTier\":\"admin\""))
  }

  @Test("The writer refuses a delete mutation and names the admin tier")
  func writerRefusesDelete() throws {
    for field in CapabilityCatalog.adminMutationFields {
      let result = try BuiltProducts.run(BuiltProducts.writer, [
        "graphql", "query",
        "mutation { \(field)(input: {taskId: \"IEAAAAAAKQAB5FNY\"}) { deletedId } }"
      ])
      #expect(result.exitCode == 2, "\(field)")
      #expect(result.standardOutput.contains("CAPABILITY_DENIED"), "\(field)")
      #expect(result.standardOutput.contains("\"requiredTier\":\"admin\""), "\(field)")
    }
  }

  @Test("No binary accepts a mock, fixture, host, or credential override")
  func noProductionTestHooks() throws {
    for name in BuiltProducts.all {
      for flag in CommandParser.forbiddenFlags {
        let result = try BuiltProducts.run(name, ["graphql", "schema", flag, "value"])
        #expect(result.exitCode == 2, "\(name) accepted \(flag)")
        #expect(result.standardError.contains(flag), "\(name) \(flag)")
      }
    }
  }

  @Test("A local validation error exits 2 before any credential is required")
  func validationBeforeCredentials() throws {
    let result = try BuiltProducts.run(BuiltProducts.reader, [
      "graphql", "query", "{ task(id: \"1\") { notAField } }"
    ])
    #expect(result.exitCode == 2)
    #expect(result.standardOutput.contains("VALIDATION_ERROR"))
    // The failure is local, so no credential error appears.
    #expect(!result.standardOutput.contains("AUTHENTICATION_FAILED"))
  }

  @Test("A missing credential exits 3 with safe guidance")
  func missingCredentialExitsThree() throws {
    let result = try BuiltProducts.run(BuiltProducts.reader, [
      "graphql", "query", "{ account { id } }"
    ])
    #expect(result.exitCode == 3)
    #expect(result.standardOutput.contains("AUTHENTICATION_FAILED"))
    #expect(result.standardOutput.contains("WRIKE_GATEWAY_ACCESS_TOKEN"))
  }

  @Test("auth status reports safe metadata only and never a token")
  func authStatusIsSafe() throws {
    for name in BuiltProducts.all {
      let result = try BuiltProducts.run(name, ["auth", "status"])
      #expect(result.exitCode == 0, "\(name)")
      #expect(result.standardOutput.contains("\"clientConfigured\":false"), "\(name)")
      #expect(result.standardOutput.contains("\"callbackIdentityAvailable\""), "\(name)")
      let lowered = result.standardOutput.lowercased()
      #expect(!lowered.contains("token\":\""), "\(name)")
      #expect(!lowered.contains("secret"), "\(name)")
      #expect(!lowered.contains("certificate"), "\(name)")
    }
  }

  @Test("Business JSON goes to stdout and usage diagnostics go to stderr")
  func streamSeparation() throws {
    let business = try BuiltProducts.run(BuiltProducts.reader, [
      "graphql", "query", "{ account { notAField } }"
    ])
    #expect(!business.standardOutput.isEmpty)
    #expect(business.standardError.isEmpty, "A GraphQL error envelope belongs on stdout")

    let usage = try BuiltProducts.run(BuiltProducts.reader, ["nonsense"])
    #expect(usage.standardOutput.isEmpty)
    #expect(usage.standardError.contains("Unknown command"))
    #expect(usage.exitCode == 2)
  }

  @Test("--pretty changes whitespace only")
  func prettyChangesWhitespaceOnly() throws {
    let compact = try BuiltProducts.run(BuiltProducts.reader, [
      "graphql", "query", "{ account { notAField } }"
    ]).standardOutput
    let pretty = try BuiltProducts.run(BuiltProducts.reader, [
      "--pretty", "graphql", "query", "{ account { notAField } }"
    ]).standardOutput

    #expect(pretty.contains("\n  "))
    // Each invocation mints its own request id, so it is normalized away before
    // comparing; everything else must be byte-identical apart from whitespace.
    #expect(
      Self.normalized(pretty) == Self.normalized(compact),
      "pretty=\(Self.normalized(pretty)) compact=\(Self.normalized(compact))"
    )
  }

  private static func normalized(_ output: String) -> String {
    let stripped = output.filter { !$0.isWhitespace }
    guard let range = stripped.range(of: "\"requestId\":\"") else { return stripped }
    guard let end = stripped[range.upperBound...].firstIndex(of: "\"") else { return stripped }
    return stripped.replacingCharacters(in: range.upperBound..<end, with: "REQUEST-ID")
  }
}
