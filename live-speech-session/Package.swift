// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "LiveSpeechSession", platforms: [.macOS("14.2")],
    products: [.library(name: "LiveSpeechSession", targets: ["LiveSpeechSession"]),
               .executable(name: "live-speech-session-checks", targets: ["LiveSpeechSessionChecks"])],
    dependencies: [.package(path: "../audio-capture"), .package(path: "../audio-clock"), .package(path: "../speech-core")],
    targets: [
        .target(name: "LiveSpeechSession", dependencies: [
            .product(name: "MeetingCopilotAudioCapture", package: "audio-capture"),
            .product(name: "MeetingCopilotPCMBridge", package: "audio-capture"),
            .product(name: "AudioClock", package: "audio-clock"),
            .product(name: "AppleOfflineSpeech", package: "speech-core")]),
        .executableTarget(name: "LiveSpeechSessionChecks", dependencies: ["LiveSpeechSession"])
    ])
