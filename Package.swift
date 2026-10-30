// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Pulse",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Pulse", targets: ["Pulse"]), .library(name: "PulseCore", targets: ["PulseCore"])],
    dependencies: [
        .package(url: "https://github.com/vapor/postgres-nio.git", exact: "1.33.2"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.37.5"),
        .package(url: "https://github.com/apple/swift-log.git", exact: "1.16.2")
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "PulseCore", dependencies: ["CSQLite", .product(name: "PostgresNIO", package: "postgres-nio"), .product(name: "NIOSSL", package: "swift-nio-ssl"), .product(name: "Logging", package: "swift-log")]),
        .executableTarget(name: "Pulse", dependencies: ["PulseCore"]),
        .testTarget(name: "PulseCoreTests", dependencies: ["PulseCore"])
    ]
)
