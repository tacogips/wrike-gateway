// swift-tools-version: 6.0

import PackageDescription

// Capability tiers are cumulative and separated at link boundaries.
// `WrikeGatewayReaderCLI` must never depend on `WrikeGatewayWrite` or
// `WrikeGatewayAdmin`, and `WrikeGatewayWriterCLI` must never depend on
// `WrikeGatewayAdmin`. `Tests/WrikeGatewayCLITests` asserts both the manifest
// structure and the linked symbols of the produced executables.
let package = Package(
  name: "wrike-gateway",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(name: "WrikeGatewayCore", targets: ["WrikeGatewayCore"]),
    .library(name: "WrikeGatewayRead", targets: ["WrikeGatewayCore", "WrikeGatewayRead"]),
    .library(
      name: "WrikeGatewayWrite",
      targets: ["WrikeGatewayCore", "WrikeGatewayRead", "WrikeGatewayWrite"]
    ),
    .library(
      name: "WrikeGatewayAdmin",
      targets: ["WrikeGatewayCore", "WrikeGatewayRead", "WrikeGatewayWrite", "WrikeGatewayAdmin"]
    ),
    .executable(name: "wrike-gateway-reader", targets: ["WrikeGatewayReaderCLI"]),
    .executable(name: "wrike-gateway-writer", targets: ["WrikeGatewayWriterCLI"]),
    .executable(name: "wrike-gateway-admin", targets: ["WrikeGatewayAdminCLI"])
  ],
  targets: [
    .target(name: "WrikeGatewayCore"),
    .target(name: "WrikeGatewayRead", dependencies: ["WrikeGatewayCore"]),
    .target(name: "WrikeGatewayWrite", dependencies: ["WrikeGatewayCore", "WrikeGatewayRead"]),
    .target(
      name: "WrikeGatewayAdmin",
      dependencies: ["WrikeGatewayCore", "WrikeGatewayRead", "WrikeGatewayWrite"]
    ),
    .executableTarget(
      name: "WrikeGatewayReaderCLI",
      dependencies: ["WrikeGatewayCore", "WrikeGatewayRead"]
    ),
    .executableTarget(
      name: "WrikeGatewayWriterCLI",
      dependencies: ["WrikeGatewayCore", "WrikeGatewayRead", "WrikeGatewayWrite"]
    ),
    .executableTarget(
      name: "WrikeGatewayAdminCLI",
      dependencies: ["WrikeGatewayCore", "WrikeGatewayRead", "WrikeGatewayWrite", "WrikeGatewayAdmin"]
    ),
    // Test-only support: recording transport, loopback server, injected clock,
    // credential, identity, and file seams. No executable target depends on it,
    // so no production binary can contain a mock or fixture path.
    .target(
      name: "WrikeGatewayTestSupport",
      dependencies: ["WrikeGatewayCore"],
      path: "Tests/WrikeGatewayTestSupport"
    ),
    .testTarget(
      name: "WrikeGatewayCoreTests",
      dependencies: ["WrikeGatewayCore", "WrikeGatewayTestSupport"]
    ),
    .testTarget(
      name: "WrikeGatewayReadTests",
      dependencies: ["WrikeGatewayCore", "WrikeGatewayRead", "WrikeGatewayTestSupport"]
    ),
    .testTarget(
      name: "WrikeGatewayWriteTests",
      dependencies: [
        "WrikeGatewayCore",
        "WrikeGatewayRead",
        "WrikeGatewayWrite",
        "WrikeGatewayTestSupport"
      ]
    ),
    .testTarget(
      name: "WrikeGatewayAdminTests",
      dependencies: [
        "WrikeGatewayCore",
        "WrikeGatewayRead",
        "WrikeGatewayWrite",
        "WrikeGatewayAdmin",
        "WrikeGatewayTestSupport"
      ]
    ),
    // The CLI test target depends on the three executable targets so that
    // `swift test` alone builds the binaries that its link-boundary and
    // end-to-end tests inspect and run.
    .testTarget(
      name: "WrikeGatewayCLITests",
      dependencies: [
        "WrikeGatewayCore",
        "WrikeGatewayRead",
        "WrikeGatewayWrite",
        "WrikeGatewayAdmin",
        "WrikeGatewayTestSupport",
        "WrikeGatewayReaderCLI",
        "WrikeGatewayWriterCLI",
        "WrikeGatewayAdminCLI"
      ]
    )
  ],
  swiftLanguageModes: [.v6]
)
