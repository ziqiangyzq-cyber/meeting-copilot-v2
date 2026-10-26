import Foundation
import AVFoundation
import MeetingCopilotAudioCapture
import AppleOfflineSpeech
import RotatingSpeechSession
import DesktopSessionController

@MainActor final class RotationBackend: OfflinePCMRecognitionBackend {
    var osAuthorized = true
    var samples: [Float] = []
    var begins = 0, ends = 0, cancels = 0
    var callback: (@MainActor @Sendable (SpeechBackendObservation) -> Void)?
    let identity: RotatingSpeechTaskIdentity
    var autoFinal: Bool
    var earlyFinal = false
    init(_ identity: RotatingSpeechTaskIdentity, autoFinal: Bool) { self.identity = identity; self.autoFinal = autoFinal }
    func begin(locale: OfflineSpeechLocale, deliver: @escaping @MainActor @Sendable (SpeechBackendObservation) -> Void) throws { begins += 1; callback = deliver }
    func append(_ buffer: AVAudioPCMBuffer) throws {
        for i in 0..<Int(buffer.frameLength) { samples.append(buffer.floatChannelData![0][i]) }
        callback?(.hypothesis(text: "partial-" + identity.segmentId, isFinal: false))
        if earlyFinal { final() }
    }
    func finishAudio() { ends += 1; if autoFinal { final() } }
    func final() { callback?(.hypothesis(text: "final-" + identity.segmentId, isFinal: true)) }
    func cancel() { cancels += 1 }
}
@MainActor final class RotationFactory {
    var backends: [RotationBackend] = [] // Bounded synthetic fixture only, not production ownership.
    var autoFinal = false, earlyFinal = false
    func make(_ identity: RotatingSpeechTaskIdentity) -> any OfflinePCMRecognitionBackend {
        let b = RotationBackend(identity, autoFinal: autoFinal); b.earlyFinal = earlyFinal
        backends.append(b); return b
    }
}
@MainActor final class RotationOutputs { var values: [RotatingSpeechOutput] = []; var reentryRejected = false; var liveCount = 0 }
@MainActor func rotationFixture() -> (DesktopSessionController, Permissions, Capture, RotationFactory, RotationOutputs) {
    let p = Permissions(), c = Capture(), f = RotationFactory(), o = RotationOutputs()
    let d = DesktopSessionController(permissions: p, capture: c, backend: Backend(), backendFactory: { f.make($0) })
    d.onRotatingOutput = { o.values.append($0) }
    d.onLiveOutput = { _ in o.liveCount += 1 }
    return (d,p,c,f,o)
}
func rotatingConfig(capacity: Int = 8, deadline: Double = 2, framesPerPoll: Int = 4) -> RotatingSpeechConfiguration {
    RotatingSpeechConfiguration(sessionId: "rotating-" + UUID().uuidString, channelId: "mic", source: .microphone,
        locale: .simplifiedChinese, maximumInputFrames: 8, maximumFramesPerBlock: 4, maximumBytesPerBlock: 1024,
        queueCapacityBlocks: capacity, maximumBlocksPerPoll: 1, maximumFramesPerPoll: framesPerPoll,
        maxRetiringTasks: 2, finishDeadlineSeconds: deadline)
}
@MainActor func emitSequence(_ capture: Capture, blocks: Int) {
    for block in 0..<blocks {
        let start = block * 4
        let buffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 1000, channels: 1)!, frameCapacity: 4)!
        buffer.frameLength = 4
        for i in 0..<4 { buffer.floatChannelData![0][i] = Float(start + i) }
        capture.handler?(AudioFrame(buffer: buffer, timestamp: SourceTimestamp(source: .microphone,
            hostSeconds: 12 + Double(start) / 1000, samplePosition: Int64(start), sampleRate: 1000,
            presentationSeconds: nil, receivedUptime: 999)))
    }
}
extension Checks {
    @MainActor static func rotatingChecks() async throws {
        try await rotatingGates(); try await rotatingContinuous(); try await rotatingStopDrain()
        try await rotatingFailures(); try await rotatingEarlyFinalAndIsolation()
        print("PASS 5 rotating DesktopSessionController groups; one capture across tasks; zero real recording")
    }
    @MainActor static func rotatingGates() async throws {
        let (d,p,c,f,_) = rotationFixture()
        do { try await d.userPressedStart(intent: DesktopStartIntent(), configuration: rotatingConfig()); throw Failure(message: "rotating unconsented") }
        catch DesktopSessionFailure.capture(.userActionRequired) {}
        for invalid in [rotatingConfig(capacity: 65537), rotatingConfig(framesPerPoll: 3)] {
            do { try await d.userPressedStart(intent: intent, configuration: invalid); throw Failure(message: "rotating invalid queue/batch") }
            catch DesktopSessionFailure.invalidConfiguration {}
        }
        try require(p.reads == 0 && c.starts == 0 && f.backends.isEmpty, "rotating prepermission gate side effects")
        p.mic = false
        do { try await d.userPressedStart(intent: intent, configuration: rotatingConfig()); throw Failure(message: "rotating permission denial") }
        catch DesktopSessionFailure.permissionsMicrophone {}
        try require(c.starts == 0 && f.backends.isEmpty, "rotating denial started backend/device")
        p.mic = true; p.blocked = true
        let old = Task { @MainActor in try await d.userPressedStart(intent: intent, configuration: rotatingConfig()) }
        try await waitUntil { p.waiter != nil }
        try d.userPressedCancel(); let waiter = p.waiter; p.waiter = nil; p.blocked = false
        try await d.userPressedStart(intent: intent, configuration: rotatingConfig())
        waiter?.resume(returning: true)
        do { try await old.value; throw Failure(message: "rotating stale authorization") }
        catch DesktopSessionFailure.startCancelled {}
        try require(c.starts == 1 && f.backends.isEmpty && d.snapshot.deviceStarted && !d.snapshot.audioObserved, "rotating old permission opened capture")
        try d.userPressedCancel()
        print("PASS rotating intent/config/permission gates and stale authorization cancellation")
    }
    @MainActor static func rotatingContinuous() async throws {
        let (d,p,c,f,o) = rotationFixture()
        try await d.userPressedStart(intent: intent, configuration: rotatingConfig())
        d.onRotatingOutput = { [weak d] output in
            o.values.append(output)
            do { try d?.userPressedStop() } catch DesktopSessionFailure.reentrantCall { o.reentryRejected = true } catch {}
        }
        emitSequence(c, blocks: 5)
        try await waitUntil { f.backends.count == 3 && f.backends.last?.samples.count == 4 }
        try require(c.starts == 1 && c.stops == 0 && c.state == .running && p.reads == 2, "task rotation restarted capture or authorization")
        try require(f.backends.map { $0.samples.count } == [8,8,4] && f.backends.flatMap { $0.samples } == (0..<20).map(Float.init), "samples lost/duplicated across 3 tasks")
        try require(Set(f.backends.map { $0.identity.streamId }).count == 3 && Set(f.backends.map { $0.identity.segmentId }).count == 3, "task identities not unique")
        try require(o.reentryRejected && o.liveCount == 0 && d.snapshot.audioObserved && d.snapshot.asrObserved, "rotating raw output/evidence compatibility")
        let dispatches = o.values.compactMap { output -> (RotatingSpeechTaskIdentity, Int64?, Int, Int, UInt64)? in
            guard case .dispatched(_, let id, let timestamp, let range) = output else { return nil }
            return (id, timestamp.samplePosition, range.frameStart, range.frameEnd, range.startNs)
        }
        try require(dispatches.count == 5 && dispatches.map { $0.1! } == [0,4,8,12,16] && dispatches.map { $0.2 } == [0,4,0,4,0] && dispatches.map { $0.3 } == [4,8,4,8,4], "native timestamp/task-local range forwarding")
        try require(dispatches.map { $0.4 } == [12_000_000_000,12_004_000_000,12_008_000_000,12_012_000_000,12_016_000_000], "source clock reset at task boundary")
        f.backends[1].final(); f.backends[0].final() // Deliberately reverse retirement final order.
        try await waitUntil { d.rotatingFinalizedTasks == 2 }
        try require(c.state == .running && c.stops == 0, "retiring final stopped live capture")
        try d.userPressedStop()
        try await waitUntil { f.backends[2].ends == 1 }
        try require(d.snapshot.state == .stopping, "completed before last actual final")
        f.backends[2].final()
        try await waitUntil { d.snapshot.state == .terminal(.completed) }
        try require(d.rotatingStartedTasks == 3 && d.rotatingFinalizedTasks == 3 && d.rotatingRetainedOwnerCount == 0, "finalized owner release")
        try require(d.queueSnapshot?.statistics.acceptedBlocks == 5 && d.queueSnapshot?.statistics.consumedBlocks == 5 && d.queueSnapshot?.statistics.releasedBlocks == 0, "normal rotating stop lost queued PCM")
        let finalIDs = o.values.compactMap { output -> String? in
            if case .transcript(_, let u) = output, u.status == "final" { return u.segmentId }; return nil
        }
        try require(finalIDs == [f.backends[1].identity.segmentId, f.backends[0].identity.segmentId, f.backends[2].identity.segmentId], "out-of-order finals rewritten or lost")
        print("PASS continuous 20 frames / budget8 / block4 / 3 unique tasks, reversed finals, one capture, raw provenance")
    }
    @MainActor static func rotatingStopDrain() async throws {
        let (d,_,c,f,_) = rotationFixture(); f.autoFinal = true
        try await d.userPressedStart(intent: intent, configuration: rotatingConfig())
        emitSequence(c, blocks: 5); try d.userPressedStop()
        try require(c.state == .stopped && f.backends.isEmpty && d.snapshot.state == .stopping, "stop did not precede rotating drain")
        try await waitUntil { d.snapshot.state == .terminal(.completed) }
        try require(f.backends.map { $0.samples.count } == [8,8,4] && c.starts == 1 && d.rotatingFinalizedTasks == 3, "bounded rotating stop drain")
        try require(d.queueSnapshot?.statistics.consumedBlocks == 5 && d.queueSnapshot?.statistics.releasedBlocks == 0, "stop discarded accepted blocks")
        print("PASS stop first then multi-poll rotating drain/endAudio/all actual finals")
    }
    @MainActor static func rotatingFailures() async throws {
        let (d,_,c,f,_) = rotationFixture()
        try await d.userPressedStart(intent: intent, configuration: rotatingConfig(deadline: 0.04))
        emitSequence(c, blocks: 3)
        try await waitUntil { d.snapshot.state == .failed(.rotating(.owner(.speech(.finalResultTimeout)))) }
        try require(c.state == .stopped && c.starts == 1 && d.rotatingRetainedOwnerCount == 0 && f.backends.allSatisfy { $0.cancels > 0 }, "retiring timeout left hardware or owner")
        try await d.userPressedStart(intent: intent, configuration: rotatingConfig(capacity: 1))
        emitSequence(c, blocks: 2)
        try await waitUntil { if case .failed(.rotating(.queue)) = d.snapshot.state { return true }; return false }
        try require(c.state == .stopped && c.starts == 2 && d.queueSnapshot?.statistics.releasedBlocks == 1, "rotating overflow hardware release")
        try await d.userPressedStart(intent: intent, configuration: rotatingConfig()); c.fail()
        try require(d.snapshot.state == .failed(.capture(.deviceInterrupted)) && c.state == .stopped, "rotating capture failure")
        print("PASS rotating live retirement timeout, overflow and capture failure stop hardware without reconnect")
    }
    @MainActor static func rotatingEarlyFinalAndIsolation() async throws {
        let (d,_,c,f,o) = rotationFixture(); f.earlyFinal = true
        try await d.userPressedStart(intent: intent, configuration: rotatingConfig())
        emitSequence(c, blocks: 2)
        try await waitUntil { d.snapshot.state == .failed(.rotating(.owner(.unexpectedFinal))) }
        try require(c.state == .stopped && d.queueSnapshot?.statistics.acceptedBlocks == 2 && d.queueSnapshot?.statistics.consumedBlocks == 1 && d.queueSnapshot?.statistics.releasedBlocks == 1, "rotating early final queue/hardware")
        let final = o.values.compactMap { output -> Int? in if case .transcript(_, let u) = output, u.status == "final" { return u.source.frameEnd }; return nil }
        try require(final == [4], "rotating early final observed text/range lost")
        let oldBackend = f.backends[0], oldHandler = c.handler, count = o.values.count
        oldBackend.final(); try require(o.values.count == count, "late rotating final leaked")
        f.earlyFinal = false
        try await d.userPressedStart(intent: intent, configuration: rotatingConfig())
        oldBackend.final()
        // Old producer is sealed; old callback cannot make a backend in the new generation.
        let buffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 1000, channels: 1)!, frameCapacity: 4)!
        buffer.frameLength = 4
        oldHandler?(AudioFrame(buffer: buffer, timestamp: SourceTimestamp(source: .microphone, hostSeconds: 12, samplePosition: 0, sampleRate: 1000, presentationSeconds: nil, receivedUptime: 999)))
        try await Task.sleep(nanoseconds: 25_000_000)
        try require(f.backends.count == 1 && o.values.count == count && !d.snapshot.audioObserved, "old rotating callback/producer crossed generation")
        try d.userPressedCancel()
        try await d.userPressedStart(intent: intent, configuration: config()); c.emit(); try d.userPressedCancel()
        try require(d.mode == .finite && d.snapshot.state == .terminal(.cancelled), "rotating-to-finite API compatibility")
        print("PASS rotating early-final retention, hardware stop, late final/producer isolation and finite mode compatibility")
    }
}
