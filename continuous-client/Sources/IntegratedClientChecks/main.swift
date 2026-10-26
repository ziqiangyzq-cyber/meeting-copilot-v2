import Foundation
import AVFoundation
import MeetingCopilotAudioCapture
import AppleOfflineSpeech
import LiveSpeechSession
import DesktopSessionController
import SpeechCore
import MeetingCopilotCore
import ClientRuntime
import LocalTranslationEngine

struct CheckFailure: Error { let message: String }
@MainActor func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw CheckFailure(message: message) }
}
@MainActor final class FakePermissions: DesktopPermissionGateway {
    var reads = 0, mic = true, speech = true
    func requestMicrophone() async -> Bool { reads += 1; return mic }
    func requestSpeech() async -> Bool { reads += 1; return speech }
}
@MainActor final class FakeCapture: DesktopCapturePort {
    var state: CaptureState = .idle
    var onStateChange: (@MainActor @Sendable (CaptureState) -> Void)?
    var handler: AudioFrameHandler?
    var starts = 0
    func start(intent: CaptureIntent, onFrame: @escaping AudioFrameHandler) throws {
        starts += 1; handler = onFrame; state = .running
    }
    func stop() { state = .stopped }
    func emit(frames: UInt32 = 4, position: Int64 = 0, rate: Double = 16000, host: Double = 1, channels: UInt32 = 1) {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for c in 0..<Int(channels) { for i in 0..<Int(frames) { buffer.floatChannelData![c][i] = 0 } }
        handler?(AudioFrame(buffer: buffer, timestamp: SourceTimestamp(source: .microphone, hostSeconds: host,
            samplePosition: position, sampleRate: rate, presentationSeconds: nil, receivedUptime: 10)))
    }
}
@MainActor final class FakeBackend: OfflinePCMRecognitionBackend {
    var osAuthorized = true
    var callback: (@MainActor @Sendable (SpeechBackendObservation) -> Void)?
    var begins = 0, appends = 0, appendedFrames = 0
    var firstAppend: [(String, Bool)] = []
    var finalOnFinish: String?
    var locales: [String] = []
    func begin(locale: OfflineSpeechLocale, deliver: @escaping @MainActor @Sendable (SpeechBackendObservation) -> Void) throws {
        begins += 1; locales.append(locale.rawValue); callback = deliver
    }
    func append(_ buffer: AVAudioPCMBuffer) throws {
        appends += 1; appendedFrames += Int(buffer.frameLength)
        if appends == 1 { for (text, final) in firstAppend { callback?(.hypothesis(text: text, isFinal: final)) } }
    }
    func finishAudio() { if let finalOnFinish { callback?(.hypothesis(text: finalOnFinish, isFinal: true)) } }
    func cancel() {}
}
@MainActor func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    while !condition() {
        try require(ProcessInfo.processInfo.systemUptime < deadline, "synthetic controller timeout")
        try await Task.sleep(nanoseconds: 2_000_000)
    }
}
struct FixtureConfiguration: Decodable {
    let session_id: String, channel_id: String, stream_id: String, segment_id: String
    let sample_rate_hz: Double, channels: UInt32
    let maximum_queued_blocks: Int, maximum_frames_per_block: UInt32, maximum_blocks_per_poll: Int
    let maximum_input_frames: Int, finish_deadline_seconds: Double, mapping_revision: Int
    var live: LiveSpeechConfiguration {
        LiveSpeechConfiguration(sessionId: session_id, channelId: channel_id, streamId: stream_id, segmentId: segment_id,
            source: .microphone, locale: .simplifiedChinese, queueCapacityBlocks: maximum_queued_blocks,
            maximumFramesPerBlock: maximum_frames_per_block, maximumBytesPerBlock: 1024,
            maximumInputFrames: maximum_input_frames, maximumBlocksPerPoll: maximum_blocks_per_poll,
            finishDeadlineSeconds: finish_deadline_seconds, mappingRevision: mapping_revision)
    }
}
struct FixtureStep: Decodable {
    let op: String
    let text: String?, is_final: Bool?, frame_count: UInt32?, sample_position: Int64?, host_seconds: Double?
}
struct CaptureFixture: Decodable { let case_id: String, configuration: FixtureConfiguration, steps: [FixtureStep] }
struct TranslationFixture: Decodable { let case_id: String, segment: LocalSegment }

