import Foundation
import ClientRuntime
import MeetingCopilotCore
import DesktopSessionController
import LocalASRProviders
import AppleOfflineSpeech
import LocalTranslationEngine

struct CheckFailure: Error { let message: String }
@MainActor func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw CheckFailure(message: message) }
}

@main struct Checks {
    @MainActor static func main() async {
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("system-source-checks-" + UUID().uuidString)
            let config = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("text-mode-config.json")
            var translated = 0
            let model = ClientModel(directory: directory, configURL: config, translationOperation: { job in
                // The original and correct system provenance must be durable before dispatch.
                let saved = try ArchiveStore(directory: directory).load()
                try require(saved.sessions.first?.segments.first?.channelKind == "system", "translation precedes durable system source")
                translated += 1
                return TranslationOutput(job: job, translatedText: "系统音频测试", engine: "fixture-only")
            })
            await model.startSelectedAudio()
            try require(!model.captureActive && !model.microphoneEnabled, "start without a session opened capture")
            let displays = model.audioDisplays.map(\.id)
            let automatic = model.resolvedSystemDisplayID()
            try require(displays.isEmpty ? automatic == nil : automatic.map { displays.contains($0) } == true,
                "automatic system scope did not resolve a connected display")
            model.systemDisplayID = UInt32.max
            try require(model.resolvedSystemDisplayID() == nil, "disconnected explicit scope silently changed")
            model.systemDisplayID = 0
            try require(!model.captureActive && !model.microphoneEnabled, "scope resolution started capture")
            print("PASS automatic scope, unavailable explicit scope, no capture on selection or start without session")
            model.add(demo: false)
            model.translateFinal = true
            let sessionID = model.selection!
            let final = QwenSegmentFinal(binding: .init(sessionID: sessionID, channelID: "system",
                streamID: "system-test-stream", source: .systemAudio), attemptID: UUID(), sequence: 1,
                sourceRange: .init(frameStart: 0, frameEnd: 16000, mappingRevision: 1, startNs: 4_000_000_000, endNs: 5_000_000_000),
                text: "System audio test", language: "English",
                engine: .init(providerID: .qwen3ASR, engineVersion: "fixture", modelVersion: "fixture", locale: "auto", generation: 1))
            try await model.commitQwenFinal(final, sourceURL: nil)
            for _ in 0..<100 where model.selected?.segments.first?.currentTranslations.isEmpty == true {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            try require(translated == 1 && model.selected?.segments.first?.currentTranslations.count == 1, "system final did not automatically translate")
            try require(model.selected?.captureAttempts.first?.sourceKind == "system" &&
                model.selected?.captureAttempts.first?.mode == "qwen-system-segmented", "system capture mislabeled as microphone/file")
            try await model.finishQwenAttempts(lifecycle: "completed", failure: nil)
            let reopened = ClientModel(directory: directory, configURL: config)
            try require(reopened.archive == model.archive, "system source/translation/terminal did not reopen")
            try require(reopened.selected?.segments.first?.current?.text == "System audio test", "original changed")
            do {
                try await model.commitQwenFinal(final, sourceURL: URL(fileURLWithPath: "/tmp/unrelated.wav"))
                throw CheckFailure(message: "system final accepted unrelated file identity")
            } catch is QwenClientError {}
            print("PASS system source + PTS + automatic translation after durable original + terminal + persisted reopen + file identity rejection")
            print("AUDIO_INPUT_CHECKS_COMPLETE; injected finals and translation only; native capture covered by separate GUI evidence")
        } catch { print("FAIL \(error)"); exit(1) }
    }
}
