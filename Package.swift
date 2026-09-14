// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Peel",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "PeelKit"),
        .executableTarget(name: "Peel", dependencies: ["PeelKit"]),
        .testTarget(name: "PeelTests", dependencies: ["PeelKit"]),
    ]
)
