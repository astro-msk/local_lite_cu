// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LiteCU",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "LiteCU", targets: ["LiteCU"])],
    targets: [
        .target(name: "LiteCUCore"),
        .executableTarget(name: "LiteCU", dependencies: ["LiteCUCore"]),
        .executableTarget(name: "LiteCUCheck", dependencies: ["LiteCUCore"]),
        .testTarget(name: "LiteCUCoreTests", dependencies: ["LiteCUCore"])
    ],
    swiftLanguageModes: [.v5]
)
