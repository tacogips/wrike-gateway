import Foundation
import Testing
import WrikeGatewayCore
import WrikeGatewayTestSupport

/// The kinko command-line contract this package depends on.
///
/// The help text below is the verbatim flag inventory printed by
/// `kinko get --help`, `kinko set-key --help`, and `kinko delete --help` for
/// `kinko version` 0.1.8. It is the fixture the argv assertions are checked
/// against, so a store that invents a flag fails here rather than in
/// production. `KinkoInterfaceIntegrationTests` re-runs the real binary against
/// the same argv when the integration switch is set.
enum KinkoHelpFixture {
  static let version = "0.1.8"

  /// Flags accepted by every subcommand.
  static let globalFlags = """
    --config string               bootstrap config path
    --confirm                     confirm sensitive tty output (default true)
    --force                       override non-tty/redirection guardrails
    --keychain-preflight string   keychain preflight mode: required|best-effort|off
    --kinko-dir string            kinko data dir
    --path string                 path (default is the current working directory)
    --profile string              profile (default "default")
    """

  /// `kinko get KEY [flags]`
  static let getFlags = """
    -h, --help     help for get
        --reveal   show plaintext
    """

  /// `kinko set-key KEY [flags]`
  static let setKeyFlags = """
    -h, --help           help for set-key
        --shared         set key in shared scope
        --value string   set key value directly
    """

  /// `kinko delete [flags]`
  static let deleteFlags = """
        --all      delete all keys in selected scope
    -h, --help     help for delete
        --shared   delete from shared scope
    -y, --yes      auto confirm deletion
    """

  /// Every long flag documented for one subcommand, including the global set.
  static func acceptedFlags(subcommand: String) -> Set<String> {
    let specific: String
    switch subcommand {
    case "get": specific = getFlags
    case "set-key": specific = setKeyFlags
    case "delete": specific = deleteFlags
    default: specific = ""
    }
    return Set((specific + "\n" + globalFlags).split(whereSeparator: \.isWhitespace)
      .filter { $0.hasPrefix("--") }
      .map { String($0.prefix(while: { $0 != "=" })) })
  }
}

/// One recorded kinko invocation, split into its subcommand, key, and flags.
private struct ParsedInvocation {
  let subcommand: String
  let positional: [String]
  let flags: [String: String?]

  init(_ arguments: [String]) {
    var subcommand = ""
    var positional: [String] = []
    var flags: [String: String?] = [:]
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      if argument.hasPrefix("--") {
        if let separator = argument.firstIndex(of: "=") {
          flags[String(argument[argument.startIndex..<separator])] = String(argument[argument.index(after: separator)...])
        } else if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
          flags[argument] = arguments[index + 1]
          index += 1
        } else {
          flags[argument] = String?.none
        }
      } else if subcommand.isEmpty {
        subcommand = argument
      } else {
        positional.append(argument)
      }
      index += 1
    }
    self.subcommand = subcommand
    self.positional = positional
    self.flags = flags
  }

  var longFlagNames: Set<String> { Set(flags.keys) }

  func value(of flag: String) -> String? { flags[flag] ?? nil }
}

@Suite("Kinko credential-store command contract")
struct KinkoCredentialStoreContractTests {
  private static let scopePath = "/Users/fixture"
  private static let profile = "default"

  private static func store(_ runner: StubProcessRunner) -> KinkoCredentialStore {
    KinkoCredentialStore(
      runner: runner,
      executablePath: "/usr/bin/true",
      scopePath: scopePath,
      profile: profile
    )
  }

  private static func state() -> OAuthTokenState {
    OAuthTokenState(
      accessToken: SecretValue("fake-access"),
      refreshToken: SecretValue("fake-refresh"),
      expiresAt: Date(timeIntervalSince1970: 1_900_000_000),
      grantedScopes: ["wsReadOnly"],
      host: "www.wrike.com",
      clientID: SecretValue("fake-client")
    )
  }

  private static var key: CredentialRecordKey {
    CredentialRecordKey(clientID: SecretValue("fake-client"), host: "www.wrike.com")
  }

