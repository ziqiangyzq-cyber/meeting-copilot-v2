import Foundation
import AVFoundation
import ClientRuntime
import MeetingCopilotCore
import DesktopSessionController
import LocalASRProviders
import AppleOfflineSpeech

/// Synthetic finals and a decoded PCM fixture exercise real writers; no ASR model is invoked.
@MainActor func runQwenWriterChecks(root: URL) async throws {
    let config = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("text-mode-config.json")
    let inputURL = root.appendingPathComponent("fake-audio.wav")
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
    pcm.frameLength = 16_000
    for i in 0..<16_000 { pcm.floatChannelData![0][i] = 0.01 }
    do {
        let file = try AVAudioFile(forWriting: inputURL, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: pcm)
    }
    let engine = ASREngineIdentity(providerID: .qwen3ASR, engineVersion: "fake-qwen-engine", modelVersion: "fake-weight-sha", locale: "zh-CN", generation: 1)
    for incremental in [false, true] {
        let label = incremental ? "typed" : "default"
        let directory = root.appendingPathComponent("qwen-\(label)-writer")
        let client = ClientModel(directory: directory, configURL: config)
        if incremental {
            await client.enableIncrementalOnLaunch()
            try settingsRequire(client.incremental != nil, "incremental production writer must open")
        }
        client.add(demo: false)
        guard let sessionID = client.selection else { throw SettingsCheckFailure(message: "missing session") }
        let binding = QwenSessionBinding(sessionID: sessionID, channelID: "audio-file", streamID: "fake-file-stream", source: .file, sourceURL: inputURL)
        let attemptID = UUID()
        var finals: [QwenSegmentFinal] = []
        for sequence in 0..<2 {
            let final = QwenSegmentFinal(binding: binding, attemptID: attemptID, sequence: sequence,
                sourceRange: PCMSourceRange(frameStart: sequence * 128_000, frameEnd: (sequence + 1) * 128_000,
                    mappingRevision: 1, startNs: UInt64(sequence) * 8_000_000_000, endNs: UInt64(sequence + 1) * 8_000_000_000),
                text: "fake file final \(sequence)", language: "Chinese", engine: engine)
            finals.append(final)
            try await client.commitQwenFinal(final, sourceURL: inputURL)
        }
        var duplicateRejected = false
        do { try await client.commitQwenFinal(finals[0], sourceURL: inputURL) } catch { duplicateRejected = true }
        try settingsRequire(duplicateRejected, "duplicate final must still be rejected")
        try await client.finishQwenAttempts(lifecycle: "completed", failure: nil)
        if let persistence = client.incremental { _ = try await persistence.awaitQuiescence() }
        let reopened = ClientModel(directory: directory, configURL: config)
        if incremental { await reopened.enableIncrementalOnLaunch() }
        guard let session = reopened.archive.sessions.first(where: { $0.id == sessionID }),
              let attempt = session.captureAttempts.first else { throw SettingsCheckFailure(message: "writer lost final/attempt on reopen") }
        try settingsRequire(session.segments.count == 2 && attempt.tasks?.count == 2, "both segments/tasks survive production writer/reopen")
        for (sequence, final) in finals.enumerated() {
            let segmentID = "qwen-\(attemptID.uuidString)-\(sequence)"
            guard let segment = session.segments.first(where: { $0.id == segmentID }), let revision = segment.current,
                  let task = attempt.tasks?.first(where: { $0.segmentID == segmentID }) else { throw SettingsCheckFailure(message: "missing segment/task") }
            try settingsRequire(revision.text == final.text && segment.channelKind == "audio_file", "exact final/source kind survive")
            try settingsRequire(revision.streamID == final.recognitionStreamID && task.streamID == final.recognitionStreamID,
                "event and task must use same recognition stream")
            try settingsRequire(revision.sourceSpans?.first?.streamId == final.recognitionStreamID,
                "source span must use recognition stream")
            try settingsRequire(revision.startNS == String(final.sourceRange.startNs) && revision.endNS == String(final.sourceRange.endNs)
                && revision.sourceSpans?.first?.frameStart == final.sourceRange.frameStart
                && revision.sourceSpans?.first?.frameEnd == final.sourceRange.frameEnd,
                "native source frames and global times must not reset")
        }
        try settingsRequire(finals[0].recognitionStreamID != finals[1].recognitionStreamID && attempt.streamID == binding.streamID, "segment streams differ; attempt retains input stream")
        try settingsRequire(attempt.engineVersion == engine.engineVersion && attempt.modelVersion == engine.modelVersion, "supplied identity survives")
        try settingsRequire(attempt.sourceKind == "audio_file" && attempt.sourceURL == inputURL.absoluteString, "exact source kind and URL survive")
        try settingsRequire(!attempt.deviceStarted && attempt.audioObserved && attempt.asrObserved, "file must not claim microphone start")
        try settingsRequire(attempt.lifecycle == "completed", "completed only after terminal confirmation")
        print("PASS fake Qwen production writer: \(label) two finals / distinct task streams / native ranges / duplicate reject / reopen")

        let failureDirectory = root.appendingPathComponent("qwen-\(label)-decode-failure")
        let failedClient = ClientModel(directory: failureDirectory, configURL: config)
        if incremental { await failedClient.enableIncrementalOnLaunch() }
        failedClient.add(demo: false)
        guard let failureSessionID = failedClient.selection else { throw SettingsCheckFailure(message: "missing failure session") }
        let backend = WriterRejectingQwenBackend(engine: engine)
        let controller = QwenSegmentController(backend: backend)
        _ = try await controller.prepare(ASRConfiguration(providerID: .qwen3ASR, locale: .simplifiedChinese, modelPath: "/fake/model"))
        controller.onObservationChange = { observation in failedClient.recordQwenAttempt(observation) }
        var backendRejected = false
        do {
            try await controller.transcribeFile(inputURL, binding: QwenSessionBinding(sessionID: failureSessionID,
                channelID: "audio-file", streamID: "decoded-input", source: .file, sourceURL: inputURL))
        } catch { backendRejected = true }
        try settingsRequire(backendRejected && backend.calls == 1 && controller.engine == nil, "backend rejection clears active engine")
        guard let observation = controller.attemptObservation else { throw SettingsCheckFailure(message: "missing historical observation") }
        failedClient.recordQwenAttempt(observation) // Update after active engine has cleared.
        try await failedClient.finishQwenAttempts(lifecycle: "incomplete", failure: "fake-backend-rejected")
        if let persistence = failedClient.incremental { _ = try await persistence.awaitQuiescence() }
        let failedReopen = ClientModel(directory: failureDirectory, configURL: config)
        if incremental { await failedReopen.enableIncrementalOnLaunch() }
        guard let failedSession = failedReopen.archive.sessions.first(where: { $0.id == failureSessionID }),
              let failedAttempt = failedSession.captureAttempts.first else { throw SettingsCheckFailure(message: "lost decoded failed attempt") }
        try settingsRequire(failedSession.segments.isEmpty && failedAttempt.audioObserved && !failedAttempt.asrObserved
            && !failedAttempt.deviceStarted && failedAttempt.lifecycle == "incomplete", "decoded audio survives ASR failure without claiming ASR/device/completion")
        try settingsRequire(failedAttempt.streamID == "decoded-input" && failedAttempt.sourceURL == inputURL.absoluteString
            && failedAttempt.engineVersion == engine.engineVersion, "historical source and engine survive failure")
        print("PASS fake Qwen production writer: \(label) actual decode / backend rejection / cleared engine / observation reopen")
    }
}

@MainActor private final class WriterRejectingQwenBackend: QwenSegmentBackend {
    let engine: ASREngineIdentity
    var prepared = false
    var calls = 0
    init(engine: ASREngineIdentity) { self.engine = engine }
    func preparedEngine(for configuration: ASRConfiguration) -> ASREngineIdentity? { prepared ? engine : nil }
    func load(_ configuration: ASRConfiguration) async throws -> ASREngineIdentity { prepared = true; return engine }
    func transcribe(fileURL: URL, context: String?) async throws -> QwenBatchResult {
        calls += 1
        throw QwenControllerError.backend("fake-backend-rejected")
    }
    func cancel() { prepared = false }
    func unload() { prepared = false }
}
