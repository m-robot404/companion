// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Companion",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "Companion", targets: ["Companion"])],
    targets: [.executableTarget(name: "Companion")]
)