  private static func recordJSON(for state: OAuthTokenState) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    // The store writes a byte-stable record, so the expectation can be exact.
    encoder.outputFormatting = .sortedKeys
    return try encoder.encode(state)
  }

  @Test("The record name is a valid kinko environment key")
  func storageNameIsAnEnvironmentKey() {
    // kinko 0.1.8 rejects anything else with `invalid environment key "..."`.
    let name = Self.key.storageName
    #expect(name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil, "\(name)")
    #expect(name.hasPrefix("WRIKE_GATEWAY_OAUTH_"))
    #expect(!name.contains("."))
    #expect(!name.contains("-"))
  }

  @Test("Two clients and two hosts stay in separate records")
  func recordNamesStaySeparate() {
    let first = CredentialRecordKey(clientID: SecretValue("client-a"), host: "www.wrike.com")
    let second = CredentialRecordKey(clientID: SecretValue("client-b"), host: "www.wrike.com")
    let third = CredentialRecordKey(clientID: SecretValue("client-a"), host: "app-eu.wrike.com")
    #expect(first.storageName != second.storageName)
    #expect(first.storageName != third.storageName)
  }

  @Test("load reads plaintext through the non-tty guardrail with a pinned scope")
  func loadArguments() async throws {
    let payload = try Self.recordJSON(for: Self.state())
    let runner = StubProcessRunner(results: [
      ProcessResult(exitCode: 0, standardOutput: payload + Data("\n".utf8), standardError: Data())
    ])
    let loaded = try await Self.store(runner).load(Self.key)
    #expect(loaded?.host == "www.wrike.com")

    let invocation = try #require(await runner.invocations.first)
    #expect(invocation.executable == "/usr/bin/true")
    #expect(invocation.standardInput == nil)
    #expect(invocation.arguments == [
      "get", Self.key.storageName, "--reveal", "--force",
      "--path", Self.scopePath, "--profile", Self.profile
    ])
  }

  @Test("replace writes the record on stdin and never on argv")
  func replaceArguments() async throws {
    let runner = StubProcessRunner(results: [
      ProcessResult(exitCode: 0, standardOutput: Data(), standardError: Data())
    ])
    let state = Self.state()
    try await Self.store(runner).replace(state, for: Self.key)

    let invocation = try #require(await runner.invocations.first)
    #expect(invocation.arguments == [
      "set-key", Self.key.storageName, "--confirm=false",
      "--path", Self.scopePath, "--profile", Self.profile
    ])
    // The token record is passed on stdin. `--value` would publish it in the
    // process listing, where any local user can read it.
    #expect(!invocation.arguments.contains("--value"))
    let stdin = try #require(invocation.standardInput)
    let expected = try Self.recordJSON(for: state)
    #expect(stdin == expected)
    #expect(!invocation.arguments.joined().contains("fake-refresh"))
  }

  @Test("delete auto-confirms, names one key, and runs exactly one command")
  func deleteArguments() async throws {
    let runner = StubProcessRunner(results: [
      ProcessResult(exitCode: 0, standardOutput: Data("deleted\n".utf8), standardError: Data())
    ])
    #expect(try await Self.store(runner).delete(Self.key))

    let invocations = await runner.invocations
    // One invocation: `delete` reports a missing key itself, so no separate
    // existence check runs and there is no window between the two in which the
    // record can change.
    #expect(invocations.count == 1)
    let invocation = try #require(invocations.first)
    #expect(invocation.arguments == [
      "delete", Self.key.storageName, "--yes",
      "--path", Self.scopePath, "--profile", Self.profile
    ])
    #expect(!invocation.arguments.contains("--all"))
  }

  @Test("A record that does not exist is reported as a no-op by delete itself")
  func deleteSkipsWhenNoRecordExists() async throws {
    // kinko 0.1.8 answers a missing key with exit 1 and `secret not found` on
    // `delete` exactly as it does on `get`.
    let runner = StubProcessRunner(results: [
      ProcessResult(exitCode: 1, standardOutput: Data(), standardError: Data("secret not found\n".utf8))
    ])
    #expect(try await Self.store(runner).delete(Self.key) == false)

    let invocations = await runner.invocations
    #expect(invocations.count == 1)
    #expect(invocations.first?.arguments.first == "delete")
  }

  @Test("hasRecord checks existence without decrypting the record")
  func hasRecordArguments() async throws {
    let runner = StubProcessRunner(results: [
      ProcessResult(exitCode: 0, standardOutput: Data("wr***\n".utf8), standardError: Data())
    ])
    #expect(try await Self.store(runner).hasRecord(Self.key))

    let invocation = try #require(await runner.invocations.first)
    #expect(invocation.arguments == [
      "get", Self.key.storageName, "--force",
      "--path", Self.scopePath, "--profile", Self.profile
    ])
    // No `--reveal`: existence comes from the exit code, never from decrypting
    // the record.
    #expect(!invocation.arguments.contains("--reveal"))
  }

  @Test("Existence is decided by the exit code, not by kinko's masked output")
  func hasRecordIgnoresMaskedBody() async throws {
    let present = StubProcessRunner(results: [
      ProcessResult(exitCode: 0, standardOutput: Data(), standardError: Data())
    ])
    #expect(try await Self.store(present).hasRecord(Self.key))

    let absent = StubProcessRunner(results: [
      ProcessResult(exitCode: 1, standardOutput: Data(), standardError: Data("secret not found".utf8))
    ])
    #expect(try await Self.store(absent).hasRecord(Self.key) == false)
  }

  @Test("Every flag the store passes exists in the verified kinko help output")
  func flagsMatchTheVerifiedInterface() async throws {
    // Four invocations: load, replace, delete, and hasRecord.
    let runner = StubProcessRunner(results: Array(
      repeating: ProcessResult(exitCode: 0, standardOutput: Data("x".utf8), standardError: Data()),
      count: 4
    ))
    let store = Self.store(runner)
    _ = try? await store.load(Self.key)
    try? await store.replace(Self.state(), for: Self.key)
    _ = try await store.delete(Self.key)
    _ = try await store.hasRecord(Self.key)

    let invocations = await runner.invocations
    #expect(invocations.count == 4)
    for invocation in invocations {
      let parsed = ParsedInvocation(invocation.arguments)
      #expect(["get", "set-key", "delete"].contains(parsed.subcommand), "\(parsed.subcommand)")
      // Exactly one key, and never a bare subcommand that would act on the
      // whole scope.
      #expect(parsed.positional.count == 1, "\(parsed.subcommand) must name exactly one key")
      let accepted = KinkoHelpFixture.acceptedFlags(subcommand: parsed.subcommand)
      let unknown = parsed.longFlagNames.subtracting(accepted)
      #expect(
        unknown.isEmpty,
        "kinko \(KinkoHelpFixture.version) `\(parsed.subcommand)` does not accept \(unknown.sorted())"
      )
      // The scope is pinned on every call, because kinko's `--path` otherwise
      // defaults to the working directory.
      #expect(parsed.value(of: "--path") == Self.scopePath, "\(parsed.subcommand)")
      #expect(parsed.value(of: "--profile") == Self.profile, "\(parsed.subcommand)")
    }
  }

  @Test("A locked vault is reported as an actionable state, not a missing record")
  func lockedVaultIsNotAMissingRecord() async throws {
    // kinko 0.1.8 prints exactly `locked` on stderr and exits 1.
    let runner = StubProcessRunner(results: [
      ProcessResult(exitCode: 1, standardOutput: Data(), standardError: Data("locked\n".utf8))
    ])
    do {
      _ = try await Self.store(runner).load(Self.key)
      Issue.record("Expected the locked vault to surface")
    } catch let error as GatewayError {
      #expect(error.code == .fileOperationFailed)
      #expect(error.recoveryGuidance?.contains("kinko unlock") == true)
    }
  }

  @Test("A missing record loads as nil rather than failing")
  func missingRecordLoadsAsNil() async throws {
    let runner = StubProcessRunner(results: [
      ProcessResult(exitCode: 1, standardOutput: Data(), standardError: Data("secret not found\n".utf8))
    ])
    #expect(try await Self.store(runner).load(Self.key) == nil)
  }

  @Test("A masked or corrupt record is refused instead of silently ignored")
  func corruptRecordFails() async throws {
    let runner = StubProcessRunner(results: [
      ProcessResult(exitCode: 0, standardOutput: Data("wr***\n".utf8), standardError: Data())
    ])
    do {
      _ = try await Self.store(runner).load(Self.key)
      Issue.record("Expected the undecodable record to surface")
    } catch let error as GatewayError {
      #expect(error.code == .fileOperationFailed)
      #expect(error.recoveryGuidance?.contains("auth oauth2") == true)
    }
  }

  @Test("A locked vault fails the write instead of reporting a stored token")
  func lockedVaultFailsTheWrite() async throws {
    let runner = StubProcessRunner(results: [
      ProcessResult(exitCode: 1, standardOutput: Data(), standardError: Data("locked".utf8))
    ])
    do {
      try await Self.store(runner).replace(Self.state(), for: Self.key)
      Issue.record("Expected the write to fail")
    } catch let error as GatewayError {
      #expect(error.recoveryGuidance?.contains("kinko unlock") == true)
    }
  }

  /// kinko 0.1.8 does not answer an unopenable vault the same way on every
  /// path, so each subcommand is driven with the exit code and stderr that
  /// subcommand actually produces. Verified on 2026-08-05 against the
  /// operator's locked vault and against an empty `--kinko-dir`; the `locked`
  /// marker alone never reaches `delete`.
  private static let unopenableVault: [(subcommand: String, result: ProcessResult)] = [
    ("get", ProcessResult(exitCode: 1, standardOutput: Data(), standardError: Data("locked\n".utf8))),
    (
      "set-key",
      ProcessResult(exitCode: 12, standardOutput: Data(), standardError: Data("Vault mutation in progress.\n".utf8))
    ),
    (
      "delete",
      ProcessResult(exitCode: 13, standardOutput: Data(), standardError: Data("Failed to load vault.\n".utf8))
    )
  ]

  @Test("An unopenable vault fails the write on every marker that subcommand produces")
  func unopenableVaultFailsTheWrite() async throws {
    for probe in Self.unopenableVault where probe.subcommand != "delete" {
      let runner = StubProcessRunner(results: [probe.result])
      do {
        try await Self.store(runner).replace(Self.state(), for: Self.key)
        Issue.record("Expected the write to fail for the \(probe.subcommand) marker")
      } catch let error as GatewayError {
        #expect(error.code == .fileOperationFailed)
        #expect(error.recoveryGuidance?.contains("kinko unlock") == true, "\(probe.subcommand)")
        // The generic "did not accept the token record" message points at
        // `kinko doctor`, which is not the recovery for an unopened vault.
        #expect(error.recoveryGuidance?.contains("kinko doctor") != true, "\(probe.subcommand)")
      }
    }
  }

  @Test("An unopenable vault fails logout instead of reporting nothing to remove")
  func unopenableVaultFailsTheDelete() async throws {
    // `delete` answers an unopenable vault with exit 13 and
    // `Failed to load vault.`, never `locked`.
    let runner = StubProcessRunner(results: [Self.unopenableVault[2].result])
    do {
      let removed = try await Self.store(runner).delete(Self.key)
      Issue.record("Expected the unopenable vault to surface, got removed=\(removed)")
    } catch let error as GatewayError {
      #expect(error.code == .fileOperationFailed)
      #expect(error.recoveryGuidance?.contains("kinko unlock") == true)
    }
    #expect(await runner.invocations.count == 1)
  }

  /// Anything that is neither exit 0 nor the pinned `secret not found` marker
  /// is a failure. A kinko upgrade that rewords a status line, a keychain
  /// error, or a corrupt vault therefore surfaces instead of being reported as
  /// an empty store.
  private static let unrecognisedFailure = ProcessResult(
    exitCode: 7,
    standardOutput: Data(),
    standardError: Data("unexpected kinko failure\n".utf8)
  )

  @Test("A failed delete is never reported as a successful no-op")
  func failedDeleteIsNotANoOp() async throws {
    // `false` here would tell an operator running `auth logout` that there was
    // nothing to remove while the refresh token is still stored.
    let runner = StubProcessRunner(results: [Self.unrecognisedFailure])
    do {
      let removed = try await Self.store(runner).delete(Self.key)
      Issue.record("Expected the failed delete to surface, got removed=\(removed)")
    } catch let error as GatewayError {
      #expect(error.code == .fileOperationFailed)
      #expect(error.message.contains("did not remove"))
    }
  }

  @Test("An unrecognised failure is never reported as a missing record")
  func unrecognisedFailureIsNotAMissingRecord() async throws {
    // `load` returning nil would read as "no credential is configured" and send
    // the operator through a fresh login instead of naming the real fault.
    let loadRunner = StubProcessRunner(results: [Self.unrecognisedFailure])
    do {
      let loaded = try await Self.store(loadRunner).load(Self.key)
      Issue.record("Expected the failed load to surface, got \(String(describing: loaded))")
    } catch let error as GatewayError {
      #expect(error.code == .fileOperationFailed)
      #expect(error.message.contains("did not return"))
    }

    let existsRunner = StubProcessRunner(results: [Self.unrecognisedFailure])
    do {
      let exists = try await Self.store(existsRunner).hasRecord(Self.key)
      Issue.record("Expected the failed existence check to surface, got \(exists)")
    } catch let error as GatewayError {
      #expect(error.code == .fileOperationFailed)
      #expect(error.message.contains("existence check"))
    }
  }

  @Test("A missing record is decided by the pinned marker, not by any non-zero exit")
  func missingRecordRequiresTheMarker() async throws {
    // Exit 1 is shared by the missing-record marker and the locked-vault
    // marker, so the stderr line is what separates them.
    let missing = ProcessResult(
      exitCode: 1,
      standardOutput: Data(),
      standardError: Data("secret not found\n".utf8)
    )
    #expect(try await Self.store(StubProcessRunner(results: [missing])).load(Self.key) == nil)
    #expect(try await Self.store(StubProcessRunner(results: [missing])).hasRecord(Self.key) == false)
    #expect(try await Self.store(StubProcessRunner(results: [missing])).delete(Self.key) == false)

    let locked = ProcessResult(exitCode: 1, standardOutput: Data(), standardError: Data("locked\n".utf8))
    do {
      _ = try await Self.store(StubProcessRunner(results: [locked])).hasRecord(Self.key)
      Issue.record("Expected the locked vault to surface")
    } catch let error as GatewayError {
      #expect(error.recoveryGuidance?.contains("kinko unlock") == true)
    }
  }
}

