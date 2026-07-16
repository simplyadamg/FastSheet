// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FastSheet",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "FastSheet", targets: ["FastSheet"])],
    targets: [
        .executableTarget(name: "FastSheet"),
        .testTarget(name: "FastSheetTests", dependencies: ["FastSheet"])
    ]
)
