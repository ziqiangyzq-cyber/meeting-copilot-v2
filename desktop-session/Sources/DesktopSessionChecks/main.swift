import Foundation
import AVFoundation
import MeetingCopilotAudioCapture
import AppleOfflineSpeech
import LiveSpeechSession
import DesktopSessionController

struct Failure: Error { let message: String }
@MainActor func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw Failure(message: message) }
}
@MainActor final class Permissions: DesktopPermissionGateway {
    var mic = true, speech = true, reads = 0
    var blocked = false
    var waiter: CheckedContinuation<Bool, Never>?
    func requestMicrophone() async -> Bool {
        reads += 1
        if blocked { return await withCheckedContinuation { waiter = $0 } }
        return mic
    }
    func requestSpeech() async -> Bool { reads += 1; return speech }
}
@MainActor final class Capture: DesktopCapturePort {
    var state: CaptureState = .idle
    var onStateChange: (@MainActor @Sendable (CaptureState) -> Void)?
    var handler: AudioFrameHandler?
    var starts = 0, stops = 0
    var failStart = false
    func start(intent: CaptureIntent, onFrame: @escaping AudioFrameHandler) throws {
        starts += 1; handler = onFrame
        if failStart { state = .failed(.deviceInterrupted); throw CaptureFailure.deviceInterrupted }
        state = .running
    }
    func stop() { stops += 1; state = .stopped }
    func emit(_ position: Int64 = 0) {
        let buffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 1000, channels: 1)!, frameCapacity: 4)!
        buffer.frameLength = 4
        for i in 0..<4 { buffer.floatChannelData![0][i] = 0.25 }
        handler?(AudioFrame(buffer: buffer, timestamp: SourceTimestamp(source: .microphone,
            hostSeconds: 12 + Double(position) / 1000, samplePosition: position, sampleRate: 1000,
            presentationSeconds: nil, receivedUptime: 999)))
    }
    func fail() { state = .failed(.deviceInterrupted); onStateChange?(state) }
}
@MainActor final class Backend: OfflinePCMRecognitionBackend {
    var osAuthorized = true
    var begins = 0, appended = 0, ends = 0, cancels = 0
    var callback: (@MainActor @Sendable (SpeechBackendObservation) -> Void)?
    var autoFinal = true, earlyFinalOnAppend = false
    func begin(locale: OfflineSpeechLocale, deliver: @escaping @MainActor @Sendable (SpeechBackendObservation) -> Void) throws {
        begins += 1; callback = deliver
    }
    func append(_ buffer: AVAudioPCMBuffer) throws {
        appended += Int(buffer.frameLength)
        if earlyFinalOnAppend {
            callback?(.hypothesis(text: "部分文本", isFinal: false))
            callback?(.hypothesis(text: "确切早final", isFinal: true))
        }
    }
    func finishAudio() { ends += 1; if autoFinal { callback?(.hypothesis(text: "真实合成final", isFinal: true)) } }
    func cancel() { cancels += 1 }
}
@MainActor final class Outputs { var values: [LiveSpeechOutput] = []; var reentrantRejected = false }
let intent = DesktopStartIntent(userInitiated: true, microphoneEnabled: true, speechEnabled: true, onDeviceProcessingAuthorized: true)
func config(_ segment: String = UUID().uuidString, capacity: Int = 8, batch: Int = 1, budget: Int = 100) -> LiveSpeechConfiguration {
    LiveSpeechConfiguration(sessionId: "s", channelId: "mic", streamId: "stream-" + segment, segmentId: segment,
        source: .microphone, locale: .simplifiedChinese, queueCapacityBlocks: capacity,
        maximumFramesPerBlock: 16, maximumBytesPerBlock: 1024, maximumInputFrames: budget,
        maximumBlocksPerPoll: batch, finishDeadlineSeconds: 0.04)
}
@MainActor func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    while !condition() {
        try require(ProcessInfo.processInfo.systemUptime < deadline, "controller wait timeout")
        try await Task.sleep(nanoseconds: 2_000_000)
    }
}
@MainActor func fixture() -> (DesktopSessionController, Permissions, Capture, Backend, Outputs) {
    let p = Permissions(), c = Capture(), b = Backend(), o = Outputs()
    let d = DesktopSessionController(permissions: p, capture: c, backend: b)
    d.onLiveOutput = { o.values.append($0) }
    return (d,p,c,b,o)
}
@main struct Checks {
    @MainActor static func main() async {
        do {
            try await gates(); try await permissionCancellation(); try await normal(); try await deadline()
            try await faults(); try await earlyFinal(); try await budgetAndCancel()
            print("PASS 7 finite DesktopSessionController synthetic groups")
            try await rotatingChecks()
            print("PASS all 12 DesktopSessionController groups; fake permission/capture/backend only; zero real recording")
        } catch {
            print("FAIL DesktopSessionController checks: \(error)")
            exit(1)
        }
    }
    @MainActor static func gates() async throws {
        let (d,p,c,b,_) = fixture()
        try require(p.reads == 0 && c.starts == 0 && b.begins == 0 && d.snapshot.state == .idle, "construction side effects")
        do { try await d.userPressedStart(intent: DesktopStartIntent(), configuration: config()); throw Failure(message: "default intent accepted") }
        catch DesktopSessionFailure.capture(.userActionRequired) {}
        try require(p.reads == 0 && c.starts == 0, "gate touched permissions/device")
        for invalid in [config(capacity: 65537), LiveSpeechConfiguration(sessionId: "s", channelId: "mic", streamId: "st", segmentId: "invalid-bytes", source: .microphone, locale: .simplifiedChinese, queueCapacityBlocks: 2, maximumBytesPerBlock: Int.max, maximumInputFrames: 100)] {
            do { try await d.userPressedStart(intent: intent, configuration: invalid); throw Failure(message: "invalid queue accepted") }
            catch DesktopSessionFailure.invalidConfiguration {}
        }
        try require(p.reads == 0 && c.starts == 0, "invalid queue touched permission/device")
        p.mic = false
        do { try await d.userPressedStart(intent: intent, configuration: config()); throw Failure(message: "mic denial accepted") }
        catch DesktopSessionFailure.permissionsMicrophone {}
        try require(p.reads == 1 && c.starts == 0 && b.begins == 0, "mic denial side effects")
        p.mic = true; p.speech = false
        do { try await d.userPressedStart(intent: intent, configuration: config()); throw Failure(message: "speech denial accepted") }
        catch DesktopSessionFailure.permissionsSpeech {}
        try require(c.starts == 0 && b.begins == 0, "speech denial begins")
        print("PASS construction, explicit intent, microphone and Speech denial")
    }
    @MainActor static func permissionCancellation() async throws {
        let (d,p,c,_,_) = fixture(); p.blocked = true
        let start = Task { @MainActor in try await d.userPressedStart(intent: intent, configuration: config()) }
        try await waitUntil { p.waiter != nil }
        do { try await d.userPressedStart(intent: intent, configuration: config()); throw Failure(message: "duplicate start accepted") }
        catch DesktopSessionFailure.alreadyActive {}
        try d.userPressedStop()
        let oldWaiter = p.waiter; p.waiter = nil; p.blocked = false
        try await d.userPressedStart(intent: intent, configuration: config())
        oldWaiter?.resume(returning: true)
        do { try await start.value; throw Failure(message: "cancelled permission wait accepted") }
        catch DesktopSessionFailure.startCancelled {}
        try require(c.starts == 1 && p.reads == 3 && d.snapshot.state == .capturing, "old permission completion altered new attempt")
        try d.userPressedCancel()
        print("PASS stop while authorization waits, duplicate start refusal, stale authorization across new attempt")
    }
    @MainActor static func normal() async throws {
        let (d,_,c,b,o) = fixture()
        try await d.userPressedStart(intent: intent, configuration: config())
        try require(d.snapshot.deviceStarted && !d.snapshot.audioObserved && !d.snapshot.asrObserved && b.begins == 0, "device start fabricated observations")
        c.emit(); try await waitUntil { b.appended == 4 }
        try require(d.snapshot.audioObserved && !d.snapshot.asrObserved, "PCM observation missing")
        d.onLiveOutput = { [weak d] output in
            o.values.append(output)
            do { try d?.userPressedStop() } catch DesktopSessionFailure.reentrantCall { o.reentrantRejected = true } catch {}
        }
        b.callback?(.hypothesis(text: "部分文本", isFinal: false))
        try require(d.snapshot.asrObserved && o.reentrantRejected, "partial or reentrant gate")
        c.emit(4); c.emit(8); c.emit(12)
        try d.userPressedStop()
        try require(c.state == .stopped && b.ends == 0 && d.snapshot.state == .stopping, "stop before bounded drain")
        try await waitUntil { d.snapshot.state == .terminal(.completed) }
        try require(b.appended == 16 && b.ends == 1 && o.values.count == 3, "drain/final/terminal order")
        guard case .transcript(_, let final) = o.values[1] else { throw Failure(message: "missing final") }
        try require(final.status == "final" && final.source.frameEnd == 16, "final range")
        let old = b.callback; old?(.hypothesis(text: "late", isFinal: true))
        try require(o.values.count == 3, "late final leaked")
        try await d.userPressedStart(intent: intent, configuration: config()); try d.userPressedCancel()
        print("PASS one poll task, evidence flags, partial, multi-poll drain, final, stale callback, restart")
    }
    @MainActor static func deadline() async throws {
        let (d,_,c,b,o) = fixture(); b.autoFinal = false
        try await d.userPressedStart(intent: intent, configuration: config())
        c.emit(); try d.userPressedStop()
        try await waitUntil { d.snapshot.state == .terminal(.incomplete(.speech(.finalResultTimeout))) }
        try require(b.ends == 1 && o.values.count == 1 && c.state == .stopped, "deadline fabricated final or live capture")
        print("PASS stop deadline with no fake final")
    }
    @MainActor static func faults() async throws {
        let (d,_,c,b,_) = fixture(); c.failStart = true
        do { try await d.userPressedStart(intent: intent, configuration: config()); throw Failure(message: "device failure accepted") }
        catch DesktopSessionFailure.capture(.deviceInterrupted) {}
        try require(c.state == .stopped && b.begins == 0, "device failure release")
        c.failStart = false
        try await d.userPressedStart(intent: intent, configuration: config(capacity: 1))
        c.emit(); c.emit(4)
        try await waitUntil { if case .terminal(.incomplete) = d.snapshot.state { return true }; return false }
        try require(c.state == .stopped && c.starts == 2, "overflow did not stop or restarted")
        try await d.userPressedStart(intent: intent, configuration: config()); c.fail()
        try require(d.snapshot.state == .failed(.capture(.deviceInterrupted)) && c.state == .stopped && c.starts == 3, "runtime device failure")
        print("PASS device start/runtime failures and queue overflow stop/release")
    }
    @MainActor static func earlyFinal() async throws {
        let (d,_,c,b,o) = fixture()
        b.earlyFinalOnAppend = true
        try await d.userPressedStart(intent: intent, configuration: config())
        c.emit(); c.emit(4)
        try await waitUntil { d.snapshot.state == .terminal(.incomplete(.unexpectedFinal)) }
        try require(c.state == .stopped && b.appended == 4, "early final falsely completed or consumed next block")
        try require(o.values.count == 3, "partial/final/terminal forwarding")
        guard case .transcript(_, let update) = o.values[1] else { throw Failure(message: "early final not forwarded") }
        try require(update.status == "final" && update.text == "确切早final" && update.source.frameEnd == 4, "observed early final text/source")
        print("early-final actual queue snapshot: \(String(describing: d.queueSnapshot))")
        try require(d.queueSnapshot?.statistics.acceptedBlocks == 2 && d.queueSnapshot?.statistics.consumedBlocks == 1 && d.queueSnapshot?.statistics.releasedBlocks == 1, "early final queue release counters")
        b.callback?(.hypothesis(text: "late", isFinal: true))
        try require(o.values.count == 3, "duplicate early final leaked")
        print("PASS observed early-final forwarding then incomplete and immediate hardware stop")
    }
    @MainActor static func budgetAndCancel() async throws {
        let (d,_,c,b,o) = fixture()
        try await d.userPressedStart(intent: intent, configuration: config(budget: 4))
        c.emit(); c.emit(4)
        try await waitUntil { d.snapshot.state == .terminal(.incomplete(.speech(.inputLimitExceeded))) }
        try require(c.state == .stopped && b.appended == 4, "finite input budget")
        try await d.userPressedStart(intent: intent, configuration: config())
        c.emit(); try d.userPressedCancel()
        try require(d.snapshot.state == .terminal(.cancelled) && c.state == .stopped, "cancel release")
        let count = o.values.count; c.emit(4)
        try await Task.sleep(nanoseconds: 25_000_000)
        try require(o.values.count == count, "sealed producer/poll after cancel")
        print("PASS finite budget, cancellation, rejected late capture; no rotation")
    }
}