@Suite("Kinko executable resolution")
struct KinkoExecutableResolverTests {
  @Test("PATH is searched before the packaged prefixes")
  func prefersPath() {
    let resolver = KinkoExecutableResolver(
      searchPath: "/nix/store/abc-kinko/bin:/usr/bin",
      isExecutable: { $0 == "/nix/store/abc-kinko/bin/kinko" || $0 == "/opt/homebrew/bin/kinko" }
    )
    #expect(resolver.resolve() == "/nix/store/abc-kinko/bin/kinko")
  }

  @Test("Both Homebrew prefixes are found when PATH is empty", arguments: [
    "/opt/homebrew/bin/kinko",
    "/usr/local/bin/kinko"
  ])
  func fallsBackToHomebrewPrefixes(installed: String) {
    let resolver = KinkoExecutableResolver(searchPath: nil, isExecutable: { $0 == installed })
    #expect(resolver.resolve() == installed)
  }

  @Test("A missing kinko is an actionable failure, not a silent no-credential state")
  func missingExecutable() async throws {
    let store = KinkoCredentialStore(
      runner: StubProcessRunner(results: []),
      resolver: KinkoExecutableResolver(searchPath: "/nowhere", isExecutable: { _ in false })
    )
    do {
      _ = try await store.load(CredentialRecordKey(clientID: SecretValue("c"), host: "www.wrike.com"))
      Issue.record("Expected the missing executable to surface")
    } catch let error as GatewayError {
      #expect(error.code == .fileOperationFailed)
      #expect(error.recoveryGuidance?.contains("/opt/homebrew/bin/kinko") == true)
      #expect(error.recoveryGuidance?.contains("/usr/local/bin/kinko") == true)
    }
  }

