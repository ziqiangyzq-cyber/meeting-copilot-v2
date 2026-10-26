import Foundation
import AVFoundation
import MeetingCopilotAudioCapture
import MeetingCopilotPCMBridge
import AppleOfflineSpeech
import LiveSpeechSession

@MainActor final class CountingBackend: OfflinePCMRecognitionBackend {
    var authorized = true
    private(set) var authorizationReads = 0
    var osAuthorized: Bool { authorizationReads += 1; return authorized }
    var begins = 0, ends = 0, cancels = 0
    var frames: [Int] = [], samples: [Float] = [], callbacks: [@MainActor @Sendable (SpeechBackendObservation) -> Void] = []
    var autoFinal = false
    func begin(locale: OfflineSpeechLocale, deliver: @escaping @MainActor @Sendable (SpeechBackendObservation) -> Void) throws {
        begins += 1; callbacks.append(deliver)
    }
    func append(_ buffer: AVAudioPCMBuffer) throws {
        frames.append(Int(buffer.frameLength)); samples.append(buffer.floatChannelData![0][0])
    }
    func finishAudio() {
        ends += 1
        if autoFinal { callbacks.last?(.hypothesis(text: "complete", isFinal: true)) }
    }
    func cancel() { cancels += 1 }
    func partial() { callbacks.last?(.hypothesis(text: "partial", isFinal: false)) }
}
@MainActor final class Recorder { var outputs: [LiveSpeechOutput] = [] }
struct CheckFailure: Error { let message: String }
@MainActor func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CheckFailure(message: message) }
}
let intent = SpeechStartIntent(userInitiated: true, speechEnabled: true, onDeviceProcessingAuthorized: true)
func config(_ segment: String = "segment", capacity: Int = 8, batch: Int = 2, source: AudioSource = .microphone,
            maximum: Int = 100) -> LiveSpeechConfiguration {
    LiveSpeechConfiguration(sessionId: "session", channelId: "channel", streamId: "stream", segmentId: segment,
        source: source, locale: .englishUS, queueCapacityBlocks: capacity, maximumFramesPerBlock: 16,
        maximumBytesPerBlock: 1024, maximumInputFrames: maximum, maximumBlocksPerPoll: batch,
        finishDeadlineSeconds: 2, mappingRevision: 7)
}
func frame(position: Int64? = 100, time: Double? = 12, frames: UInt32 = 4, rate: Double = 1000,
           source: AudioSource = .microphone) -> AudioFrame {
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for index in 0..<Int(frames) { buffer.floatChannelData![0][index] = 0.25 }
    let timestamp = SourceTimestamp(source: source, hostSeconds: source == .microphone ? time : nil,
        samplePosition: position, sampleRate: rate, presentationSeconds: source == .systemAudio ? time : nil,
        receivedUptime: 999999)
    return AudioFrame(buffer: buffer, timestamp: timestamp)
}

