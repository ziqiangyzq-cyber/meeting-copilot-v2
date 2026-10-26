// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "DesktopSessionController", platforms: [.macOS("14.2")],
    products: [.library(name: "DesktopSessionController", targets: ["DesktopSessionController"]),
               .executable(name: "desktop-session-checks", targets: ["DesktopSessionChecks"]),
               .executable(name: "desktop-canonical-checks", targets: ["DesktopCanonicalChecks"]),
               .executable(name: "qwen-segment-checks", targets: ["QwenSegmentChecks"])],
    dependencies: [.package(path: "../live-speech-session"), .package(path: "../rotating-speech-session"), .package(path: "../audio-capture"), .package(path: "../speech-core")],
    targets: [
        .target(name: "DesktopSessionController", dependencies: [
            .product(name: "LiveSpeechSession", package: "live-speech-session"),
            .product(name: "RotatingSpeechSession", package: "rotating-speech-session"),
            .product(name: "MeetingCopilotAudioCapture", package: "audio-capture"),
            .product(name: "MeetingCopilotPCMBridge", package: "audio-capture"),
            .product(name: "LocalASRProviders", package: "speech-core"),
            .product(name: "AppleOfflineSpeech", package: "speech-core")]),
        .executableTarget(name: "DesktopSessionChecks", dependencies: ["DesktopSessionController"]),
        .executableTarget(name: "DesktopCanonicalChecks", dependencies: ["DesktopSessionController"]),
        .executableTarget(name: "QwenSegmentChecks", dependencies: ["DesktopSessionController", .product(name: "LocalASRProviders", package: "speech-core"), .product(name: "MeetingCopilotAudioCapture", package: "audio-capture"), .product(name: "AppleOfflineSpeech", package: "speech-core")])
    ])
