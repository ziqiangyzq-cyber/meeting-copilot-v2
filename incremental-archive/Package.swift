// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "IncrementalArchive", platforms: [.macOS(.v14)],
    products: [.library(name: "IncrementalArchive", targets: ["IncrementalArchive"]), .executable(name: "incremental-archive-checks", targets: ["IncrementalArchiveChecks"])],
    targets: [.target(name: "IncrementalArchive"), .executableTarget(name: "IncrementalArchiveChecks", dependencies: ["IncrementalArchive"])],
    swiftLanguageModes: [.v5])
