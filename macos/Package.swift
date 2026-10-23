// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NotifyBridge",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "NotifyBridgeCore", targets: ["NotifyBridgeCore"]),
        .executable(name: "NotifyBridge", targets: ["NotifyBridge"]),
        .executable(name: "ProtocolSelfTest", targets: ["ProtocolSelfTest"]),
    ],
    targets: [
        .target(name: "NotifyBridgeCore"),
        .executableTarget(name: "NotifyBridge", dependencies: ["NotifyBridgeCore"]),
        .executableTarget(name: "ProtocolSelfTest", dependencies: ["NotifyBridgeCore"]),
    ]
)
