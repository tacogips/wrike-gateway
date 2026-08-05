import WrikeGatewayAdmin
import WrikeGatewayCore
import WrikeGatewayRead
import WrikeGatewayWrite

// The admin entry point selects a role and delegates to the shared command
// frame. It is the only binary that links WrikeGatewayAdmin and therefore the
// only one that can dispatch a reviewed delete capability.
await GatewayComposition.runMain(role: .admin, definitions: AdminCapabilities.all)
