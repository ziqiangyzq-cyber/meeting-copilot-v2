// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "APIIntelligence", platforms: [.macOS("14.2")],
    products: [
        .library(name: "APIIntelligence", targets: ["APIIntelligence"]),
        .executable(name: "APIIntelligenceChecks", targets: ["APIIntelligenceChecks"])
    ],
    dependencies: [],
    targets: [
        .target(name: "APIIntelligence"),
        .executableTarget(name: "APIIntelligenceChecks", dependencies: ["APIIntelligence"])
    ]
)