  @Test("The default store pins the home directory, not the working directory")
  func defaultScopeIsStable() {
    #expect(KinkoCredentialStore.defaultScopePath == NSHomeDirectory())
    #expect(KinkoCredentialStore.defaultScopePath != FileManager.default.currentDirectoryPath)
  }
}

/// Replays the store's real argv against an installed kinko.
///
/// Opt in with `WRIKE_GATEWAY_KINKO_INTEGRATION=1 swift test`. Every command is
/// pointed at an empty `--kinko-dir`, so it fails at vault load and never
/// reads, writes, or deletes anything in the operator's vault; the assertion is
/// only that kinko's argument parser accepted the command.
@Suite(
  "Kinko interface integration",
  .enabled(if: ProcessInfo.processInfo.environment["WRIKE_GATEWAY_KINKO_INTEGRATION"] == "1")
)
struct KinkoInterfaceIntegrationTests {
  /// Every contract diagnostic kinko 0.1.8 emits for an argv this store could
  /// plausibly regress into. Flag drift is only half of it: the last two
  /// entries are what a dropped key positional and a dropped stdin record body
  /// look like, and without them the suite that exists to catch argv drift
  /// would pass while `delete` acted on nothing and `set-key` wrote nothing.
  static let contractRejections = [
    "unknown flag",
    "unknown shorthand flag",
    "invalid environment key",
    "accepts at most",
    "delete requires a key or --all",
    "set-key requires --value or stdin value"
  ]

