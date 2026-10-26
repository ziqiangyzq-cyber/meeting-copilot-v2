import Foundation
import AVFoundation
import MeetingCopilotAudioCapture
import AppleOfflineSpeech
import RotatingSpeechSession
import DesktopSessionController
import SpeechCore
import MeetingCopilotCore
import ClientRuntime

struct Failure: Error { let message: String }
@MainActor func require(_ ok: @autoclosure () -> Bool, _ message: String) throws {
    if !ok() { throw Failure(message: message) }
}
@MainActor func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 3
    while !predicate() {
        try require(ProcessInfo.processInfo.systemUptime < deadline, "controller/model timeout")
        try await Task.sleep(nanoseconds: 2_000_000)
    }
}
@MainActor final class Permissions: DesktopPermissionGateway {
    var reads = 0, mic = true
    func requestMicrophone() async -> Bool { reads += 1; return mic }
    func requestSpeech() async -> Bool { reads += 1; return true }
}
@MainActor final class Capture: DesktopCapturePort {
    var state: CaptureState = .idle
    var onStateChange: (@MainActor @Sendable (CaptureState) -> Void)?
    var handler: AudioFrameHandler?
    var starts = 0, stops = 0
    func start(intent: CaptureIntent, onFrame: @escaping AudioFrameHandler) throws {
        starts += 1; handler = onFrame; state = .running
    }
    func stop() { if state == .running || isFailed { stops += 1 }; state = .stopped }
    private var isFailed: Bool { if case .failed = state { return true }; return false }
    func fail() { state = .failed(.deviceInterrupted); onStateChange?(state) }
    func emit(position: Int, pts: Double? = nil, rawTimestamp: SourceTimestamp? = nil) {
        let buffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 1000, channels: 1)!, frameCapacity: 4)!
        buffer.frameLength = 4
        for i in 0..<4 { buffer.floatChannelData![0][i] = Float(position + i) }
        handler?(AudioFrame(buffer: buffer, timestamp: rawTimestamp ?? SourceTimestamp(source: .microphone,
            hostSeconds: pts ?? (12 + Double(position) / 1000), samplePosition: Int64(position), sampleRate: 1000,
            presentationSeconds: pts, receivedUptime: 999)))
    }
}
@MainActor final class Backend: OfflinePCMRecognitionBackend {
    var osAuthorized = true
    let identity: RotatingSpeechTaskIdentity
    var callback: (@MainActor @Sendable (SpeechBackendObservation) -> Void)?
    var samples: [Float] = []
    var ends = 0, cancels = 0
    var autoFinal = false, throwAppend = false, earlyFinal = false
    var beforeASR: (() -> Void)?
    init(_ identity: RotatingSpeechTaskIdentity) { self.identity = identity }
    func begin(locale: OfflineSpeechLocale, deliver: @escaping @MainActor @Sendable (SpeechBackendObservation) -> Void) throws { callback = deliver }
    func append(_ buffer: AVAudioPCMBuffer) throws {
        if throwAppend { throw Failure(message: "synthetic_append_failure") }
        for i in 0..<Int(buffer.frameLength) { samples.append(buffer.floatChannelData![0][i]) }
        beforeASR?()
        // Synchronous callback deliberately precedes the rotating owner's dispatched notification.
        callback?(.hypothesis(text: "partial-" + identity.segmentId, isFinal: false))
        if earlyFinal { final() }
    }
    func finishAudio() { ends += 1; if autoFinal { final() } }
    func final() { callback?(.hypothesis(text: "final-" + identity.segmentId, isFinal: true)) }
    func cancel() { cancels += 1 }
}
@MainActor final class Factory {
    var backends: [Backend] = []
    var autoFinal = false, throwAppend = false, earlyFinal = false
    var beforeASR: (() -> Void)?
    func make(_ identity: RotatingSpeechTaskIdentity) -> any OfflinePCMRecognitionBackend {
        let b = Backend(identity); b.autoFinal = autoFinal; b.throwAppend = throwAppend; b.earlyFinal = earlyFinal; b.beforeASR = beforeASR
        backends.append(b); return b
    }
}
@MainActor func configuration(_ id: String, deadline: Double = 1, budget: Int = 8) -> RotatingSpeechConfiguration {
    RotatingSpeechConfiguration(sessionId: id, channelId: "mic", source: .microphone, locale: .simplifiedChinese,
        maximumInputFrames: budget, maximumFramesPerBlock: 4, maximumBytesPerBlock: 1024,
        queueCapacityBlocks: 8, maximumBlocksPerPoll: 1, maximumFramesPerPoll: 4,
        maxRetiringTasks: 2, finishDeadlineSeconds: deadline)
}
@MainActor func configURL() -> URL { URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("text-mode-config.json") }
@MainActor func make(_ directory: URL) -> (ClientModel, DesktopSessionController, Permissions, Capture, Factory) {
    let p = Permissions(), c = Capture(), f = Factory()
    let d = DesktopSessionController(permissions: p, capture: c, backendFactory: { f.make($0) })
    let m = ClientModel(directory: directory, configURL: configURL(), controller: d)
    m.add(demo: false)
    return (m,d,p,c,f)
}
@MainActor func emit20(_ c: Capture) { for position in stride(from: 0, to: 20, by: 4) { c.emit(position: position) } }
@MainActor func journal(_ session: LocalSession) throws -> [SpeechEvent] { try session.speechJournal.map { try SpeechEvent.decode($0) } }

