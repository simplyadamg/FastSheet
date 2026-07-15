// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FinderStack",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "FinderStack", targets: ["FinderStack"])],
    targets: [.executableTarget(name: "FinderStack")]
)