  @Test("Every store command parses against the installed kinko binary")
  func storeCommandsParse() async throws {
    let executable = try #require(
      KinkoExecutableResolver().resolve(),
      "kinko is not installed; the integration switch requires it"
    )
    let recorder = StubProcessRunner(results: Array(
      repeating: ProcessResult(exitCode: 0, standardOutput: Data("x".utf8), standardError: Data()),
      count: 4
    ))
    let store = KinkoCredentialStore(runner: recorder, executablePath: executable)
    let key = CredentialRecordKey(clientID: SecretValue("integration-probe"), host: "www.wrike.com")
    let state = OAuthTokenState(
      accessToken: SecretValue("probe"),
      refreshToken: SecretValue("probe"),
      expiresAt: Date(timeIntervalSince1970: 1_900_000_000),
      grantedScopes: [],
      host: "www.wrike.com",
      clientID: SecretValue("integration-probe")
    )
    _ = try? await store.load(key)
    try? await store.replace(state, for: key)
    _ = try? await store.delete(key)
    _ = try? await store.hasRecord(key)

    let emptyVault = FileManager.default.temporaryDirectory
      .appendingPathComponent("wrike-gateway-kinko-probe-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: emptyVault, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: emptyVault) }

    let live = SystemProcessRunner()
    for invocation in await recorder.invocations {
      let result = try await live.run(
        executable: executable,
        arguments: invocation.arguments + ["--kinko-dir", emptyVault.path],
        // `?? Data()` gives an empty, closed stdin rather than inheriting the
        // test runner's. A regression that dropped the record body would
        // otherwise leave `set-key` reading from a terminal instead of
        // reporting `set-key requires --value or stdin value`.
        standardInput: invocation.standardInput ?? Data()
      )
      let text = String(data: result.standardOutput + result.standardError, encoding: .utf8) ?? ""
      for rejection in Self.contractRejections {
        #expect(!text.contains(rejection), "kinko rejected `\(invocation.arguments.joined(separator: " "))`: \(text)")
      }
    }
    // Nothing was created in the probe vault directory.
    #expect(try FileManager.default.contentsOfDirectory(atPath: emptyVault.path).isEmpty)
  }
}
