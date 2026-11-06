// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "BottledResetRune", platforms: [.macOS(.v13)],
    products: [.library(name: "RuneCore", targets: ["RuneCore"]),
               .executable(name: "reset-rune", targets: ["RuneCommand"]),
               .executable(name: "BottledResetRuneMenu", targets: ["RuneMenu"])],
    dependencies: [.package(url: "https://github.com/apple/swift-nio.git", exact: "2.90.0"),
                   .package(url: "https://github.com/apple/swift-collections.git", exact: "1.2.1"),
                   .package(url: "https://github.com/apple/swift-system.git", exact: "1.4.2")],
    targets: [
        .target(name: "RuneCore"),
        .target(name: "CodexTransport", dependencies: ["RuneCore"], exclude:["README.md"]),
        .target(name: "RuneService", dependencies: ["RuneCore", "CodexTransport",
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio")]),
        .executableTarget(name: "RuneCommand", dependencies: ["RuneService", "RuneCore"]),
        .executableTarget(name: "RuneMenu"),
        .testTarget(name: "RuneCoreTests", dependencies: ["RuneCore"]),
        .testTarget(name: "CodexTransportTests", dependencies: ["CodexTransport", "RuneCore"]),
        .testTarget(name: "RuneServiceTests", dependencies: ["RuneService", "RuneCore"]),
        .testTarget(name: "RuneMenuTests", dependencies: ["RuneMenu"])
    ], swiftLanguageVersions: [.v5])
