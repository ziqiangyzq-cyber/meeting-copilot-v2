// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "CanonicalAudioClock",
    products: [
        .library(name: "CanonicalAudioClock", targets: ["CanonicalAudioClock"]),
        .executable(name: "canonical-audio-clock-checks", targets: ["CanonicalAudioClockChecks"])
    ],
    dependencies: [.package(path: "../audio-clock")],
    targets: [
        .target(name: "CanonicalAudioClock", dependencies: [.product(name: "AudioClock", package: "audio-clock")]),
        .executableTarget(name: "CanonicalAudioClockChecks", dependencies: ["CanonicalAudioClock"])
    ]
)
