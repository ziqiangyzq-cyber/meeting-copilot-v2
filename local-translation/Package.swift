// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocalTranslationEngine",
    platforms: [.macOS("14.2")],
    products: [.library(name: "LocalTranslationEngine", targets: ["LocalTranslationEngine"])],
    targets: [.target(name: "LocalTranslationEngine")],
    swiftLanguageModes: [.v5]
)
