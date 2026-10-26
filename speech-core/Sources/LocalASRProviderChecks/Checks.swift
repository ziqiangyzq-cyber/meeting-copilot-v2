import Foundation
import AVFoundation
import AppleOfflineSpeech
import LocalASRProviders

@MainActor final class FakeBackend: OfflinePCMRecognitionBackend {
    var osAuthorized = true
    var begins = 0, appends = 0, finishes = 0, cancels = 0
    var startError: OfflineSpeechFailure?
    var finishObservation: SpeechBackendObservation?
    var callback: (@MainActor @Sendable (SpeechBackendObservation) -> Void)?
    func begin(locale: OfflineSpeechLocale, deliver: @escaping @MainActor @Sendable (SpeechBackendObservation) -> Void) throws {
        begins += 1; callback = deliver
        if let startError { throw startError }
    }
    func append(_ buffer: AVAudioPCMBuffer) throws { appends += 1 }
    func finishAudio() { finishes += 1; if let finishObservation { emit(finishObservation) } }
    func cancel() { cancels += 1 }
    func emit(_ observation: SpeechBackendObservation) { callback?(observation) }
}
@MainActor final class Probe { var readiness = ASRReadiness(.readyToPrepare); var calls = 0 }
@MainActor final class Events { var values: [ASRProviderEvent] = [] }
enum CheckError: Error { case assertion(String) }
@main struct Checks {
    @MainActor static func main() {
        var passes = 0
        func check(_ value: Bool, _ name: String) throws {
            guard value else { throw CheckError.assertion(name) }; passes += 1; print("PASS \(name)")
        }
        func expect(_ expected: ASRProviderError, _ action: () throws -> Void) throws {
            do { try action(); throw CheckError.assertion("expected error \(expected)") }
            catch let e as ASRProviderError { guard e == expected else { throw CheckError.assertion("wrong error \(e)") } }
        }
        do {
            let fake = FakeBackend(), probe = Probe(), events = Events()
            let factory = ASRBackendFactory(engineVersion: "fake-only/1", inspect: { _ in probe.calls += 1; return probe.readiness }, make: { fake })
            let p = LocalASRProvider(providerID: .appleSpeech, maxInputFrames: 32, finalResultTimeoutSeconds: 2, factory: factory)
            let config = ASRConfiguration(providerID: .appleSpeech, locale: .simplifiedChinese)
            try check(LocalASRRegistry.catalog.count == 2 && LocalASRRegistry.catalog[1].implemented, "catalog Qwen implemented with runtime readiness gate")
            try check(p.inspect(config).state == .readyToPrepare && fake.begins == 0, "inspect creates no recognition task")
            probe.readiness = .init(.permissionRequired, reason: "TEST_PERMISSION")
            try expect(.readiness(probe.readiness)) { _ = try p.load(config) }
            try check(p.activeEngine == nil && fake.begins == 0 && p.lastFailure != nil, "permission denied load preserves idle and starts no task")
            probe.readiness = .init(.readyToPrepare)
            let engine = try p.load(config)
            try check(p.state == .prepared && fake.begins == 0 && engine.engineVersion == "fake-only/1" && engine.modelVersion == nil, "load prepares only and records honest version")
            let bad = ASRConfiguration(providerID: .appleSpeech, locale: .englishUS, modelPath: "/unread/model")
            try expect(.invalidConfiguration("APPLE_MODEL_IS_SYSTEM_MANAGED")) { _ = try p.load(bad) }
            try check(p.activeEngine == engine && p.activeConfiguration == config, "failed configuration switch retains active engine")
            try expect(.providerMismatch) { _ = try p.load(.init(providerID: .qwen3ASR, locale: .englishUS)) }
            let q = LocalASRRegistry.make(.qwen3ASR)
            let qc = ASRConfiguration(providerID: .qwen3ASR, locale: .englishUS, modelPath: "/does/not/exist")
            try expect(.qwen("ASYNC_LOAD_REQUIRED")) { _ = try q.load(qc) }
            try check(q.inspect(qc).state == .unavailable && q.activeEngine == nil, "Qwen missing runtime not prepared or routed to Apple")
            try expect(.speech(.userStartRequired)) { try p.start(intent: .init(), sessionID: "s", channelID: "c", streamID: "st", segmentID: "denied") { events.values.append($0) } }
            try check(fake.begins == 0, "explicit start gate enforced")
            let intent = SpeechStartIntent(userInitiated: true, speechEnabled: true, onDeviceProcessingAuthorized: true)
            try p.start(intent: intent, sessionID: "s", channelID: "c", streamID: "st", segmentID: "one") { events.values.append($0) }
            try expect(.activeRecognition) { _ = try p.load(config) }
            try check(p.state == .listening && fake.begins == 1 && p.activeEngine == engine, "active load rejected without replacing task")
            let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16)!
            buffer.frameLength = 16
            buffer.floatChannelData![0].initialize(repeating: 0, count: 16)
            let range = PCMSourceRange(frameStart: 0, frameEnd: 16, mappingRevision: 1, startNs: 0, endNs: 1_000_000)
            try p.append(buffer, source: range)
            fake.emit(.hypothesis(text: "合成", isFinal: false))
            fake.emit(.hypothesis(text: "合成测试", isFinal: true))
            let count = events.values.count
            fake.emit(.hypothesis(text: "迟到污染", isFinal: true))
            try check(p.state == .finalized && count == 2 && events.values.count == count, "partial final and late callback isolation")
            if case .transcript(let first) = events.values[0].output, case .transcript(let last) = events.values[1].output {
                try check(first.revision == 1 && last.revision == 2 && last.replacesRevision == 1 && last.source == range && events.values[1].engine == engine, "revision source and engine identity bound")
            } else { throw CheckError.assertion("missing transcripts") }
            try p.start(intent: intent, sessionID: "s", channelID: "c", streamID: "st", segmentID: "sync-final") { events.values.append($0) }
            try p.append(buffer, source: range)
            fake.finishObservation = .hypothesis(text: "同步终稿", isFinal: true)
            try p.finishAudio(atUptime: 90)
            try check(p.state == .finalized, "synchronous final not overwritten by finishing")
            fake.finishObservation = nil
            try p.start(intent: intent, sessionID: "s", channelID: "c", streamID: "st", segmentID: "revoked") { events.values.append($0) }
            fake.osAuthorized = false
            try expect(.speech(.osAuthorizationMissing)) { try p.append(buffer, source: range) }
            try check(p.state == .failed && p.lastFailure == .speech(.osAuthorizationMissing), "authorization revocation fails before append")
            fake.osAuthorized = true
            try p.start(intent: intent, sessionID: "s", channelID: "c", streamID: "st", segmentID: "two") { events.values.append($0) }
            try p.append(buffer, source: range); try p.finishAudio(atUptime: 100)
            p.pollFinalDeadline(atUptime: 101)
            try check(p.state == .finishing, "final wait remains bounded but not premature")
            p.pollFinalDeadline(atUptime: 102)
            try check(p.state == .failed && p.lastFailure == .speech(.finalResultTimeout), "final timeout produces explicit failure")
            let oldCallback = fake.callback
            p.unload(); let before = events.values.count
            oldCallback?(.hypothesis(text: "旧模型", isFinal: true))
            try check(p.state == .idle && p.activeEngine == nil && events.values.count == before, "unload clears identity and discards retired callback")
            let newEngine = try p.load(config)
            try check(newEngine.generation > engine.generation, "reload increments generation")
            try p.start(intent: intent, sessionID: "s2", channelID: "c", streamID: "st", segmentID: "cancel") { events.values.append($0) }
            p.cancel(); let cancelledCount = events.values.count
            fake.emit(.hypothesis(text: "取消后", isFinal: false))
            try check(p.state == .cancelled && events.values.count == cancelledCount && fake.cancels > 0, "cancel retires callbacks")
            try p.start(intent: intent, sessionID: "s2", channelID: "c", streamID: "st", segmentID: "limit") { events.values.append($0) }
            try p.append(buffer, source: range)
            try p.append(buffer, source: .init(frameStart: 16, frameEnd: 32, mappingRevision: 1, startNs: 1_000_000, endNs: 2_000_000))
            try expect(.speech(.inputLimitExceeded)) { try p.append(buffer, source: .init(frameStart: 32, frameEnd: 48, mappingRevision: 1, startNs: 2_000_000, endNs: 3_000_000)) }
            try check(p.state == .failed && p.lastFailure == .speech(.inputLimitExceeded), "input limit is failure not silent drop")
            p.unload(); _ = try p.load(config); fake.startError = .recognizerUnavailable
            try expect(.speech(.recognizerUnavailable)) { try p.start(intent: intent, sessionID: "s3", channelID: "c", streamID: "st", segmentID: "failure") { events.values.append($0) } }
            try check(p.state == .failed && p.lastFailure == .speech(.recognizerUnavailable), "backend begin failure retained")
            // Pure status query on the real Apple backend; never begin, request permission or supply audio.
            let apple = LocalASRRegistry.make(.appleSpeech)
            let status = apple.inspect(config)
            print("REAL_APPLE_INSPECT state=\(status.state.rawValue) reason=\(status.reason ?? "none") recognition_tasks=0")
            print("RESULT \(passes)/\(passes) checks passed; real_recognition_tasks=0; permission_requests=0")
        } catch { fputs("FAIL \(error)\n", stderr); exit(1) }
    }
}
