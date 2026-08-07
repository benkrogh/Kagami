// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Kagami",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Kagami",
            path: "Sources/Kagami",
            resources: [.process("Resources")],
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=minimal"])
            ]
        )
    ]
)
