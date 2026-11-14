import WrikeGatewayCore

extension WrikeGatewaySDK {
  public static func admin() throws -> WrikeGatewaySDK {
    try WrikeGatewaySDK(role: .admin, definitions: AdminCapabilities.all)
  }
}
