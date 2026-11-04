// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Treadmill",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TreadmillApp", targets: ["TreadmillApp"]),
    ],
    targets: [
        // Protocol + CoreBluetooth client. No UI, so it stays easy to test and port.
        .target(name: "WalkingPadKit"),
        .executableTarget(name: "TreadmillApp", dependencies: ["WalkingPadKit"]),
        .testTarget(name: "WalkingPadKitTests", dependencies: ["WalkingPadKit"]),
    ]
)
