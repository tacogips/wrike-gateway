import WrikeGatewayCore

extension WrikeGatewaySDK {
  public static func writer() throws -> WrikeGatewaySDK {
    try WrikeGatewaySDK(role: .writer, definitions: WriteCapabilities.all)
  }
}
