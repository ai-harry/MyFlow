// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyFlow",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7")
    ],
    targets: [
        .executableTarget(
            name: "MyFlow",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/MyFlow",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
