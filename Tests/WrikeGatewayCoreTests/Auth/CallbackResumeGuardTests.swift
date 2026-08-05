import Foundation
import Testing
@testable import WrikeGatewayCore

/// The OAuth callback listener bridges two independent Network.framework
/// callbacks - a listener state change and a connection result - into one
/// checked continuation. Resuming a checked continuation twice traps, so the
/// guard has to be a single atomic claim rather than a check followed by a set.
///
/// `LockedBox` is deliberately internal: it is an implementation detail of the
/// listener, not part of the SDK contract, so this is the one test file that
/// imports the module with `@testable`.
@Suite("Callback single-resume guard")
struct CallbackResumeGuardTests {
  @Test("Exactly one caller wins the claim under contention")
  func onlyOneClaimWins() async {
    for _ in 0..<200 {
      let guardBox = LockedBox(false)
      let winners = LockedBox(0)
      await withTaskGroup(of: Bool.self) { group in
        for _ in 0..<8 {
          group.addTask { guardBox.markResumed() }
        }
        for await won in group where won {
          winners.set(winners.get() + 1)
        }
      }
      #expect(winners.get() == 1)
      #expect(guardBox.get())
    }
  }

  @Test("A second claim after the first is refused")
  func secondClaimIsRefused() {
    let guardBox = LockedBox(false)
    #expect(guardBox.markResumed())
    #expect(!guardBox.markResumed())
    #expect(!guardBox.markResumed())
  }
}
