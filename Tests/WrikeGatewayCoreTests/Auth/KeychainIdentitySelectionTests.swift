import Foundation
import Security
import Testing

@testable import WrikeGatewayCore

/// Regression cover for the production Keychain identity selection.
///
/// A `kSecClassIdentity` query against a file-based login Keychain silently
/// ignores `kSecAttrLabel` and `kSecAttrApplicationLabel`: it returns every
/// identity the user holds regardless of the filter, and it does not return
/// `kSecAttrApplicationLabel` at all. The loader therefore applies the label
/// match itself. These cases exercise that selection over the attribute
/// dictionaries the Keychain would have handed back, so no provisioned
/// Keychain and no live credential is required.
@Suite("Keychain callback identity selection")
struct KeychainIdentitySelectionTests {
  private let label = WrikeOAuthEndpoints.callbackIdentityLabel

  /// The dictionaries an unfiltered query returns on a developer machine: the
  /// provisioned callback identity alongside unrelated signing identities.
  private func keychainContents() -> [[String: Any]] {
    [
      ["labl": "rolandcloud.com"],
      ["labl": "Developer ID Application: Example Developer (TEAMID1234)"],
      ["labl": "Apple Development: Example Developer (TEAMID5678)"],
      ["labl": label],
      ["labl": "Apple Distribution: Example Developer (TEAMID1234)"]
    ].map { entry in
      [kSecAttrLabel as String: entry["labl"] as Any]
    }
  }

  @Test("Only the labelled identity is selected out of a populated Keychain")
  func selectsSolelyTheLabelledIdentity() {
    let matches = KeychainTLSIdentityLoader.matchingItems(
      in: keychainContents(),
      labelled: label
    )
    #expect(matches.count == 1)
    #expect(matches.first?[kSecAttrLabel as String] as? String == label)
  }

  @Test("An unprovisioned Keychain yields no match rather than every identity")
  func unprovisionedKeychainYieldsNoMatch() {
    let withoutCallbackIdentity = keychainContents().filter {
      $0[kSecAttrLabel as String] as? String != label
    }
    let matches = KeychainTLSIdentityLoader.matchingItems(
      in: withoutCallbackIdentity,
      labelled: label
    )
    #expect(
      matches.isEmpty,
      "Four unrelated signing identities must not stand in for the callback identity"
    )
  }

  @Test("A label that matches nothing selects nothing")
  func unknownLabelSelectsNothing() {
    let matches = KeychainTLSIdentityLoader.matchingItems(
      in: keychainContents(),
      labelled: "no-such-label.example"
    )
    #expect(matches.isEmpty)
  }

  @Test("Two identities sharing the label are reported rather than silently picked")
  func duplicateLabelIsVisibleToTheCaller() {
    var contents = keychainContents()
    contents.append([kSecAttrLabel as String: label])
    let matches = KeychainTLSIdentityLoader.matchingItems(in: contents, labelled: label)
    #expect(matches.count == 2, "The loader must see both so it can refuse an ambiguous identity")
  }

  @Test("A labelled entry carrying no identity reference is dropped")
  func entryWithoutIdentityReferenceIsDropped() {
    let identities = KeychainTLSIdentityLoader.identities(
      in: keychainContents(),
      labelled: label
    )
    #expect(identities.isEmpty, "An attribute-only dictionary carries no usable identity")
  }

  @Test("A labelled entry whose reference is not an identity is dropped")
  func entryWithForeignReferenceIsDropped() {
    let contents: [[String: Any]] = [
      [
        kSecAttrLabel as String: label,
        kSecValueRef as String: "not-an-identity" as CFString
      ]
    ]
    let identities = KeychainTLSIdentityLoader.identities(in: contents, labelled: label)
    #expect(identities.isEmpty)
  }

  @Test("Selection reads the label attribute the Keychain actually returns")
  func selectionUsesReturnedLabelAttribute() {
    // `kSecAttrApplicationLabel` is absent from identity results, so a loader
    // keyed on it can never match. Guard against a regression back to it.
    let applicationLabelOnly: [[String: Any]] = [
      [kSecAttrApplicationLabel as String: Data(label.utf8)]
    ]
    #expect(
      KeychainTLSIdentityLoader.matchingItems(in: applicationLabelOnly, labelled: label).isEmpty
    )
  }
}
