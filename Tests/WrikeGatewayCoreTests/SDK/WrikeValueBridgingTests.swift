import GatewaySDKKit
import Testing
@testable import WrikeGatewayCore

@Suite("Wrike SDK value bridging")
struct WrikeValueBridgingTests {
  @Test("Both bridge directions preserve every JSON case")
  func roundTrips() {
    let value = WrikeValue.object([
      "null": .null,
      "bool": .bool(true),
      "integer": .int(3),
      "double": .double(3.5),
      "string": .string("value"),
      "array": .array([.int(1), .double(1.0)]),
      "object": .object(["id": .string("x")])
    ])
    #expect(WrikeValue(GatewayJSONValue(value)) == value)
    #expect(GatewayJSONValue(WrikeValue(.double(3.0))) == .double(3.0))
    #expect(GatewayJSONValue(WrikeValue(.int(3))) == .int(3))
  }
}
