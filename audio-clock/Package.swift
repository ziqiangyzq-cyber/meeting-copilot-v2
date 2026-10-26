// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudioClock",
    products: [
        .library(name: "AudioClock", targets: ["AudioClock"]),
        .executable(name: "audio-clock-checks", targets: ["AudioClockChecks"])
    ],
    targets: [
        .target(name: "AudioClock"),
        .executableTarget(name: "AudioClockChecks", dependencies: ["AudioClock"])
    ]
)
