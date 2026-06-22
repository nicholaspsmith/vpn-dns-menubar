// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VPNDNSMenuBar",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "VPNDNSMenuBar", targets: ["VPNDNSMenuBar"]),
        .library(name: "VPNDNSCore", targets: ["VPNDNSCore"]),
    ],
    dependencies: [
        .package(path: "../StatusItemKit"),
    ],
    targets: [
        .target(name: "VPNDNSCore"),
        .executableTarget(
            name: "VPNDNSMenuBar",
            dependencies: ["VPNDNSCore", .product(name: "StatusItemKit", package: "StatusItemKit")]
        ),
        .testTarget(name: "VPNDNSCoreTests", dependencies: ["VPNDNSCore"]),
    ]
)
