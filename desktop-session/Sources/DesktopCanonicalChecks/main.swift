import Foundation
import AVFoundation
import MeetingCopilotAudioCapture
import AppleOfflineSpeech
import RotatingSpeechSession
import CanonicalAudioClock
import DesktopSessionController

struct CheckError: Error { let message: String }
@MainActor func check(_ value: @autoclosure () -> Bool, _ message: String) throws { if !value() { throw CheckError(message: message) } }
@MainActor final class Permission: DesktopPermissionGateway {
    func requestMicrophone() async -> Bool { true }
    func requestSpeech() async -> Bool { true }
}
@MainActor final class Capture: DesktopCapturePort {
    var state: CaptureState = .idle
    var onStateChange: (@MainActor @Sendable (CaptureState) -> Void)?
    var handler: AudioFrameHandler?
    var starts = 0, stops = 0
    func start(intent: CaptureIntent, onFrame: @escaping AudioFrameHandler) throws { starts += 1; handler = onFrame; state = .running }
    func stop() { stops += 1; state = .stopped }
    func frame(position: Int64?, time: Double, channels: UInt32 = 1) {
        let buffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 1000, channels: channels)!, frameCapacity: 4)!
        buffer.frameLength = 4
        for ch in 0..<Int(channels) { for i in 0..<4 { buffer.floatChannelData![ch][i] = Float(i) } }
        handler?(AudioFrame(buffer: buffer, timestamp: SourceTimestamp(source: .microphone, hostSeconds: time,
            samplePosition: position, sampleRate: 1000, presentationSeconds: nil, receivedUptime: 999)))
    }
}
@MainActor final class Backend: OfflinePCMRecognitionBackend {
    let osAuthorized = true
    var sink: (@MainActor @Sendable (SpeechBackendObservation) -> Void)?
    var frames = 0
    let early: Bool, throwsAppend: Bool
    init(early: Bool, throwsAppend: Bool) { self.early = early; self.throwsAppend = throwsAppend }
    func begin(locale: OfflineSpeechLocale, deliver: @escaping @MainActor @Sendable (SpeechBackendObservation) -> Void) throws { sink = deliver }
    func append(_ buffer: AVAudioPCMBuffer) throws {
        if throwsAppend { throw OfflineSpeechFailure.backend("INJECTED_APPEND_THROW") }
        frames += Int(buffer.frameLength)
        sink?(.hypothesis(text: "partial", isFinal: false))
        if early { sink?(.hypothesis(text: "observed early final", isFinal: true)) }
    }
    func finishAudio() { sink?(.hypothesis(text: "complete", isFinal: true)) }
    func cancel() {}
}
@MainActor final class Record {
    var metadata: [RotatingCanonicalOutput] = []
    var raw: [RotatingSpeechOutput] = []
    var order: [String] = []
    var backends: [Backend] = []
    var reentryDenied = false
}
@MainActor func make(early: Bool = false, throwsAppend: Bool = false) -> (DesktopSessionController, Capture, Record) {
    let capture = Capture(), record = Record()
    let controller = DesktopSessionController(permissions: Permission(), capture: capture,
        backendFactory: { _ in let b = Backend(early: early, throwsAppend: throwsAppend); record.backends.append(b); return b })
    controller.onCanonicalOutput = { [weak controller] output in
        record.metadata.append(output)
        switch output {
        case .mapped: record.order.append("mapped")
        case .associated: record.order.append("associated")
        case .settled: record.order.append("settled")
        case .terminalCoverage: record.order.append(capture.state == .stopped ? "coverage:hardware-stopped" : "coverage:hardware-running")
        }
        do { try controller?.userPressedStop() } catch DesktopSessionFailure.reentrantCall { record.reentryDenied = true } catch {}
    }
    controller.onRotatingOutput = { output in
        record.raw.append(output)
        switch output {
        case .transcript(_, let u): record.order.append(u.status)
        case .dispatched: record.order.append("dispatched")
        case .terminal: record.order.append("raw-terminal")
        }
    }
    controller.onStateChange = { s in
        switch s.state { case .terminal, .failed: record.order.append("terminal-snapshot"); default: break }
    }
    return (controller,capture,record)
}
func configuration(budget: Int = 10, policy: UInt64? = nil) -> RotatingSpeechConfiguration {
    RotatingSpeechConfiguration(sessionId: UUID().uuidString, channelId: "mic", source: .microphone,
        locale: .simplifiedChinese, maximumInputFrames: budget, maximumFramesPerBlock: 4,
        maximumBytesPerBlock: 1024, queueCapacityBlocks: 8, maximumBlocksPerPoll: 1,
        maximumFramesPerPoll: 4, finishDeadlineSeconds: 1, canonicalMaximumTimestampStepNs: policy)
}
let intent = DesktopStartIntent(userInitiated: true, microphoneEnabled: true, speechEnabled: true, onDeviceProcessingAuthorized: true)
@MainActor func untilTerminal(_ d: DesktopSessionController) async throws {
    let end = ProcessInfo.processInfo.systemUptime + 2
    while true {
        if case .terminal = d.snapshot.state { return }
        if case .failed = d.snapshot.state { return }
        try check(ProcessInfo.processInfo.systemUptime < end, "terminal deadline")
        try await Task.sleep(nanoseconds: 2_000_000)
    }
}
@MainActor func verifyOrder(_ r: Record) throws {
    guard let settled = r.order.lastIndex(of: "settled"), let coverage = r.order.lastIndex(of: "coverage:hardware-stopped"),
          let snapshot = r.order.lastIndex(of: "terminal-snapshot"), let raw = r.order.lastIndex(of: "raw-terminal") else {
        throw CheckError(message: "missing settled/coverage/stopped/snapshot/raw terminal: \(r.order)")
    }
    try check(settled < coverage && coverage < snapshot && snapshot < raw, "terminal order \(r.order)")
    guard let finalCoverage = r.metadata.compactMap({ output -> RotatingCanonicalCoverage? in
        if case .terminalCoverage(_, let c) = output { return c }; return nil
    }).last else { throw CheckError(message: "missing coverage") }
    try check(finalCoverage.ownerQueueAccountingValid, "stable owner/queue counters disagree")
}
@main struct CanonicalChecks {
    @MainActor static func main() async {
        do {
            try await continuousAssociation(); try await rawOverlapAndLegacy(); try await earlyFinal()
            try await thrownAppend(); try await discontinuities(); try await noNativeStep()
            print("PASS 6 canonical integration increment groups; no old 12 groups rerun; fake permission/capture/backend only")
        } catch { print("FAIL canonical increment: \(error)"); exit(1) }
    }
    @MainActor static func continuousAssociation() async throws {
        let (d,c,r) = make()
        try await d.userPressedStart(intent: intent, configuration: configuration())
        for n in 0..<5 { c.frame(position: Int64(n*4), time: 1 + Double(n*4)/1000) }
        try d.userPressedStop(); try await untilTerminal(d)
        let spans = r.metadata.compactMap { output -> RotatingTaskCanonicalSpan? in if case .associated(_, let s) = output { return s }; return nil }
        let mapped = r.metadata.compactMap { output -> CanonicalAudioBlock? in if case .mapped(_, _, let b) = output { return b }; return nil }
        try check(r.backends.map { $0.frames } == [8,8,4], "wholeblock budget10 incorrectly exact-partitioned")
        try check(spans.map { $0.taskStartGlobalFrame } == [0,0,8,8,16] && spans.map { $0.taskLocalFrameStart } == [0,4,0,4,0], "actual UUID task global/local association")
        try check(Set(spans.map { $0.task.streamId }).count == 3 && Set(mapped.map { $0.anchor.epochID }).count == 1, "UUID tasks confused with epoch")
        try check(mapped.map { $0.globalFrameStart } == [0,4,8,12,16] && mapped.last?.endNs == 1_020_000_000, "global nominal mapping")
        let cov = d.canonicalCoverage!
        try check(cov.completionCoverageValid && cov.mappedFrames == 20 && cov.recognitionConsumedFrames == 20 && cov.backendAcceptedFrames == 20 && cov.validatedFinalFrames == 20 && cov.validatedFinalTasks == 3, "four layer completion coverage")
        try check(c.starts == 1 && r.reentryDenied, "metadata callback reentry/capture restart")
        try verifyOrder(r)
        print("PASS budget10/block4 actual8/8/4 UUID association, one epoch, full four-layer coverage")
    }
    @MainActor static func rawOverlapAndLegacy() async throws {
        let (d,c,r) = make()
        try await d.userPressedStart(intent: intent, configuration: configuration())
        c.frame(position: 0, time: 1.0000000006)
        c.frame(position: 4, time: 1.0035000006) // native continuous, raw 500000ns overlap vs nominal
        try d.userPressedStop(); try await untilTerminal(d)
        let mapped = r.metadata.compactMap { output -> CanonicalAudioBlock? in if case .mapped(_, _, let b) = output { return b }; return nil }
        let ranges = r.raw.compactMap { output -> PCMSourceRange? in if case .dispatched(_, _, _, let range) = output { return range }; return nil }
        try check(mapped.count == 2 && mapped[1].rawObservation.hostSeconds == 1.0035000006 && mapped[1].diagnostic.residualNs == -500_000, "raw overlap overwritten or lost")
        try check(mapped[0].startNs == 1_000_000_001 && mapped[1].startNs == 1_004_000_001 && ranges[0].startNs == 1_000_000_000, "nominal nearest-anchor/floor-boundary vs original floor range changed")
        try check(mapped[0].anchor.format.channelCount == 1 && !mapped[0].anchor.format.encoding.isEmpty && mapped[0].rawObservation.receivedUptime == 999, "actual PCM format/raw absent")
        try check(d.canonicalCoverage!.completionCoverageValid, "native overlap incorrectly discontinuous")
        print("PASS raw500000ns overlap preserved; nominal basis separate; legacy ns/source ranges unchanged")
    }
    @MainActor static func earlyFinal() async throws {
        let (d,c,r) = make(early: true)
        try await d.userPressedStart(intent: intent, configuration: configuration())
        c.frame(position: 0, time: 1); c.frame(position: 4, time: 1.004)
        try await untilTerminal(d)
        let cov = d.canonicalCoverage!
        try check(cov.mappedBlocks == 1 && cov.recognitionConsumedBlocks == 0 && cov.backendAcceptedBlocks == 1 && cov.uncertainAfterMappingBlocks == 1 && cov.validatedFinalFrames == 0, "early final mapping confused with ASR coverage")
        try check(cov.canonicalAccountingValid && cov.queueAccountingValid && !cov.completionCoverageValid && cov.queue?.statistics.acceptedBlocks == 2 && cov.queue?.statistics.consumedBlocks == 1 && cov.queue?.statistics.releasedBlocks == 1, "early final queue accounting")
        try check(cov.releasedWithoutTransferBlocks == 1 && r.order.firstIndex(of: "associated")! < r.order.firstIndex(of: "final")!, "early final association metadata missing before ASR")
        try check(r.order.contains("final") && !r.order.contains("dispatched") && c.state == .stopped, "early final legacy contract")
        try verifyOrder(r)
        print("PASS earlyfinal mapped/associated before ASR, uncertain settlement, backend accepted separate, stable terminal queue")
    }
    @MainActor static func thrownAppend() async throws {
        let (d,c,r) = make(throwsAppend: true)
        try await d.userPressedStart(intent: intent, configuration: configuration())
        c.frame(position: 0, time: 1); c.frame(position: 4, time: 1.004)
        try await untilTerminal(d)
        let cov = d.canonicalCoverage!
        try check(cov.mappedBlocks == 1 && cov.backendAcceptedBlocks == 0 && cov.recognitionConsumedBlocks == 0 && cov.rejectedAfterMappingBlocks == 1 && cov.ownerReturnedBlocks == 0, "append throw claimed consumption")
        try check(cov.canonicalAccountingValid && cov.queueAccountingValid && cov.queue?.statistics.consumedBlocks == 0 && cov.queue?.statistics.releasedBlocks == 2 && cov.releasedWithoutTransferBlocks == 1, "throw accounting")
        try verifyOrder(r)
        print("PASS mapped-but-append-throw rejected; failed transferred block + queued block released and reconciled")
    }
    @MainActor static func discontinuities() async throws {
        for formatChange in [false,true] {
            let (d,c,r) = make()
            try await d.userPressedStart(intent: intent, configuration: configuration())
            c.frame(position: 0, time: 1)
            c.frame(position: formatChange ? 4 : 5, time: 1.004, channels: formatChange ? 2 : 1)
            try await untilTerminal(d)
            let cov = d.canonicalCoverage!
            try check(cov.mappedBlocks == 1 && cov.rejectedBeforeMappingBlocks == 1 && cov.recognitionConsumedBlocks == 1 && cov.backendAcceptedBlocks == 1 && cov.queueAccountingValid && cov.canonicalAccountingValid, "discontinuity committed or auto-newEpoch")
            try check(r.backends.count == 1 && r.backends[0].frames == 4 && c.state == .stopped, "discontinuity reached ASR or reconnected")
            guard case .failed(.rotating(.canonicalDiscontinuity)) = d.snapshot.state else { throw CheckError(message: "canonical reason not preserved") }
            try verifyOrder(r)
        }
        print("PASS format/native discontinuities reject without map commit, new epoch or ASR")
    }
    @MainActor static func noNativeStep() async throws {
        let (d,c,_) = make()
        try await d.userPressedStart(intent: intent, configuration: configuration(policy: 100_000))
        c.frame(position: nil, time: 1); c.frame(position: nil, time: 1.0035)
        try await untilTerminal(d)
        guard case .failed(.rotating(.canonicalDiscontinuity(.explicitStepOverlap(let ns)))) = d.snapshot.state else { throw CheckError(message: "no-native overlap silently accepted") }
        try check(ns == 500_000 && d.canonicalCoverage!.mappedBlocks == 1 && d.canonicalCoverage!.rejectedBeforeMappingBlocks == 1 && c.state == .stopped, "step overlap coverage")
        print("PASS no-native500000ns step overlap exceeds configured policy, explicit failclosed")
    }
}
