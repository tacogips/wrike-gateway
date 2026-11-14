import WrikeGatewayCore
import WrikeGatewayRead
import WrikeGatewayWrite

// The writer entry point selects a role and delegates to the shared command
// frame. It links WrikeGatewayCore, WrikeGatewayRead, and WrikeGatewayWrite;
// WrikeGatewayAdmin is not reachable from this binary at link time.
await GatewayComposition.runMain(role: .writer, definitions: WriteCapabilities.all)
