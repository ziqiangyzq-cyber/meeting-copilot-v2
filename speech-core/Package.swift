// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "SpeechCore", platforms: [.macOS(.v13)],
    products: [.library(name: "SpeechCore", targets: ["SpeechCore"]), .library(name: "AppleOfflineSpeech", targets: ["AppleOfflineSpeech"]), .library(name: "LocalASRProviders", targets: ["LocalASRProviders"])],
    targets: [
        .target(name: "LocalASRProviders", dependencies: ["AppleOfflineSpeech"], resources: [.copy("Resources")], linkerSettings: [.linkedFramework("Speech"), .linkedFramework("AVFoundation")]),
        .executableTarget(name: "QwenProviderChecks", dependencies: ["LocalASRProviders", "AppleOfflineSpeech"]),
        .executableTarget(name: "LocalASRProviderChecks", dependencies: ["LocalASRProviders", "AppleOfflineSpeech"]),
        .target(name: "SpeechCore"),
        .target(name: "AppleOfflineSpeech", dependencies: ["SpeechCore"], linkerSettings: [.linkedFramework("Speech"), .linkedFramework("AVFoundation")]),
        .executableTarget(name: "SpeechCoreChecks", dependencies: ["SpeechCore"], path: "Tests/SpeechCoreTests"),
        .executableTarget(name: "SpeechCoreQAAdapter", dependencies: ["SpeechCore"]),
        .executableTarget(name: "AppleSpeechGateChecks", dependencies: ["AppleOfflineSpeech", "SpeechCore"]),
        .executableTarget(name: "IndependentSpeechWorker", dependencies: ["SpeechCore"], linkerSettings: [.linkedFramework("Speech"), .linkedFramework("AVFoundation")]),
        .executableTarget(name: "BilingualSpeechExperiment", dependencies: ["SpeechCore"], linkerSettings: [.linkedFramework("Speech"), .linkedFramework("AVFoundation")])
    ]
)
