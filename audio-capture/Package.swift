// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "MeetingCopilotAudioCapture",
    platforms: [.macOS("14.2")],
    products: [
        .library(name: "MeetingCopilotAudioCapture", targets: ["MeetingCopilotAudioCapture"]),
        .library(name: "MeetingCopilotPCMBridge", targets: ["MeetingCopilotPCMBridge"])
    ],
    targets: [
        .target(name: "MeetingCopilotAudioCapture"),
        .target(name: "MeetingCopilotPCMBridge", dependencies: ["MeetingCopilotAudioCapture"])
    ]
)
