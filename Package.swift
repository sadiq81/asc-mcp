// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "asc-mcp",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "asc-mcp", targets: ["asc-mcp"])
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "5.0.1")
    ],
    // Linux has no CryptoKit or system zlib module, so those come from portable
    // replacements (Linux-only dependencies). Apple platforms are unchanged.
    targets: [
        // zlib headers from the system (zlib1g-dev on Debian/Ubuntu). No pkgConfig,
        // so macOS builds never try to resolve it and stay warning-free.
        .systemLibrary(name: "CZlib", path: "Sources/CZlib"),
        .executableTarget(
            name: "asc-mcp",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
                .target(name: "CZlib", condition: .when(platforms: [.linux]))
            ],
            resources: [
                .copy("Resources/OperationManifest")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "ASCMCPTests",
            dependencies: [
                "asc-mcp",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
                .target(name: "CZlib", condition: .when(platforms: [.linux]))
            ],
            resources: [.copy("Fixtures")],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
    ]
)
