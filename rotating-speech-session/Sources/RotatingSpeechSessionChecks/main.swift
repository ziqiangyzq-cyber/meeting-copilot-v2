import Foundation
import AVFoundation
import MeetingCopilotAudioCapture
import MeetingCopilotPCMBridge
import AppleOfflineSpeech
import RotatingSpeechSession

@MainActor final class Backend: OfflinePCMRecognitionBackend {
    var osAuthorized: Bool { true }
    var begins = 0, ends = 0, cancels = 0
    var samples: [Float] = [], blocks: [Int] = []
    var callback: (@MainActor @Sendable (SpeechBackendObservation) -> Void)?
    var autoFinal = false, failAppend = false
    func begin(locale: OfflineSpeechLocale, deliver: @escaping @MainActor @Sendable (SpeechBackendObservation) -> Void) throws {
        begins += 1; callback = deliver
    }
    func append(_ buffer: AVAudioPCMBuffer) throws {
        if failAppend { throw OfflineSpeechFailure.backend("INJECTED") }
        blocks.append(Int(buffer.frameLength))
        samples.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
    func finishAudio() { ends += 1; if autoFinal { final() } }
    func cancel() { cancels += 1 }
    func final(_ text: String = "actual final") { callback?(.hypothesis(text: text, isFinal: true)) }
}
@MainActor final class Factory {
    var backends: [Backend] = []
    var identities: [RotatingSpeechTaskIdentity] = []
    var autoFinal = false
    func make(_ id: RotatingSpeechTaskIdentity) -> any OfflinePCMRecognitionBackend {
        let backend = Backend(); backend.autoFinal = autoFinal
        backends.append(backend); identities.append(id); return backend
    }
}
@MainActor final class Recorder { var outputs: [RotatingSpeechOutput] = [] }
struct Failure: Error { let message: String }
@MainActor func require(_ test: @autoclosure () -> Bool, _ message: String) throws {
    guard test() else { throw Failure(message: message) }
}
let intent = SpeechStartIntent(userInitiated: true, speechEnabled: true, onDeviceProcessingAuthorized: true)
func config(capacity: Int = 8, batch: Int = 8, retiring: Int = 3, source: AudioSource = .microphone,
            budget: Int = 8, maxBlock: UInt32 = 4, frameBatch: Int = 32) -> RotatingSpeechConfiguration {
    RotatingSpeechConfiguration(sessionId: "meeting", channelId: "channel", source: source, locale: .englishUS,
        maximumInputFrames: budget, maximumFramesPerBlock: maxBlock, maximumBytesPerBlock: 1024,
        queueCapacityBlocks: capacity, maximumBlocksPerPoll: batch, maximumFramesPerPoll: frameBatch,
        maxRetiringTasks: retiring, finishDeadlineSeconds: 2, mappingRevision: 7)
}
func frame(_ start: Int, source: AudioSource = .microphone, native: Bool = true, count: UInt32 = 4) -> AudioFrame {
    let buffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 1000, channels: 1)!, frameCapacity: count)!
    buffer.frameLength = count
    for i in 0..<Int(count) { buffer.floatChannelData![0][i] = Float(start + i) }
    return AudioFrame(buffer: buffer, timestamp: SourceTimestamp(source: source,
        hostSeconds: source == .microphone ? 12 + Double(start) / 1000 : nil,
        samplePosition: native ? 100 + Int64(start) : nil, sampleRate: 1000,
        presentationSeconds: source == .systemAudio ? 20 + Double(start) / 1000 : nil, receivedUptime: 999999))
}
struct Checks {
    @MainActor static func main() throws {
        try continuousAndFinals(); try drain(); try staleAndEarlyFinal(); try pressureTimeoutOverflow()
        try clocksAndBounds(); try failuresAndGating(); try lifetime()
        print("PASS all RotatingSpeechSession synthetic checks; no Apple backend/device tasks")
    }
    @MainActor static func continuousAndFinals() throws {
        let factory = Factory(), r = Recorder()
        let s = RotatingSpeechSession { factory.make($0) }
        let p = try s.begin(intent: intent, configuration: config()) { r.outputs.append($0) }
        for start in stride(from: 0, to: 20, by: 4) {
            let f = frame(start); try require(p.enqueue(f) == .accepted, "enqueue")
            f.buffer.floatChannelData![0][0] = -1 // prove borrowed-buffer isolation
            try s.poll(generation: p.generation, atUptime: 1)
        }
        try require(factory.backends.count == 3 && factory.backends.map(\.blocks) == [[4,4],[4,4],[4]], "20 frames / 8 budget / 4 blocks")
        try require(factory.backends.flatMap(\.samples) == (0..<20).map(Float.init), "PCM missing/duplicated/corrupted")
        try require(factory.backends.map(\.ends) == [1,1,0] && s.state == .accepting, "rotation stopped whole capture")
        try require(Set(factory.identities.map(\.streamId)).count == 3 && Set(factory.identities.map(\.segmentId)).count == 3, "unique identities")
        let dispatches = r.outputs.compactMap { output -> (RotatingSpeechTaskIdentity, SourceTimestamp, PCMSourceRange)? in
            if case .dispatched(_, let task, let timestamp, let range) = output { return (task,timestamp,range) }; return nil
        }
        for i in 0..<5 {
            let expected = i * 4, local = i % 2 * 4
            try require(dispatches[i].0 == factory.identities[i / 2], "block identity")
            try require(dispatches[i].1 == frame(expected).timestamp, "raw timestamp changed")
            try require(dispatches[i].2 == PCMSourceRange(frameStart: local, frameEnd: local + 4, mappingRevision: 7,
                startNs: 12_000_000_000 + UInt64(expected) * 1_000_000,
                endNs: 12_000_000_000 + UInt64(expected + 4) * 1_000_000), "source range/time")
        }
        try s.finish(generation: p.generation, atUptime: 1.1)
        factory.backends[1].final("second first")
        factory.backends[2].final("third second")
        try s.poll(generation: p.generation, atUptime: 1.2)
        try require(s.state == .awaitingFinals && s.finalizedTasks == 2 && s.retainedOwnerCount == 1, "premature complete / unpurged owners")
        factory.backends[0].final("first last")
        try s.poll(generation: p.generation, atUptime: 1.3)
        try require(s.state == .completed && s.finalizedTasks == 3 && s.retainedOwnerCount == 0, "all ranges final")
        let finals = r.outputs.compactMap { output -> OfflineTranscriptUpdate? in
            if case .transcript(_, let update) = output { return update }; return nil
        }
        try require(finals.map(\.text) == ["second first","third second","first last"] && finals.map(\.revision) == [1,1,1], "raw final ordering/revision")
        try require(finals.map(\.source.frameEnd) == [8,4,8] && finals.map(\.streamId) == [factory.identities[1].streamId,factory.identities[2].streamId,factory.identities[0].streamId], "final identity/coverage")
        try require(s.queueSnapshot?.statistics.releasedBlocks == 0, "normal PCM discarded")
        print("PASS continuous 20-frame capture / 3 distinct tasks / exact PCM and native source clocks / out-of-order finals")
    }
    @MainActor static func drain() throws {
        let f = Factory(); f.autoFinal = true
        let s = RotatingSpeechSession { f.make($0) }
        let p = try s.begin(intent: intent, configuration: config(batch: 1)) { _ in }
        for i in stride(from: 0, to: 20, by: 4) { _ = p.enqueue(frame(i)) }
        try s.finish(generation: p.generation, atUptime: 1)
        try require(s.state == .draining && f.backends[0].samples.count == 4 && f.backends[0].ends == 0, "finish discarded queued blocks")
        try require(p.enqueue(frame(20)) == .rejectedInactive, "close did not seal")
        for _ in 0..<4 { try s.poll(generation: p.generation, atUptime: 1) }
        try require(s.state == .completed && f.backends.flatMap(\.samples) == (0..<20).map(Float.init), "stop drain segmented PCM")
        try require(f.backends.map(\.ends) == [1,1,1], "endAudio once each")
        print("PASS stop seals ingress, bounded drains all accepted PCM across rotations and waits for actual finals")
    }
    @MainActor static func staleAndEarlyFinal() throws {
        let f = Factory(), r = Recorder(), s = RotatingSpeechSession { _ in Backend() }
        let p0 = try s.begin(intent: intent, configuration: config()) { _ in }
        try s.cancel(generation: p0.generation)
        try require(p0.enqueue(frame(0)) == .rejectedStaleGeneration, "cancel ingress")
        let owner = RotatingSpeechSession { f.make($0) }
        let old = try owner.begin(intent: intent, configuration: config()) { r.outputs.append($0) }
        _ = old.enqueue(frame(0)); try owner.poll(generation: old.generation, atUptime: 1)
        try owner.cancel(generation: old.generation)
        let p = try owner.begin(intent: intent, configuration: config()) { r.outputs.append($0) }
        let before = r.outputs.count
        f.backends[0].callback?(.failure("old")); f.backends[0].final("old final")
        try require(r.outputs.count == before && owner.state == .accepting && old.enqueue(frame(0)) == .rejectedStaleGeneration, "old generation leaks")
        do { try owner.poll(generation: old.generation); throw Failure(message: "stale poll accepted") }
        catch RotatingSpeechFailure.staleGeneration { }
        _ = p.enqueue(frame(0)); try owner.poll(generation: p.generation, atUptime: 1)
        f.backends[1].final("early actual text")
        try require(owner.state == .incomplete(.owner(.unexpectedFinal)) && owner.retainedOwnerCount == 0, "early final silently continues")
        try require(r.outputs.contains { if case .transcript(_, let u) = $0 { return u.text == "early actual text" }; return false }, "actual early final lost")
        let n = r.outputs.count; f.backends[1].final("late"); try require(r.outputs.count == n, "late terminal repeats")
        print("PASS cancellation, old generation producer/controller/callback isolation and early final text preserved incomplete")
    }
    @MainActor static func pressureTimeoutOverflow() throws {
        let f = Factory(), s = RotatingSpeechSession { f.make($0) }
        let p = try s.begin(intent: intent, configuration: config(retiring: 1)) { _ in }
        for i in stride(from: 0, to: 20, by: 4) { _ = p.enqueue(frame(i)) }
        try s.poll(generation: p.generation, atUptime: 1)
        try require(s.state == .incomplete(.retiringTaskLimit) && f.backends.count == 2 && s.retainedOwnerCount == 0, "retirement pressure unbounded")
        let timeout = RotatingSpeechSession { _ in Backend() }
        let tp = try timeout.begin(intent: intent, configuration: config()) { _ in }
        _ = tp.enqueue(frame(0)); try timeout.finish(generation: tp.generation, atUptime: 10)
        try timeout.poll(generation: tp.generation, atUptime: 12)
        try require(timeout.state == .incomplete(.owner(.speech(.finalResultTimeout))) && timeout.retainedOwnerCount == 0, "deadline")
        let overflow = RotatingSpeechSession { _ in Backend() }
        let op = try overflow.begin(intent: intent, configuration: config(capacity: 1)) { _ in }
        _ = op.enqueue(frame(0))
        try require(op.enqueue(frame(4)) == .failed(.capacityExceeded(limitBlocks: 1)), "overflow result")
        try overflow.poll(generation: op.generation, atUptime: 1)
        try require(overflow.state == .incomplete(.queue(.capacityExceeded(limitBlocks: 1))) && overflow.queueSnapshot?.statistics.releasedBlocks == 1, "overflow incomplete diagnostics")
        let tf = Factory(), retiringTimeout = RotatingSpeechSession { tf.make($0) }
        let rtp = try retiringTimeout.begin(intent: intent, configuration: config()) { _ in }
        for i in [0,4,8] { _ = rtp.enqueue(frame(i)) }
        try retiringTimeout.poll(generation: rtp.generation, atUptime: 1)
        try require(tf.backends.count == 2 && tf.backends[1].samples.count == 4, "new task did not ingest before old final")
        try retiringTimeout.poll(generation: rtp.generation, atUptime: 3)
        try require(retiringTimeout.state == .incomplete(.owner(.speech(.finalResultTimeout))) && tf.backends[1].cancels == 1,
                    "retiring owner deadline not polled/cancelled active")
        print("PASS bounded retirement pressure, active/retiring final timeouts, queue overflow explicitly incomplete")
    }
    @MainActor static func clocksAndBounds() throws {
        let f = Factory(); f.autoFinal = true
        let s = RotatingSpeechSession { f.make($0) }
        let p = try s.begin(intent: intent, configuration: config(source: .systemAudio)) { _ in }
        for i in stride(from: 0, to: 20, by: 4) { _ = p.enqueue(frame(i, source: .systemAudio, native: false)) }
        try s.finish(generation: p.generation, atUptime: 1)
        try require(s.state == .completed && f.backends.count == 3, "PTS rotation")
        let gap = RotatingSpeechSession { _ in Backend() }
        let gp = try gap.begin(intent: intent, configuration: config()) { _ in }
        for i in [0,4,9] { _ = gp.enqueue(frame(i)) }
        try gap.poll(generation: gp.generation, atUptime: 1)
        try require(gap.state == .incomplete(.clock(.nativeSampleDiscontinuity(expected: 108, actual: 109))), "rotation hides native gap")
        let pts = RotatingSpeechSession { _ in Backend() }
        let pp = try pts.begin(intent: intent, configuration: config(source: .systemAudio)) { _ in }
        for i in [0,4,20] { _ = pp.enqueue(frame(i, source: .systemAudio, native: false)) }
        try pts.poll(generation: pp.generation, atUptime: 1)
        try require(pts.state == .incomplete(.timestampGap), "rotation hides PTS gap")
        let b = Factory(), bounded = RotatingSpeechSession { b.make($0) }
        let bp = try bounded.begin(intent: intent, configuration: config(frameBatch: 4)) { _ in }
        for i in [0,4,8] { _ = bp.enqueue(frame(i)) }
        try bounded.poll(generation: bp.generation, atUptime: 1)
        try require(b.backends[0].samples.count == 4 && bounded.queueSnapshot?.queuedFrames == 8, "per-poll frame bound")
        try bounded.cancel(generation: bp.generation)
        print("PASS PTS/native continuity across rotation and explicit per-poll frame bound")
    }
    @MainActor static func failuresAndGating() throws {
        let f = Factory(), s = RotatingSpeechSession { f.make($0) }
        do { _ = try s.begin(intent: SpeechStartIntent(), configuration: config()) { _ in }; throw Failure(message: "ungated") }
        catch OfflineSpeechFailure.userStartRequired { }
        try require(f.backends.isEmpty && s.state == .idle, "gate side effects")
        do { _ = try s.begin(intent: intent, configuration: config(budget: 3)) { _ in }; throw Failure(message: "block > budget configuration") }
        catch RotatingSpeechFailure.invalidConfiguration { }
        let p = try s.begin(intent: intent, configuration: config()) { _ in }
        try require(p.enqueue(frame(0, count: 5)) == .failed(.blockTooLarge), "oversized block accepted")
        try s.poll(generation: p.generation, atUptime: 1)
        try require(s.state == .incomplete(.queue(.blockTooLarge)), "block failure incomplete")
        let backend = Backend(); backend.failAppend = true
        let fail = RotatingSpeechSession { _ in backend }
        let fp = try fail.begin(intent: intent, configuration: config()) { _ in }
        _ = fp.enqueue(frame(0)); try fail.poll(generation: fp.generation, atUptime: 1)
        try require(fail.state == .incomplete(.owner(.speech(.backend("INJECTED")))), "backend failure incomplete")
        let empty = RotatingSpeechSession { _ in Backend() }
        let ep = try empty.begin(intent: intent, configuration: config()) { _ in }
        try empty.finish(generation: ep.generation, atUptime: 1)
        try require(empty.state == .incomplete(.noAudio), "empty meeting completed")
        let reused = Backend(); reused.autoFinal = true
        let reuse = RotatingSpeechSession { _ in reused }
        let rp = try reuse.begin(intent: intent, configuration: config()) { _ in }
        for i in [0,4,8] { _ = rp.enqueue(frame(i)) }
        try reuse.poll(generation: rp.generation, atUptime: 1)
        try require(reuse.state == .incomplete(.reusedBackend) && reused.begins == 1, "completed backend reused")
        let earlyFactory = Factory(); earlyFactory.autoFinal = true
        let early = RotatingSpeechSession { earlyFactory.make($0) }
        let earlyP = try early.begin(intent: intent, configuration: config(budget: 10)) { _ in }
        for i in stride(from: 0, to: 20, by: 4) { _ = earlyP.enqueue(frame(i)) }
        try early.finish(generation: earlyP.generation, atUptime: 1)
        try require(early.state == .completed && earlyFactory.backends.map(\.blocks) == [[4,4],[4,4],[4]], "early rotation split/lost block")
        print("PASS intent gating, block budget validation, backend failure/reuse, empty input and early whole-block rotation")
    }
    @MainActor static func lifetime() throws {
        // No factory-held strong references: finalized backend must deallocate after owner retirement.
        weak var retired: Backend?
        var allocations = 0
        let s = RotatingSpeechSession { _ in
            let b = Backend(); b.autoFinal = true; allocations += 1
            if allocations == 1 { retired = b }
            return b
        }
        let p = try s.begin(intent: intent, configuration: config(batch: 1, retiring: 1)) { _ in }
        for i in stride(from: 0, to: 400, by: 4) {
            _ = p.enqueue(frame(i)); try s.poll(generation: p.generation, atUptime: 1)
            try require(s.retainedOwnerCount <= 2, "long meeting owners accumulated")
        }
        try s.finish(generation: p.generation, atUptime: 1)
        try require(s.state == .completed && allocations == 50 && retired == nil && s.finalizedTasks == 50, "finite bookkeeping/backend lifetime")
        print("PASS 50-task continuous meeting with bounded owners and released completed backend references")
    }
}

try Checks.main()
