// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GamePulse",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "GamePulse", targets: ["GamePulse"])
    ],
    targets: [
        .executableTarget(
            name: "GamePulse",
            path: "Sources/GamePulse"
        ),
        .testTarget(
            name: "GamePulseTests",
            dependencies: ["GamePulse"],
            path: "Tests/GamePulseTests"
        )
    ]
)
