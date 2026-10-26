// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "RotatingSpeechSession", platforms: [.macOS("14.2")],
    products: [.library(name: "RotatingSpeechSession", targets: ["RotatingSpeechSession"]),
               .executable(name: "rotating-speech-session-checks", targets: ["RotatingSpeechSessionChecks"])],
    dependencies: [.package(path: "../live-speech-session"), .package(path: "../audio-capture"),
                   .package(path: "../audio-clock"), .package(path: "../canonical-audio-clock"), .package(path: "../speech-core")],
    targets: [.target(name: "RotatingSpeechSession", dependencies: [
        .product(name: "LiveSpeechSession", package: "live-speech-session"),
        .product(name: "MeetingCopilotAudioCapture", package: "audio-capture"),
        .product(name: "MeetingCopilotPCMBridge", package: "audio-capture"),
        .product(name: "AudioClock", package: "audio-clock"),
        .product(name: "CanonicalAudioClock", package: "canonical-audio-clock"),
        .product(name: "AppleOfflineSpeech", package: "speech-core")]),
        .executableTarget(name: "RotatingSpeechSessionChecks", dependencies: ["RotatingSpeechSession"])])
