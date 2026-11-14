import WrikeGatewayCore
import WrikeGatewayRead

// The reader entry point selects a role and delegates to the shared command
// frame. It links WrikeGatewayCore and WrikeGatewayRead only; no write or admin
// module is reachable from this binary at link time.
await GatewayComposition.runMain(role: .reader, definitions: ReadCapabilities.all)