struct Checks {
    @MainActor static func main() throws {
        try gating(); try normalStop(); try timeout(); try overflow(); try stale(); try clocks(); try budget(); try cancelAndEarlyFinal()
        print("PASS all LiveSpeechSession synthetic checks (no Apple backend, device or permission query)")
    }
    @MainActor static func gating() throws {
        for denied in [SpeechStartIntent(), SpeechStartIntent(userInitiated: true),
                       SpeechStartIntent(userInitiated: true, speechEnabled: true)] {
            let backend = CountingBackend()
            let session = LiveSpeechSession(backend: backend)
            do { _ = try session.begin(intent: denied, configuration: config()) { _ in }; throw CheckFailure(message: "ungated begin") }
            catch is OfflineSpeechFailure { }
            try require(backend.begins == 0 && backend.authorizationReads == 0 && session.state == .idle, "denied start side effect")
        }
        let b = CountingBackend(); b.authorized = false
        let s = LiveSpeechSession(backend: b)
        do { _ = try s.begin(intent: intent, configuration: config()) { _ in }; throw CheckFailure(message: "authorization missing") }
        catch OfflineSpeechFailure.osAuthorizationMissing { }
        try require(b.begins == 0, "authorization gate begins")
        print("PASS explicit start/authorization gating")
    }
    @MainActor static func normalStop() throws {
        let b = CountingBackend(), r = Recorder()
        let owner = LiveSpeechSession(backend: b)
        let p = try owner.begin(intent: intent, configuration: config()) { r.outputs.append($0) }
        try require(b.begins == 0, "recognizer started before timestamp")
        let borrowed = frame()
        try require(p.enqueue(borrowed) == .accepted, "accept first")
        borrowed.buffer.floatChannelData![0][0] = 0.75
        for i in 1...4 { try require(p.enqueue(frame(position: 100 + Int64(i * 4), time: 12 + Double(i * 4) / 1000)) == .accepted, "accept queued") }
        try owner.poll(generation: p.generation, atUptime: 1)
        try require(b.frames == [4,4] && b.samples == [0.25,0.25], "owned PCM delivered")
        try require(owner.lastMappedRange == PCMSourceRange(frameStart: 4, frameEnd: 8, mappingRevision: 7,
            startNs: 12_004_000_000, endNs: 12_008_000_000), "exact mapped PCM range")
        b.partial()
        try require(r.outputs.count == 1, "partial delivered")
        try owner.finish(generation: p.generation, atUptime: 2)
        try require(owner.state == .draining && b.ends == 0 && b.frames.count == 4, "bounded drain before endAudio")
        try require(p.enqueue(frame()) == .rejectedInactive, "close seals producer")
        b.autoFinal = true
        try owner.poll(generation: p.generation, atUptime: 3)
        try require(b.frames == [4,4,4,4,4] && b.ends == 1 && owner.state == .completed, "normal stop drains all accepted before final")
        try require(owner.queueSnapshot?.statistics.releasedBlocks == 0, "normal stop discarded queue")
        guard case .transcript(_, let final) = r.outputs[r.outputs.count - 2] else { throw CheckFailure(message: "missing final") }
        try require(final.status == "final" && final.source.frameEnd == 20 && final.source.startNs == 12_000_000_000 && final.source.endNs == 12_020_000_000, "final range covers all input")
        print("PASS bounded owned-copy delivery, exact ranges, partials, drain/endAudio/final ordering")
    }
    @MainActor static func timeout() throws {
        let b = CountingBackend(), r = Recorder()
        let owner = LiveSpeechSession(backend: b)
        let p = try owner.begin(intent: intent, configuration: config()) { r.outputs.append($0) }
        _ = p.enqueue(frame()); try owner.finish(generation: p.generation, atUptime: 10)
        try require(owner.state == .finishing, "wait for actual final")
        try owner.poll(generation: p.generation, atUptime: 12)
        try require(owner.state == .incomplete(.speech(.finalResultTimeout)) && b.ends == 1, "deadline terminal")
        try require(r.outputs.count == 1, "fake final generated")
        b.callbacks[0](.hypothesis(text: "late", isFinal: true))
        try require(r.outputs.count == 1, "late final leaks")
        print("PASS finishing deadline, no fake final, late result isolation")
    }
    @MainActor static func overflow() throws {
        let b = CountingBackend(), r = Recorder()
        let owner = LiveSpeechSession(backend: b)
        let p = try owner.begin(intent: intent, configuration: config(capacity: 1)) { r.outputs.append($0) }
        _ = p.enqueue(frame()); try owner.poll(generation: p.generation)
        b.partial()
        _ = p.enqueue(frame(position: 104, time: 12.004))
        try require(p.enqueue(frame(position: 108, time: 12.008)) == .failed(.capacityExceeded(limitBlocks: 1)), "overflow returned")
        try owner.poll(generation: p.generation)
        try require(owner.state == .incomplete(.queue(.capacityExceeded(limitBlocks: 1))) && b.ends == 0, "overflow terminal")
        try require(r.outputs.count == 2 && owner.queueSnapshot?.queuedBlocks == 0, "partial retained and queue released")
        print("PASS overflow incomplete, queue release, emitted partial preserved")
    }
    @MainActor static func stale() throws {
        let b = CountingBackend(), r = Recorder(), s = LiveSpeechSession(backend: b)
        let old = try s.begin(intent: intent, configuration: config()) { r.outputs.append($0) }
        _ = old.enqueue(frame()); try s.poll(generation: old.generation)
        try s.cancel(generation: old.generation)
        let p = try s.begin(intent: intent, configuration: config("next")) { r.outputs.append($0) }
        let count = r.outputs.count
        try require(old.enqueue(frame()) == .rejectedStaleGeneration, "old producer accepted")
        b.callbacks[0](.failure("old error")); b.callbacks[0](.hypothesis(text: "old final", isFinal: true))
        try require(r.outputs.count == count && s.state == .accepting, "old callbacks affect new generation")
        do { try s.finish(generation: old.generation); throw CheckFailure(message: "stale controller") }
        catch LiveSpeechFailure.staleGeneration { }
        _ = p.enqueue(frame()); try s.poll(generation: p.generation)
        try require(b.begins == 2 && s.lastMappedRange?.frameStart == 0, "new generation independent")
        print("PASS stale producer/controller/final/error isolation")
    }
    @MainActor static func clocks() throws {
        let b = CountingBackend(), s = LiveSpeechSession(backend: b)
        let p = try s.begin(intent: intent, configuration: config()) { _ in }
        _ = p.enqueue(frame(time: nil)); try s.poll(generation: p.generation)
        try require(s.state == .incomplete(.missingSourceTimestamp) && b.begins == 0, "receipt-time anchor fallback")
        let p2 = try s.begin(intent: intent, configuration: config("gap")) { _ in }
        _ = p2.enqueue(frame()); _ = p2.enqueue(frame(position: 105, time: 12.004))
        try s.poll(generation: p2.generation)
        try require(s.state == .incomplete(.clock(.nativeSampleDiscontinuity(expected: 104, actual: 105))), "native gap ignored")
        let p3 = try s.begin(intent: intent, configuration: config("fractional")) { _ in }
        _ = p3.enqueue(frame(rate: 1000.5)); try s.poll(generation: p3.generation)
        try require(s.state == .incomplete(.clock(.invalidSampleRate)), "fractional rate truncated")
        let p4 = try s.begin(intent: intent, configuration: config("pts", source: .systemAudio)) { _ in }
        _ = p4.enqueue(frame(position: nil, time: 20, source: .systemAudio))
        _ = p4.enqueue(frame(position: nil, time: 20.004, source: .systemAudio))
        try s.poll(generation: p4.generation)
        try require(s.lastMappedRange?.startNs == 20_004_000_000, "actual PTS source anchor")
        _ = p4.enqueue(frame(position: nil, time: 21, source: .systemAudio)); try s.poll(generation: p4.generation)
        try require(s.state == .incomplete(.timestampGap), "PTS gap ignored")
        print("PASS source-only anchors, native gap, integral rate and PTS gap checks")
    }
    @MainActor static func budget() throws {
        let b = CountingBackend(), s = LiveSpeechSession(backend: b)
        let p = try s.begin(intent: intent, configuration: config(maximum: 4)) { _ in }
        _ = p.enqueue(frame()); _ = p.enqueue(frame(position: 104, time: 12.004)); try s.poll(generation: p.generation)
        try require(s.state == .incomplete(.speech(.inputLimitExceeded)) && b.frames == [4], "finite budget")
        print("PASS finite recognition task budget")
    }
    @MainActor static func cancelAndEarlyFinal() throws {
        let b = CountingBackend(), r = Recorder(), s = LiveSpeechSession(backend: b)
        let p = try s.begin(intent: intent, configuration: config()) { r.outputs.append($0) }
        _ = p.enqueue(frame()); try s.poll(generation: p.generation)
        b.partial()
        _ = p.enqueue(frame(position: 104, time: 12.004))
        b.callbacks[0](.hypothesis(text: "early", isFinal: true))
        try require(s.state == .incomplete(.unexpectedFinal), "early final pretends full recording")
        try require(r.outputs.count == 3, "early final or terminal lost")
        guard case .transcript(_, let observedFinal) = r.outputs[1] else { throw CheckFailure(message: "early final not preserved") }
        try require(observedFinal.text == "early" && observedFinal.status == "final" && observedFinal.source.frameEnd == 4,
                    "early final claims unconsumed audio or loses confirmed text")
        try require(s.queueSnapshot?.statistics.releasedBlocks == 1 && s.queueSnapshot?.queuedBlocks == 0,
                    "unconsumed early-final input not explicitly released")
        b.callbacks[0](.hypothesis(text: "late", isFinal: true))
        try require(r.outputs.count == 3, "early-final terminal accepted late duplicate")
        let p2 = try s.begin(intent: intent, configuration: config("empty")) { _ in }
        try s.finish(generation: p2.generation)
        try require(s.state == .incomplete(.inputClosedBeforeAudio), "empty final fabricated")
        print("PASS unexpected early final and empty-input terminal handling")
    }
}

try Checks.main()
