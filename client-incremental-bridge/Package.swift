// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "ClientIncrementalBridge", platforms: [.macOS(.v14)],
 products: [.library(name: "ClientIncrementalBridge", targets: ["ClientIncrementalBridge"]), .executable(name: "client-incremental-bridge-checks", targets: ["BridgeChecks"])],
 dependencies: [.package(path: "../incremental-archive"), .package(path: "../speech-core")],
 targets: [.target(name: "ClientIncrementalBridge", dependencies: [.product(name: "IncrementalArchive", package: "incremental-archive"), .product(name: "SpeechCore", package: "speech-core")]), .executableTarget(name: "BridgeChecks", dependencies: ["ClientIncrementalBridge", .product(name: "IncrementalArchive", package: "incremental-archive"), .product(name: "SpeechCore", package: "speech-core")])], swiftLanguageModes: [.v5])