@MainActor final class TranslationJobs { var values: [TranslationJob] = [] }

@main struct Checks {
    @MainActor static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments.first == "--fixture" {
                try require(arguments.count == 3, "usage: IntegratedClientChecks --fixture INPUT NEW_DIR")
                let input = URL(fileURLWithPath: arguments[1]), directory = URL(fileURLWithPath: arguments[2], isDirectory: true)
                try require(directory.standardizedFileURL.path.hasPrefix(configURL().deletingLastPathComponent().standardizedFileURL.path + "/"), "NEW_DIR must stay under integrated-client")
                try require(!FileManager.default.fileExists(atPath: directory.path), "NEW_DIR must not exist")
                let data = try Data(contentsOf: input)
                let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                if object["configuration"] != nil {
                    let fixture = try JSONDecoder().decode(CaptureFixture.self, from: data)
                    try await earlyFinal(directory: directory, fixture: fixture)
                } else {
                    let fixture = try JSONDecoder().decode(TranslationFixture.self, from: data)
                    try translationsFixture(directory: directory, fixture: fixture)
                }
            } else {
                let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("evidence/checks-" + UUID().uuidString)
                try await earlyFinal(directory: directory.appendingPathComponent("early"), fixture: nil)
                try await ordinaryLifecycle(directory: directory.appendingPathComponent("ordinary"))
                try await persistenceConflict(directory: directory.appendingPathComponent("conflict"))
                try await localeTranslation(directory: directory.appendingPathComponent("locale"))
                try translationFiltering(directory: directory.appendingPathComponent("translation"))
            }
            print("PASS IntegratedClientChecks; SAME ClientModel/controller/reducer/journal/ArchiveStore; fake permissions/capture/backend only")
        } catch { print("FAIL IntegratedClientChecks: \(error)"); exit(1) }
    }
    @MainActor static func configURL() -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("text-mode-config.json")
    }
    @MainActor static func earlyFinal(directory: URL, fixture: CaptureFixture?) async throws {
        var permissions: FakePermissions? = FakePermissions(), capture: FakeCapture? = FakeCapture(), backend: FakeBackend? = FakeBackend()
        var controller: DesktopSessionController? = DesktopSessionController(permissions: permissions!, capture: capture!, backend: backend!)
        var model: ClientModel? = ClientModel(directory: directory, configURL: configURL(), controller: controller!)
        weak var weakModel = model
        weak var weakController = controller
        let c = fixture?.configuration.live ?? LiveSpeechConfiguration(sessionId: "early", channelId: "mic", streamId: "stream-early", segmentId: "segment-early", source: .microphone, locale: .simplifiedChinese, queueCapacityBlocks: 3, maximumFramesPerBlock: 4, maximumBytesPerBlock: 1024, maximumInputFrames: 32, maximumBlocksPerPoll: 1, finishDeadlineSeconds: 1)
        let hypotheses = fixture?.steps.filter { $0.op == "inject_hypothesis" }.map { ($0.text!, $0.is_final!) } ?? [("部分文本", false), ("确切早final", true)]
        backend!.firstAppend = hypotheses
        let finalText = hypotheses.last!.0
        try require(!model!.microphoneEnabled && permissions!.reads == 0 && capture!.starts == 0 && backend!.begins == 0, "construction touched permission/device/backend")
        model!.archive.sessions = [LocalSession(id: c.sessionId, title: "Synthetic fixture")]; model!.selection = c.sessionId
        try require(model!.persist(), "save fixture session")
        await model!.startCapture(configuration: c)
        try require(permissions!.reads == 0 && capture!.starts == 0, "disabled opt-in requested permission")
        // Typed and mic journal events deliberately interleave through the actual model.
        if fixture == nil { model!.inputText = "typed before capture"; model!.submitText(translate: false); model!.editingSegmentID = nil }
        model!.microphoneEnabled = true
        await model!.startCapture(configuration: c)
        try require(model!.captureActive && permissions!.reads == 2 && capture!.starts == 1 && !controller!.snapshot.audioObserved && !controller!.snapshot.asrObserved, "start evidence or explicit permission gate")
        if fixture == nil { model!.inputText = "typed while capture active"; model!.submitText(translate: false); model!.editingSegmentID = nil }
        if let fixture {
            for step in fixture.steps where step.op == "enqueue_zero_pcm" {
                capture!.emit(frames: step.frame_count!, position: step.sample_position!, rate: fixture.configuration.sample_rate_hz, host: step.host_seconds!, channels: fixture.configuration.channels)
            }
        } else { capture!.emit(); capture!.emit(position: 4, host: 1.00025) }
        try await waitUntil { !model!.captureActive }
        try require(controller!.snapshot.state == .terminal(.incomplete(.unexpectedFinal)), "early final did not report incomplete")
        try require(controller!.snapshot.deviceStarted && controller!.snapshot.audioObserved && controller!.snapshot.asrObserved, "evidence flags lost")
        let queue = controller!.queueSnapshot!
        try require(queue.statistics.acceptedBlocks == 2 && queue.statistics.consumedBlocks == 1 && queue.statistics.releasedBlocks == 1 && queue.queuedBlocks == 0, "early final exact queue 2/1/1/0")
        let session = model!.selected!
        let mic = session.segments.first { $0.id == c.segmentId }!
        try require(mic.channelKind == "mic" && mic.revisions.count == 2 && mic.current!.text == finalText && mic.current!.status == "final", "observed final/revisions lost or relabeled typed")
        try require(mic.current!.sourceSpans == [SourceAudioSpan(channelId: c.channelId, streamId: c.streamId, frameStart: 0, frameEnd: 4, mappingRevision: c.mappingRevision)], "exact source span lost")
        let start = fixture?.steps.first { $0.op == "enqueue_zero_pcm" }?.host_seconds ?? 1
        let rate = fixture?.configuration.sample_rate_hz ?? 16000
        try require(mic.current!.startNS == String(UInt64(start * 1_000_000_000)) && mic.current!.endNS == String(UInt64(start * 1_000_000_000) + UInt64(4 * 1_000_000_000 / rate)), "source timestamps changed")
        try require(mic.current!.channelID == c.channelId && mic.current!.streamID == c.streamId && mic.current!.sourceLanguage == "zh-CN", "channel/stream/locale metadata lost")
        try require(session.captureAttempts.last!.lifecycle == "incomplete" && session.captureAttempts.last!.failure == "unexpectedFinal", "separate incomplete marker missing")
        let journal = try session.speechJournal.map { try SpeechEvent.decode($0) }
        try require(journal.map(\.eventSeq) == Array(1...journal.count), "typed/mic/status sequence collision")
        let observed = journal.filter { $0.segmentId == c.segmentId && $0.type == "asr.segment" }
        try require(observed.count == 2 && observed[0].status == "partial" && observed[1].status == "final" && observed[1].text == finalText, "journal doesn't retain actual partial/final")
        let generation = model!.archive.generation
        backend!.callback?(.hypothesis(text: finalText, isFinal: true))
        try require(model!.archive.generation == generation && model!.selected!.speechJournal == session.speechJournal, "old duplicate mutated journal/store")
        let frozen = model!.archive
        // No live controller, model or ArchiveStore survives the reopen.
        model = nil; controller = nil; permissions = nil; capture = nil; backend = nil
        try await Task.sleep(nanoseconds: 25_000_000)
        try require(weakModel == nil && weakController == nil, "old model/controller retained")
        let p2 = FakePermissions(), c2 = FakeCapture(), b2 = FakeBackend()
        let d2 = DesktopSessionController(permissions: p2, capture: c2, backend: b2)
        let reopened = ClientModel(directory: directory, configURL: configURL(), controller: d2)
        try require(reopened.archive == frozen && reopened.selected!.speechJournal == session.speechJournal && reopened.selected!.segments.first { $0.id == c.segmentId } == mic, "reopen changed exact journal/transcript/status")
        try require(p2.reads == 0 && c2.starts == 0 && b2.begins == 0 && !reopened.microphoneEnabled && !reopened.captureActive, "restore started capture")
        let output: [String: Any] = ["case_id": fixture?.case_id ?? "integrated_early_final", "accepted_blocks": queue.statistics.acceptedBlocks, "consumed_blocks": queue.statistics.consumedBlocks, "released_blocks": queue.statistics.releasedBlocks, "queued_blocks": queue.queuedBlocks, "terminal_state": "incomplete", "terminal_failure": "unexpectedFinal", "current_final_text": mic.current!.text, "current_final_frame_end": 4, "partial_final_journal_retained": true, "late_duplicate_ignored": true, "reopened_exact": true, "device_started": true, "audio_observed": true, "asr_observed": true, "real_permissions": 0, "real_devices": 0, "real_apple_backend": 0]
        try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("observations.json"))
        print("PASS early final + immediate real archive save/reopen + exact source span + 2/1/1/0 + stale duplicate + typed interleave")
    }
    @MainActor static func ordinaryLifecycle(directory: URL) async throws {
        let permissions = FakePermissions(), capture = FakeCapture(), backend = FakeBackend()
        backend.finalOnFinish = "final after stop"
        let controller = DesktopSessionController(permissions: permissions, capture: capture, backend: backend)
        let model = ClientModel(directory: directory, configURL: configURL(), controller: controller)
        model.rotatingEnabled = false
        model.add(demo: false); model.microphoneEnabled = true
        await model.startCapture()
        capture.emit()
        try await waitUntil { backend.appends == 1 }
        backend.callback?(.hypothesis(text: "partial saved immediately", isFinal: false))
        let disk = try ArchiveStore(directory: directory).load()
        try require(disk.sessions[0].segments[0].current?.status == "partial", "partial not immediately durable")
        model.stopCapture()
        try await waitUntil { !model.captureActive }
        try require(model.selected!.captureAttempts.last!.lifecycle == "completed" && model.selected!.segments[0].current!.status == "final", "stop completion missing")
        let first = model.selected!.captureAttempts.last!
        await model.startCapture()
        let second = model.selected!.captureAttempts.last!
        try require(first.streamID != second.streamID && first.segmentID != second.segmentID && first.id != second.id, "generation identity reused")
        let oldSession = model.selection!
        model.add(demo: false) // selection change cancels current capture before new session receives data.
        try require(!model.captureActive && model.archive.sessions.first { $0.id == oldSession }!.captureAttempts.last!.lifecycle == "cancelled", "selection did not cancel")
        capture.emit(position: 4, host: 1.00025)
        try await Task.sleep(nanoseconds: 25_000_000)
        try require(model.selected!.segments.isEmpty, "late recording entered wrong session")
        permissions.mic = false
        await model.startCapture()
        try require(model.selected!.captureAttempts.last!.failure == "permissionsMicrophone" && capture.starts == 2 && !model.captureActive, "denied permission started device or wasn't persisted")
        print("PASS partial durability, completed stop, new identities, selection cancellation, permission failure")
    }
    @MainActor static func persistenceConflict(directory: URL) async throws {
        let permissions = FakePermissions(), capture = FakeCapture(), backend = FakeBackend()
        let controller = DesktopSessionController(permissions: permissions, capture: capture, backend: backend)
        let model = ClientModel(directory: directory, configURL: configURL(), controller: controller)
        model.rotatingEnabled = false
        model.add(demo: false); model.microphoneEnabled = true
        await model.startCapture()
        capture.emit()
        try await waitUntil { backend.appends == 1 }
        let competingStore = ArchiveStore(directory: directory)
        var disk = try competingStore.load()
        disk.sessions[0].notes = "competing generation preserved"
        let competing = try competingStore.save(disk)
        backend.callback?(.hypothesis(text: "unsaved partial must remain in memory", isFinal: false))
        try await waitUntil { !model.captureActive }
        try require(capture.state == .stopped && controller.snapshot.state == .terminal(.cancelled), "persistence conflict left capture running")
        try require(model.error != nil && model.selected!.segments.first?.current?.text == "unsaved partial must remain in memory", "conflict lost unsaved transcript/error")
        let persisted = try competingStore.load()
        try require(persisted == competing, "capture conflict overwrote newer disk generation")
        print("PASS actual ArchiveStore stale generation conflict stops capture, preserves disk and unsaved partial")
    }
    @MainActor static func localeTranslation(directory: URL) async throws {
        let permissions = FakePermissions(), capture = FakeCapture(), backend = FakeBackend()
        backend.finalOnFinish = "中文最终文本"
        let controller = DesktopSessionController(permissions: permissions, capture: capture, backend: backend)
        let jobs = TranslationJobs()
        let model = ClientModel(directory: directory, configURL: configURL(), controller: controller, translationOperation: { job in
            jobs.values.append(job)
            return TranslationOutput(job: job, translatedText: "synthetic translation", engine: "synthetic-QA-only")
        })
        model.rotatingEnabled = false
        model.add(demo: false); model.microphoneEnabled = true; model.translateFinal = true
        model.recognizerLocale = "zh-CN"; model.sourceLanguage = "en"; model.targetLanguage = "en"
        await model.startCapture()
        capture.emit(); try await waitUntil { backend.appends == 1 }
        model.stopCapture()
        try await waitUntil { model.selected!.segments.first?.currentTranslations.count == 1 }
        try require(jobs.values.count == 1 && jobs.values[0].sourceLanguage == "zh-CN" && jobs.values[0].sourceText == "中文最终文本", "mic final translation used typed language instead of recognizer locale")
        print("PASS SAME ClientModel final translation dispatch uses exact recognizer locale and source version (fake translation only)")
    }
    @MainActor static func translationsFixture(directory: URL, fixture: TranslationFixture) throws {
        let controller = DesktopSessionController(permissions: FakePermissions(), capture: FakeCapture(), backend: FakeBackend())
        let model = ClientModel(directory: directory, configURL: configURL(), controller: controller)
        model.archive.sessions = [LocalSession(title: "Translation fixture", segments: [fixture.segment])]
        model.selection = model.archive.sessions[0].id
        try require(model.persist(), "translation fixture persistence")
        let actual = try ArchiveStore(directory: directory).load().sessions[0].segments[0].currentTranslations
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(actual).write(to: directory.appendingPathComponent("observations.json"))
        print("PASS translation fixture actual currentTranslations: \(actual.count)")
    }
    @MainActor static func translationFiltering(directory: URL) throws {
        let source = "exact source"
        var segment = LocalSegment(id: "seg", channelKind: "mic", revisions: [SourceRevision(revision: 1, text: source)], translations: [LocalTranslation(id: "tr", revision: 2, sourceRevision: 1, sourceText: source, targetLanguage: "en", text: "new"), LocalTranslation(id: "tr", revision: 1, sourceRevision: 1, sourceText: source, targetLanguage: "en", text: "old")])
        try require(segment.currentTranslations.map(\.text) == ["new"], "latest translation filtering")
        try segment.appendRevision(SourceRevision(revision: 2, text: "corrected source", status: "corrected"))
        try require(segment.currentTranslations.isEmpty, "stale source translation visible")
        var coordinator = try TextSessionCoordinator(session: LocalSession(title: "translation generations"), config: TextModeConfig.load(configURL()))
        let event = try coordinator.submit(text: source)
        let older = try coordinator.request(segmentID: event.segmentId!, targetLanguage: "en")
        let newer = try coordinator.request(segmentID: event.segmentId!, targetLanguage: "en")
        let stale = try coordinator.accept(older, translatedText: "old")
        let latest = try coordinator.accept(newer, translatedText: "new")
        try require(stale == nil && latest != nil, "translation generations accepted older request")
        let correctionRequest = try coordinator.request(segmentID: event.segmentId!, targetLanguage: "en")
        _ = try coordinator.submit(text: "corrected source", segmentID: event.segmentId!)
        let correctedStale = try coordinator.accept(correctionRequest, translatedText: "stale")
        try require(correctedStale == nil, "corrected source accepted obsolete translation")
        try translationsFixture(directory: directory, fixture: TranslationFixture(case_id: "current_translations", segment: segment))
        print("PASS current translation highest revision and obsolete translation request filtering")
    }
}
