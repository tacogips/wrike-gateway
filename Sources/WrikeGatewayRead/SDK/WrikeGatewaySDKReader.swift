import WrikeGatewayCore

extension WrikeGatewaySDK {
  public static func reader() throws -> WrikeGatewaySDK {
    try WrikeGatewaySDK(role: .reader, definitions: ReadCapabilities.all)
  }
}