@main struct Checks {
    @MainActor static func main() async {
        do {
            let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("evidence/continuous-" + UUID().uuidString)
            try await continuous(root.appendingPathComponent("continuous"))
            try await stopDrain(root.appendingPathComponent("drain"))
            try await isolation(root.appendingPathComponent("isolation"))
            try await budget10(root.appendingPathComponent("budget10"))
            try await canonicalFailures(root.appendingPathComponent("canonical-failures"))
            try await ptsProbe(root.appendingPathComponent("pts"))
            try await invalidRaw(root.appendingPathComponent("invalid-raw"))
            if !CommandLine.arguments.contains("--canonical-only") { try await failures(root.appendingPathComponent("failures")) }
            try await publicationFailure(root.appendingPathComponent("publication"))
            try legacyMetadata()
            print("PASS ContinuousClientChecks: SAME UI ClientRuntime.ClientModel/controller/reducer/journal/store; real permissions=0 devices=0 Apple backend tasks=0")
            print("EVIDENCE_ROOT=\(root.path)")
        } catch { print("FAIL ContinuousClientChecks: \(error)"); exit(1) }
    }
    @MainActor static func continuous(_ directory: URL) async throws {
        var p: Permissions? = Permissions(), c: Capture? = Capture(), f: Factory? = Factory()
        let factory = f!
        var d: DesktopSessionController? = DesktopSessionController(permissions: p!, capture: c!, backendFactory: { factory.make($0) })
        var m: ClientModel? = ClientModel(directory: directory, configURL: configURL(), controller: d!)
        weak var weakModel = m; weak var weakController = d; weak var weakStore = m?.store
        m!.add(demo: false)
        let id = m!.selection!
        let evidence = CanonicalEvidence()
        factory.beforeASR = {
            let disk = try? ArchiveStore(directory: directory).load()
            let metadata = disk?.sessions.first { $0.id == id }?.captureAttempts.last?.canonicalMetadata
            evidence.preASR.append(metadata?.associations.last?.blockID == metadata?.blocks.last?.blockID && metadata?.associations.isEmpty == false)
        }
        try require(m!.rotatingEnabled && !m!.microphoneEnabled && p!.reads == 0 && c!.starts == 0 && f!.backends.isEmpty, "construction/restore side effects")
        await m!.startCapture(configuration: configuration(id))
        try require(p!.reads == 0 && c!.starts == 0, "default-off gate")
        m!.inputText = "typed before rotation"; m!.submitText(translate: false); m!.editingSegmentID = nil
        m!.microphoneEnabled = true
        await m!.startCapture(configuration: configuration(id))
        let rawCallback = d!.onRotatingOutput!
        d!.onRotatingOutput = { output in
            if case .terminal = output {
                let disk = try? ArchiveStore(directory: directory).load()
                evidence.terminalDurable = disk?.sessions.first { $0.id == id }?.captureAttempts.last?.canonicalMetadata?.terminalCoverage != nil
            }
            rawCallback(output)
        }
        emit20(c!)
        try await waitUntil { f!.backends.count == 3 && f!.backends[2].samples.count == 4 }
        try require(f!.backends.map { $0.samples.count } == [8,8,4] && f!.backends.flatMap { $0.samples } == (0..<20).map(Float.init), "8/8/4 exact samples")
        try require(p!.reads == 2 && c!.starts == 1 && c!.stops == 0, "rotation reopened capture/permissions")
        let tasks = m!.selected!.captureAttempts.last!.allTaskIdentities
        try require(tasks.count == 3 && Set(tasks.map(\.streamID)).count == 3 && Set(tasks.map(\.segmentID)).count == 3, "dynamic unique task registration")
        let blocks = tasks.flatMap { $0.sourceBlocks ?? [] }
        try require(blocks.count == 5 && blocks.map { $0.samplePosition! } == [0,4,8,12,16]
                    && blocks.map(\.frameStart) == [0,4,0,4,0] && blocks.map(\.frameEnd) == [4,8,4,8,4], "raw dispatch timestamp/task-local frame provenance")
        try require(blocks.map(\.startNS) == ["12000000000","12004000000","12008000000","12012000000","12016000000"], "raw task-local clock changed")
        try require(tasks.allSatisfy { $0.firstObservedBy == "transcript" }, "sync-before-dispatched registration was not demonstrated")
        let beforeFinal = try journal(m!.selected!)
        for task in tasks {
            let opened = beforeFinal.firstIndex { $0.type == "audio.stream_opened" && $0.streamId == task.streamID }!
            let transcript = beforeFinal.firstIndex { $0.type == "asr.segment" && $0.segmentId == task.segmentID }!
            try require(opened < transcript && beforeFinal.filter { $0.type == "audio.stream_opened" && $0.streamId == task.streamID }.count == 1, "stream not idempotently registered before synchronous transcript")
        }
        m!.inputText = "typed during rotation"; m!.submitText(translate: false); m!.editingSegmentID = nil
        f!.backends[1].final(); f!.backends[0].final()
        try await waitUntil { d!.rotatingFinalizedTasks == 2 }
        let immediate = try ArchiveStore(directory: directory).load().sessions.first { $0.id == id }!
        try require(immediate.captureAttempts.last!.lifecycle == "capturing" && immediate.segments.filter { $0.channelKind == "mic" && $0.current?.status == "final" }.count == 2, "task finals prematurely completed attempt or not durable")
        m!.stopCapture()
        try await waitUntil { f!.backends[2].ends == 1 }
        try require(m!.captureActive && m!.selected!.captureAttempts.last!.lifecycle == "stopping", "completed before all task finals")
        f!.backends[2].final()
        try await waitUntil { !m!.captureActive }
        let session = m!.selected!
        try require(session.captureAttempts.last!.lifecycle == "completed" && session.captureAttempts.last!.allTaskIdentities.allSatisfy(\.finalObserved), "all-finals drained completion missing")
        for (i, backend) in f!.backends.enumerated() {
            let segment = session.segments.first { $0.id == backend.identity.segmentId }!
            let current = segment.current!
            let count = i < 2 ? 8 : 4
            try require(current.status == "final" && current.text == "final-" + backend.identity.segmentId, "observed final text lost")
            try require(current.startNS == String(12_000_000_000 + i * 8_000_000) && current.endNS == String(12_000_000_000 + i * 8_000_000 + count * 1_000_000), "raw source ns rewritten")
            try require(current.sourceSpans == [SourceAudioSpan(channelId: "mic", streamId: backend.identity.streamId, frameStart: 0, frameEnd: count, mappingRevision: 1)], "task-local native frame spans changed")
        }
        let events = try journal(session)
        try require(events.map(\.eventSeq) == Array(1...events.count), "one-global-seq typed/streams/mic/state collision")
        let finalIDs = events.filter { $0.type == "asr.segment" && $0.channelKind == "mic" && $0.status == "final" }.map { $0.segmentId! }
        try require(finalIDs == [tasks[1].segmentID,tasks[0].segmentID,tasks[2].segmentID], "out-of-order final arrival changed journal")
        try require(session.chronologicalSegments.filter { $0.channelKind == "mic" }.map(\.id) == tasks.map(\.segmentID), "display order uses arrival instead of source ns")
        let q = d!.queueSnapshot!
        try require(q.statistics.acceptedBlocks == 5 && q.statistics.consumedBlocks == 5 && q.statistics.releasedBlocks == 0 && q.queuedBlocks == 0, "normal drain queue accounting")
        let metadata = session.captureAttempts.last!.canonicalMetadata!
        try require(evidence.preASR.count == 5 && evidence.preASR.allSatisfy { $0 } && evidence.terminalDurable, "association not durable before sync ASR / terminalCoverage not durable before raw terminal")
        try require(metadata.blocks.map(\.globalFrameStart) == [0,4,8,12,16] && metadata.blocks.map(\.globalFrameEnd) == [4,8,12,16,20], "canonical global adjacency lost")
        for (index, task) in tasks.enumerated() {
            let spans = metadata.associations.filter { $0.streamID == task.streamID && $0.segmentID == task.segmentID }
            try require(spans.first?.globalFrameStart == UInt64(index * 8) && spans.last?.globalFrameEnd == UInt64(index < 2 ? (index + 1) * 8 : 20)
                && spans.allSatisfy { $0.taskStartGlobalFrame == UInt64(index * 8) && $0.basis == "nominalFromEpochAnchor" }, "actual backend task canonical spans are not 0..8,8..16,16..20")
        }
        try require(metadata.settlements.count == 5 && metadata.settlements.allSatisfy { $0.backendAccepted && $0.ownerReturned && $0.disposition == "recognitionConsumed" && $0.failure == nil }, "settled evidence changed")
        let coverage = metadata.terminalCoverage!
        try require(coverage == LocalCanonicalCoverage(d!.canonicalCoverage!) && coverage.completionCoverageValid && coverage.canonicalAccountingValid && coverage.queueAccountingValid && coverage.mappedFrames == 20 && coverage.validatedFinalFrames == 20 && coverage.startedTasks == 3 && coverage.validatedFinalTasks == 3, "terminal projection not actual complete coverage")
        let markdown = String(data: try NoteOperations.exportData(session, format: .markdown), encoding: .utf8)!
        for task in tasks { try require(markdown.contains(task.streamID) && markdown.contains(task.segmentID), "Markdown dropped task identities") }
        try require(markdown.contains("nominalFromEpochAnchor") && markdown.contains("epoch \(metadata.blocks[0].anchor.epochID)") && markdown.contains("task-local source") && markdown.contains("completionCoverageValid true"), "Markdown lost nominal epoch basis/raw distinction/completion flag")
        let frozen = m!.archive
        m = nil; d = nil; p = nil; c = nil; f = nil
        try await Task.sleep(nanoseconds: 25_000_000)
        try require(weakModel == nil && weakController == nil && weakStore == nil, "model/controller/store not truly destroyed")
        let p2 = Permissions(), c2 = Capture(), f2 = Factory()
        let d2 = DesktopSessionController(permissions: p2, capture: c2, backendFactory: { f2.make($0) })
        let reopened = ClientModel(directory: directory, configURL: configURL(), controller: d2)
        try require(reopened.archive == frozen && reopened.selected!.captureAttempts.last!.lifecycle == "completed" && reopened.selected!.segments.filter { $0.channelKind == "mic" && $0.current?.status == "final" }.count == 3, "actual store reopen lost three finals/completed")
        try require(p2.reads == 0 && c2.starts == 0 && f2.backends.isEmpty, "reopen launched devices/tasks")
        try JSONEncoder().encode(reopened.archive).write(to: directory.appendingPathComponent("reopened-observations.json"))
        print("PASS budget8/block4 continuous20 samples -> 8/8/4, unique identities, sync-before-dispatched dynamic stream registration, reversed finals, raw ns/spans, typed interleave/global seq, true destroy/store reopen")
    }
    @MainActor static func stopDrain(_ directory: URL) async throws {
        let (m,d,_,c,f) = make(directory); f.autoFinal = true; m.microphoneEnabled = true
        await m.startCapture(configuration: configuration(m.selection!))
        emit20(c); m.stopCapture()
        try require(c.state == .stopped && f.backends.isEmpty && m.captureActive && m.selected!.captureAttempts.last!.lifecycle == "stopping", "stop must stop hardware before queued drain")
        try await waitUntil { !m.captureActive }
        try require(f.backends.map { $0.samples.count } == [8,8,4] && d.rotatingFinalizedTasks == 3 && m.selected!.captureAttempts.last!.lifecycle == "completed", "multi-poll stop drain lost tasks/finals")
        print("PASS stop hardware then real multi-poll drain/all-finals completion")
    }
    @MainActor static func isolation(_ directory: URL) async throws {
        let (m,d,_,c,f) = make(directory); m.microphoneEnabled = true
        await m.startCapture(configuration: configuration(m.selection!))
        let canonicalBox = CanonicalBox(), oldCanonical = d.onCanonicalOutput!
        d.onCanonicalOutput = { output in oldCanonical(output); canonicalBox.outputs.append(output) }
        c.emit(position: 0)
        try await waitUntil { f.backends.count == 1 && f.backends[0].samples.count == 4 }
        let original = m.archive
        for output in canonicalBox.outputs { d.onCanonicalOutput?(output) }
        try require(m.archive == original, "duplicate canonical callback added metadata/save generation/journal seq")
        let oldCanonicalOutputs = canonicalBox.outputs
        let oldOutput = d.onRotatingOutput!, oldState = d.onStateChange!, oldHandler = c.handler!, oldBackend = f.backends[0]
        let rawBox = RawBox(); d.onRotatingOutput = { output in oldOutput(output); rawBox.outputs.append(output) }
        oldBackend.callback?(.hypothesis(text: "old partial", isFinal: false))
        let oldRaw = rawBox.outputs.last!
        m.cancelCapture()
        await m.startCapture(configuration: configuration(m.selection!))
        c.emit(position: 0)
        try await waitUntil { f.backends.count == 2 && f.backends[1].samples.count == 4 }
        let before = m.archive
        oldOutput(oldRaw); oldState(d.snapshot); oldBackend.final(); d.onRotatingOutput?(oldRaw)
        for output in oldCanonicalOutputs { oldCanonical(output); d.onCanonicalOutput?(output) }
        let buffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 1000, channels: 1)!, frameCapacity: 4)!
        buffer.frameLength = 4
        oldHandler(AudioFrame(buffer: buffer, timestamp: SourceTimestamp(source: .microphone, hostSeconds: 12, samplePosition: 0, sampleRate: 1000, presentationSeconds: nil, receivedUptime: 999)))
        try await Task.sleep(nanoseconds: 25_000_000)
        try require(m.archive == before && f.backends.count == 2, "old attempt callback/generation/producer entered new attempt")
        let oldID = m.selection!; m.add(demo: false)
        try require(!m.captureActive && c.state == .stopped && m.archive.sessions.first { $0.id == oldID }!.captureAttempts.last!.lifecycle == "cancelled", "selection cancel")
        print("PASS old model callbacks/owner generation/producer isolated; selection cancels capture")
    }
    @MainActor static func failures(_ directory: URL) async throws {
        let (m,d,p,c,f) = make(directory); m.microphoneEnabled = true
        p.mic = false; await m.startCapture(configuration: configuration(m.selection!))
        try require(!m.captureActive && c.starts == 0 && f.backends.isEmpty && m.selected!.captureAttempts.last!.failure == "permissionsMicrophone", "permission failure not persisted")
        p.mic = true; f.earlyFinal = true
        await m.startCapture(configuration: configuration(m.selection!)); c.emit(position: 0); c.emit(position: 4)
        try await waitUntil { !m.captureActive }
        try require(m.selected!.captureAttempts.last!.lifecycle == "incomplete" && m.selected!.segments.first?.current?.status == "final" && c.state == .stopped, "early final must be retained with incomplete attempt")
        var q = d.queueSnapshot!
        try require(q.statistics.acceptedBlocks == 2 && q.statistics.consumedBlocks == 1 && q.statistics.releasedBlocks == 1 && q.queuedBlocks == 0, "early final accounting 2/1/1/0")
        f.earlyFinal = false; f.throwAppend = true
        await m.startCapture(configuration: configuration(m.selection!)); c.emit(position: 0); c.emit(position: 4)
        try await waitUntil { !m.captureActive }
        q = d.queueSnapshot!
        // Frozen canonical pipeline throws the failed outer consumer: failed block is released, never consumed.
        try require(q.statistics.acceptedBlocks == 2 && q.statistics.consumedBlocks == 0 && q.statistics.releasedBlocks == 2 && q.queuedBlocks == 0, "consumerthrow accounting MUST be 2/0/2/0, never fake consumption of failed append")
        try require(m.selected!.captureAttempts.last!.lifecycle == "incomplete" && c.state == .stopped, "backend failure left hardware running")
        let failedMetadata = m.selected!.captureAttempts.last!.canonicalMetadata!
        let failedCoverage = failedMetadata.terminalCoverage!
        try require(failedMetadata.blocks.count == 1 && failedMetadata.associations.count == 1 && failedMetadata.settlements.count == 1
            && failedMetadata.settlements[0].disposition == "rejectedAfterMapping" && !failedMetadata.settlements[0].backendAccepted
            && !failedMetadata.settlements[0].ownerReturned && failedMetadata.settlements[0].failure != nil
            && failedMetadata.settlements[0].rawObservation.samplePosition == 0, "first append throw lost rejected/raw failure metadata")
        try require(failedCoverage == LocalCanonicalCoverage(d.canonicalCoverage!) && failedCoverage.transferredBlocks == 1 && failedCoverage.mappedFrames == 4
            && failedCoverage.recognitionConsumedBlocks == 0 && failedCoverage.recognitionConsumedFrames == 0
            && failedCoverage.backendAcceptedBlocks == 0 && failedCoverage.backendAcceptedFrames == 0 && failedCoverage.ownerReturnedBlocks == 0
            && failedCoverage.rejectedAfterMappingBlocks == 1 && failedCoverage.rejectedAfterMappingFrames == 4
            && failedCoverage.uncertainAfterMappingBlocks == 0 && failedCoverage.validatedFinalTasks == 0 && failedCoverage.validatedFinalFrames == 0
            && failedCoverage.queue?.acceptedBlocks == 2 && failedCoverage.queue?.releasedBlocks == 2 && failedCoverage.releasedWithoutTransferBlocks == 1
            && failedCoverage.canonicalAccountingValid && failedCoverage.queueAccountingValid && failedCoverage.ownerQueueAccountingValid && !failedCoverage.completionCoverageValid,
            "first append throw fabricated consumption or lost released/untransferred coverage")
        let failedDisk = try ArchiveStore(directory: directory).load()
        try require(failedDisk == m.archive, "failed canonical metadata not durable")
        f.throwAppend = false
        await m.startCapture(configuration: configuration(m.selection!, deadline: 0.04)); c.emit(position: 0)
        try await waitUntil { f.backends.last!.samples.count == 4 }
        let partial = m.selected!.segments.first { $0.id == f.backends.last!.identity.segmentId }!.current!.text
        m.stopCapture(); try await waitUntil { !m.captureActive }
        try require(m.selected!.captureAttempts.last!.lifecycle == "incomplete" && m.selected!.segments.contains { $0.current?.text == partial && $0.current?.status == "partial" }, "timeout invented final/lost partial")
        await m.startCapture(configuration: configuration(m.selection!)); c.emit(position: 0)
        try await waitUntil { f.backends.last!.samples.count == 4 }
        c.fail()
        try require(!m.captureActive && c.state == .stopped && d.snapshot.state == .failed(.capture(.deviceInterrupted)) && m.selected!.captureAttempts.last!.failure == String(describing: DesktopSessionFailure.capture(.deviceInterrupted)), "capture failure lost exact controller error")
        print("PASS permission/early-final/backend consumerthrow/timeout/capture failures preserve observed text and stop hardware; earlyfinal queue2/1/1/0; throw queue2/0/2/0 and full rejected layers")
    }
    @MainActor static func publicationFailure(_ directory: URL) async throws {
        let (m,_,_,c,f) = make(directory); m.microphoneEnabled = true
        await m.startCapture(configuration: configuration(m.selection!)); c.emit(position: 0)
        try await waitUntil { f.backends.count == 1 && f.backends[0].samples.count == 4 }
        let competingStore = ArchiveStore(directory: directory)
        var disk = try competingStore.load(); disk.sessions[0].notes = "newer disk preserved"
        let newer = try competingStore.save(disk)
        f.backends[0].callback?(.hypothesis(text: "unsaved rotating raw text", isFinal: false))
        try await waitUntil { !m.captureActive }
        try require(c.state == .stopped && m.error != nil && m.unsavedCaptureText == "unsaved rotating raw text" && m.selected!.captureAttempts.last!.lifecycle == "incomplete", "publication fail must preserve text/error and incomplete marker")
        let actual = try competingStore.load()
        try require(actual == newer, "publication failure overwrote newer disk")
        print("PASS real ArchiveStore publication conflict preserves newer disk/raw text; attempt incomplete; hardware stopped")
    }
    @MainActor static func budget10(_ directory: URL) async throws {
        let (m,d,p,c,f) = make(directory); m.microphoneEnabled = true; f.autoFinal = true
        await m.startCapture(configuration: configuration(m.selection!, budget: 10))
        emit20(c); m.stopCapture(); try await waitUntil { !m.captureActive }
        let session = m.selected!, metadata = session.captureAttempts.last!.canonicalMetadata!
        try require(f.backends.map { $0.samples.count } == [8,8,4] && f.backends.flatMap { $0.samples } == (0..<20).map(Float.init), "budget10/block4 actual samples not 8/8/4")
        try require(metadata.associations.count == 5 && Set(metadata.associations.map(\.segmentID)).count == 3, "budget10 association count/identity lost")
        for (index, backend) in f.backends.enumerated() {
            let spans = metadata.associations.filter { $0.segmentID == backend.identity.segmentId && $0.streamID == backend.identity.streamId }
            try require(spans.first?.globalFrameStart == UInt64(index * 8) && spans.last?.globalFrameEnd == UInt64(index < 2 ? (index + 1) * 8 : 20)
                && spans.allSatisfy { $0.taskStartGlobalFrame == UInt64(index * 8) }, "actual budget10 backend UUID spans substituted by 0/10 exact partitions")
        }
        let coverage = metadata.terminalCoverage!
        try require(coverage == LocalCanonicalCoverage(d.canonicalCoverage!) && coverage.mappedFrames == 20 && coverage.backendAcceptedFrames == 20
            && coverage.validatedFinalFrames == 20 && coverage.validatedFinalTasks == 3 && coverage.ownerQueueAccountingValid && coverage.completionCoverageValid
            && session.captureAttempts.last!.lifecycle == "completed", "budget10 whole-attempt coverage incomplete")
        try require(p.reads == 2 && c.starts == 1 && c.stops == 1, "budget10 rotation restarted permissions/device")
        let disk = try ArchiveStore(directory: directory).load(); try require(disk == m.archive, "budget10 canonical associations not durable")
        print("PASS budget10/block4 continuous20: actual backend UUID spans0..8,8..16,16..20, samples8/8/4, no exact-budget partition substitution")
    }
    @MainActor static func canonicalFailures(_ directory: URL) async throws {
        for early in [true, false] {
            let dir = directory.appendingPathComponent(early ? "early" : "throw")
            let (m,d,_,c,f) = make(dir); m.microphoneEnabled = true
            f.earlyFinal = early; f.throwAppend = !early
            await m.startCapture(configuration: configuration(m.selection!)); c.emit(position: 0); c.emit(position: 4)
            try await waitUntil { !m.captureActive }
            let metadata = m.selected!.captureAttempts.last!.canonicalMetadata!, coverage = metadata.terminalCoverage!
            try require(metadata.blocks.count == 1 && metadata.associations.count == 1 && metadata.settlements.count == 1, "failure block evidence missing")
            let s = metadata.settlements[0]
            try require(s.disposition == (early ? "uncertainAfterMapping" : "rejectedAfterMapping") && s.backendAccepted == early && s.ownerReturned == early
                && s.failure != nil && s.rawObservation.samplePosition == 0, "actual failure layers/raw not copied")
            try require(coverage == LocalCanonicalCoverage(d.canonicalCoverage!) && coverage.mappedFrames == 4 && coverage.recognitionConsumedFrames == 0
                && coverage.backendAcceptedFrames == (early ? 4 : 0) && coverage.uncertainAfterMappingFrames == (early ? 4 : 0)
                && coverage.rejectedAfterMappingFrames == (early ? 0 : 4) && coverage.validatedFinalFrames == 0
                && coverage.queue?.acceptedBlocks == 2 && coverage.queue?.consumedBlocks == (early ? 1 : 0) && coverage.queue?.releasedBlocks == (early ? 1 : 2)
                && coverage.releasedWithoutTransferBlocks == 1 && coverage.ownerQueueAccountingValid && !coverage.completionCoverageValid,
                "failure coverage fabricated normal consume/final or lost released metadata")
            let disk = try ArchiveStore(directory: dir).load()
            try require(disk == m.archive && m.selected!.captureAttempts.last!.lifecycle == "incomplete", "failure metadata not durable/attempt not incomplete")
        }
        // Raw evidence must survive even if mapper rejects this second native-discontinuous block.
        let (m,d,_,c,f) = make(directory.appendingPathComponent("mapping-rejected")); m.microphoneEnabled = true
        await m.startCapture(configuration: configuration(m.selection!)); c.emit(position: 0); c.emit(position: 9, pts: 20.0075)
        try await waitUntil { !m.captureActive }
        let metadata = m.selected!.captureAttempts.last!.canonicalMetadata!
        try require(metadata.blocks.count == 1 && metadata.settlements.count == 2 && metadata.settlements.last!.disposition == "rejectedBeforeMapping"
            && metadata.settlements.last!.rawObservation.presentationSeconds == 20.0075 && metadata.settlements.last!.rawObservation.samplePosition == 9
            && metadata.terminalCoverage == LocalCanonicalCoverage(d.canonicalCoverage!), "mapper rejection erased original raw failure metadata")
        try require(f.backends.count == 1, "rejected mapper invented task")
        print("PASS canonical failures: early-final uncertain and append-throw rejected layers, queue conservation, raw rejected timestamp durable")
    }
    @MainActor static func ptsProbe(_ directory: URL) async throws {
        let (m,d,_,c,f) = make(directory); m.microphoneEnabled = true; f.autoFinal = true
        await m.startCapture(configuration: configuration(m.selection!))
        c.emit(position: 0, pts: 20); c.emit(position: 4, pts: 20.004); c.emit(position: 8, pts: 20.0075)
        m.stopCapture(); try await waitUntil { !m.captureActive }
        let session = m.selected!, metadata = session.captureAttempts.last!.canonicalMetadata!
        try require(metadata.blocks.map { $0.rawObservation.presentationSeconds! } == [20,20.004,20.0075]
            && metadata.blocks.map(\.nominalStartNs) == [20_000_000_000,20_004_000_000,20_008_000_000]
            && metadata.blocks.map(\.nominalEndNs) == [20_004_000_000,20_008_000_000,20_012_000_000]
            && metadata.blocks.last!.residualNs == -500_000, "raw PTS clamped or canonical adjacency lost")
        let old = session.captureAttempts.last!.allTaskIdentities.flatMap { $0.sourceBlocks ?? [] }
        try require(old.count == 3 && old[1].endNS == "20008000000" && old[2].startNS == "20007500000"
            && old[2].presentationSeconds == 20.0075 && old[2].frameStart == 0, "independent old raw task-local overlap erased")
        try require(metadata.terminalCoverage == LocalCanonicalCoverage(d.canonicalCoverage!) && metadata.terminalCoverage!.completionCoverageValid, "native-continuous overlap failed normal coverage")
        let markdown = String(data: try NoteOperations.exportData(session, format: .markdown), encoding: .utf8)!
        try require(markdown.contains("nominalFromEpochAnchor") && markdown.contains("20008000000") && markdown.contains("20007500000") && markdown.contains("-500000"), "Markdown lost independent nominal/raw evidence")
        let disk = try ArchiveStore(directory: directory).load(); try require(disk == m.archive, "PTS canonical evidence not durable")
        print("PASS raw PTS20/20.004/20.0075: canonical adjacent, original task-local overlap retained, residual -500000ns, actual store/Markdown")
    }
    @MainActor static func invalidRaw(_ directory: URL) async throws {
        let payloadNaN = Double(bitPattern: 0x7ff8_0000_0000_0042)
        let negativeNaN = Double(bitPattern: 0xfff8_0000_0000_0043)
        let raws = [
            SourceTimestamp(source: .microphone, hostSeconds: payloadNaN, samplePosition: 0, sampleRate: 1000, presentationSeconds: nil, receivedUptime: 999),
            SourceTimestamp(source: .microphone, hostSeconds: .infinity, samplePosition: 0, sampleRate: 1000, presentationSeconds: nil, receivedUptime: 999),
            SourceTimestamp(source: .microphone, hostSeconds: 12, samplePosition: 0, sampleRate: 1000, presentationSeconds: -Double.infinity, receivedUptime: 999),
            SourceTimestamp(source: .microphone, hostSeconds: 12, samplePosition: 0, sampleRate: 1000, presentationSeconds: negativeNaN, receivedUptime: 999),
            SourceTimestamp(source: .microphone, hostSeconds: 12, samplePosition: 0, sampleRate: .infinity, presentationSeconds: nil, receivedUptime: 999),
            SourceTimestamp(source: .microphone, hostSeconds: 12, samplePosition: 0, sampleRate: 1000, presentationSeconds: nil, receivedUptime: -Double.infinity)
        ]
        for (index, raw) in raws.enumerated() {
            let dir = directory.appendingPathComponent(String(index))
            let (m,d,_,c,f) = make(dir); m.microphoneEnabled = true
            await m.startCapture(configuration: configuration(m.selection!))
            let callback = d.onRotatingOutput!, beforeTerminal = CanonicalEvidence()
            d.onRotatingOutput = { output in
                if case .terminal = output {
                    let disk = try? ArchiveStore(directory: dir).load()
                    beforeTerminal.terminalDurable = disk?.sessions.first?.captureAttempts.last?.canonicalMetadata?.terminalCoverage != nil
                }
                callback(output)
            }
            c.emit(position: 0, rawTimestamp: raw); c.emit(position: 4)
            try await waitUntil { !m.captureActive }
            let session = m.selected!, metadata = session.captureAttempts.last!.canonicalMetadata!
            try require(m.error == nil && m.unsavedCaptureText == nil && session.captureAttempts.last!.lifecycle == "incomplete"
                && session.segments.isEmpty && f.backends.isEmpty && c.state == .stopped, "invalid raw became publication failure, invented ASR/task, or left device running")
            try require(metadata.blocks.isEmpty && metadata.associations.isEmpty && metadata.settlements.count == 1, "invalid raw fabricated canonical mapping/identity")
            let settled = metadata.settlements[0], expected = LocalRawObservation(raw)
            try require(settled.rawObservation == expected && settled.rawObservation.hostSeconds?.bitPattern == raw.hostSeconds?.bitPattern
                && settled.rawObservation.presentationSeconds?.bitPattern == raw.presentationSeconds?.bitPattern
                && settled.rawObservation.sampleRate.bitPattern == raw.sampleRate.bitPattern && settled.rawObservation.receivedUptime.bitPattern == raw.receivedUptime.bitPattern
                && settled.disposition == "rejectedBeforeMapping" && settled.taskLocalRange == nil && !settled.backendAccepted && !settled.ownerReturned && settled.failure != nil,
                "invalid raw lost exact NaN payload/sign or infinity bits / reject evidence")
            let coverage = metadata.terminalCoverage!
            try require(beforeTerminal.terminalDurable && coverage == LocalCanonicalCoverage(d.canonicalCoverage!) && coverage.transferredBlocks == 1
                && coverage.transferredFrames == 4 && coverage.mappedBlocks == 0 && coverage.recognitionConsumedBlocks == 0 && coverage.backendAcceptedBlocks == 0
                && coverage.ownerReturnedBlocks == 0 && coverage.rejectedBeforeMappingBlocks == 1 && coverage.rejectedBeforeMappingFrames == 4
                && coverage.queue?.acceptedBlocks == 2 && coverage.queue?.consumedBlocks == 0 && coverage.queue?.releasedBlocks == 2
                && coverage.ownerQueueAccountingValid && coverage.releasedWithoutTransferBlocks == 1 && !coverage.completionCoverageValid, "invalid raw coverage/save-before-terminal incorrect")
            let disk = try ArchiveStore(directory: dir).load()
            try require(disk == m.archive && disk.sessions.first!.captureAttempts.last!.canonicalMetadata!.settlements[0].rawObservation == expected,
                "real ArchiveStore exact readback rejected NaN equality or lost raw bits")
            let json = try NoteOperations.exportData(session, format: .json)
            let reopened = try JSONDecoder().decode(LocalSession.self, from: json)
            try require(reopened == session, "default JSON export/read lost nonfinite raw payload")
            let object = try JSONSerialization.jsonObject(with: json) as! [String: Any]
            let attempts = object["captureAttempts"] as! [[String: Any]], encodedMetadata = attempts.last!["canonicalMetadata"] as! [String: Any]
            let encodedSettlements = encodedMetadata["settlements"] as! [[String: Any]], encodedRaw = encodedSettlements[0]["rawObservation"] as! [String: Any]
            for (key, value) in [("hostSeconds",raw.hostSeconds), ("presentationSeconds",raw.presentationSeconds), ("sampleRate",Optional(raw.sampleRate)), ("receivedUptime",Optional(raw.receivedUptime))] {
                if let value, !value.isFinite {
                    try require(encodedRaw[key] as? String == "ieee754-binary64:" + String(value.bitPattern, radix: 16), "nonfinite raw encoded as invalid JSON number or normalized payload")
                } else if value != nil { try require(encodedRaw[key] is NSNumber, "finite raw JSON number representation changed") }
            }
        }
        // Standard finite-mode/default JSON remains strict: only this local raw projection handles tagged bits.
        do { _ = try JSONEncoder().encode(Double.infinity); throw Failure(message: "default finite JSON strategy silently changed") }
        catch is EncodingError { }
        print("PASS invalid raw NaN payload/sign and +/-Infinity: real controller rejects before mapping, exact tagged IEEE754 bits saved/readback/exported, queue2/0/2, incomplete, no publication failure/tasks")
    }
    @MainActor static func legacyMetadata() throws {
        let bytes = Data("""
        {"id":"legacy","channelID":"mic","streamID":"old-stream","segmentID":"old-segment","locale":"zh-CN","lifecycle":"completed","deviceStarted":true,"audioObserved":true,"asrObserved":true,"history":["completed"]}
        """.utf8)
        let attempt = try JSONDecoder().decode(LocalCaptureAttempt.self, from: bytes)
        try require(attempt.allTaskIdentities.count == 1 && attempt.allTaskIdentities[0].streamID == "old-stream", "old single metadata compatibility")
        try require(attempt.canonicalMetadata == nil, "legacy canonical metadata invented")
        var session = LocalSession(title: "legacy"); session.captureAttempts = [attempt]
        let markdown = String(data: try NoteOperations.exportData(session, format: .markdown), encoding: .utf8)!
        try require(markdown.contains("canonical global timeline: unavailable"), "legacy unavailable label missing")
        print("PASS old single-task attempt metadata decodes")
    }
}
@MainActor final class CanonicalBox { var outputs: [RotatingCanonicalOutput] = [] }
@MainActor final class CanonicalEvidence { var preASR: [Bool] = []; var terminalDurable = false }
@MainActor final class RawBox { var outputs: [RotatingSpeechOutput] = [] }
