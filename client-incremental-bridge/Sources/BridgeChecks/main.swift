import Foundation
import SpeechCore
import IncrementalArchive
import ClientIncrementalBridge

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw BridgeFailure.invalid(message) }
}
final class FaultGate: @unchecked Sendable {
    let gate = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var armed = true
    func inject(_ point: ArchiveFaultPoint) throws {
        lock.lock(); let fail = armed && point == .beforeWrite; if fail { armed = false }; lock.unlock()
        if fail { guard gate.wait(timeout: .now() + 10) == .success else { throw BridgeFailure.invalid("fault gate timeout") }; throw ArchiveFailure.injected(.beforeWrite) }
    }
}
final class ValidationGate: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let lock = NSLock(); var first = true
    func waitForStart() -> Bool { started.wait(timeout: .now() + 2) == .success }
    func pause() {
        lock.lock(); let pause = first; first = false; lock.unlock()
        if pause { started.signal(); _ = release.wait(timeout: .now() + 10) }
    }
}
@main struct Checks {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-synthetic-\(UUID())")
        let limits = try CoreLimits(maxBufferedEvents: 32, maxBufferedBytes: 65536, reorderTimeoutMs: 100, recoveryTimeoutMs: 1000)
        let bridge = try await ClientArchiveBridge.open(directory: directory, limits: limits)
        let fence = ArchiveFence(sessionID: "synthetic-session")
        _ = try await bridge.submit(fence: fence, deltas: [.sessionOpened(title: "合成合同子集")])
        var config = SpeechEvent(id: "actual-config", session: fence.sessionID, sequence: 1, type: "session.config", timeNs: "1")
        config.glossaryRevision = 1
        var source = SpeechEvent(id: "actual-source", session: fence.sessionID, sequence: 2, type: "asr.segment", timeNs: "2")
        source.segmentId = "actual-typed-segment"; source.revision = 1; source.status = "final"
        source.text = "保留实际输入，不重分序号"; source.startNs = "0"; source.endNs = "1"
        let configWire = try config.encoded(), sourceWire = try source.encoded()
        _ = try await bridge.submit(fence: fence, deltas: [try speechDelta(from: configWire), try speechDelta(from: sourceWire), .notesRevision(revision: 1, text: "合成随记"), .sessionMetadataRevision(revision: 1, title: "实际编辑标题", tags: ["", "Sample", "Sample"])])
        let saved = try await bridge.flush()
        try require(saved.confirmedHead == 2 && saved.fsyncedHead == 2, "real flush watermark")
        try require(bridge.state.unconfirmed.isEmpty, "pending cleared only after ack")
        try require(bridge.state.acknowledgedProjection.sessions[fence.sessionID]?.journal == [configWire, sourceWire], "exact original wire")
        try require(bridge.state.acknowledgedProjection.sessions[fence.sessionID]?.core.currentSegment("actual-typed-segment")?.text == source.text, "real reducer projection")
        print("PASS typed wire/notes real writer + flush")
        // Actual scalar metadata caller fixture; no audio or mapper claimed.
        let capture = ArchiveFence(sessionID: fence.sessionID, attemptID: "synthetic-attempt", generationID: UUID())
        _ = try await bridge.submit(fence: capture, deltas: [.attemptBegan(requiresTerminalCoverage: true)])
        _ = try await bridge.submit(fence: capture, deltas: [.canonicalBatch([CanonicalObservation(kind: .terminalCoverage, fields: ["completionCoverageValid": .boolean(true), "fixtureCallerDeclared": .boolean(true)])])])
        let coverage = try await bridge.flush()
        _ = try await bridge.submit(fence: capture, deltas: [.attemptEnded(outcome: .completed, requiredCommitSequence: coverage.confirmedHead)])
        let terminal = try await bridge.flush()
        try require(terminal.confirmedHead == 5, "terminal watermark separate commit")
        _ = try await bridge.close()
        let reopened = try await ClientArchiveBridge.open(directory: directory, limits: limits)
        let state = reopened.state.acknowledgedProjection
        try require(state.head == 5, "reopened actual head")
        try require(state.sessions[fence.sessionID]?.tags == ["", "Sample", "Sample"] && state.sessions[fence.sessionID]?.metadataRevision == 1 && state.sessions[fence.sessionID]?.title == "实际编辑标题", "metadata exact values/no normalization")
        try require(state.sessions[fence.sessionID]?.journal == [configWire, sourceWire], "true reopen wire")
        try require(state.sessions[fence.sessionID]?.notes == bridge.state.acknowledgedProjection.sessions[fence.sessionID]?.notes, "true reopen every note revision")
        try require(state.sessions[fence.sessionID]?.attempts[capture]?.outcome == .completed, "preserve actual fence terminal")
        try require(reopened.writer.status.fsyncedHead == 0, "reopen does not invent fsync evidence")
        _ = try await reopened.flush(); _ = try await reopened.close()
        print("PASS canonical/fence/terminal dependency + new writer reopen")
        // Mismatched typed wrapper must fail BEFORE admission, without poisoning disk log.
        let rejectionDir = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-rejection-\(UUID())")
        let rejecting = try await ClientArchiveBridge.open(directory: rejectionDir, limits: limits)
        _ = try await rejecting.submit(fence: fence, deltas: [.sessionOpened(title: "拒绝检查")]); _ = try await rejecting.flush()
        do {
            _ = try await rejecting.submit(fence: fence, deltas: [.sourceRevision(segmentID: "wrong", revision: 1, eventSequence: 2, wireData: sourceWire)])
            throw BridgeFailure.invalid("accepted mismatched source")
        } catch BridgeFailure.invalid(let reason) {
            try require(reason != "accepted mismatched source", "binding must reject")
        }
        try require(rejecting.writer.status.confirmedHead == 1 && rejecting.state.unconfirmed.isEmpty, "rejection retained caller-owned; no false save")
        _ = try await rejecting.close()
        print("PASS invalid binding rejected before writer admission")
        let faults = FaultGate()
        let faultDir = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-fault-\(UUID())")
        let faulted = try await ClientArchiveBridge.open(directory: faultDir, limits: limits, fault: { try faults.inject($0) })
        let first = try await faulted.submit(fence: fence, deltas: [.sessionOpened(title: "故障账本")])
        let second = try await faulted.submit(fence: fence, deltas: [.notesRevision(revision: 1, text: "不可丢的修订")])
        faults.gate.signal()
        do { _ = try await faulted.flush(); throw BridgeFailure.invalid("fault silently passed") }
        catch ArchiveFailure.injected(.beforeWrite) {}
        try require(faulted.state.unconfirmed.count == 2 && faulted.writer.unconfirmedSubmissions.count == 2 && faulted.state.admittedCount == 2 && faulted.state.reservedBytes > 0, "all accepted unconfirmed and budgets retained")
        try require(faulted.state.acknowledgedProjection.head == 0, "admission is not saved")
        try require(faulted.state.unconfirmed.map(\.id) == [first.submissionID, second.submissionID], "original IDs retained")
        try faulted.retryUnconfirmed()
        let retried = try await faulted.flush()
        try require(retried.confirmedHead == 2 && faulted.state.unconfirmed.isEmpty, "real retry confirms originals")
        _ = try await faulted.close()
        print("PASS fault retains all unconfirmed + same-ID explicit retry")
        let pause = ValidationGate()
        let boundedDir = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-bounded-\(UUID())")
        let bounded = try await ClientArchiveBridge.open(directory: boundedDir, limits: limits,
            budget: BridgeLimits(maximumAdmittedCount: 2), beforeValidation: { pause.pause() })
        let one = Task { try await bounded.submit(fence: fence, deltas: [.sessionOpened(title: "有界并发")]) }
        let began = await Task.detached { pause.waitForStart() }.value
        try require(began, "validation gate started")
        let two = Task { try await bounded.submit(fence: fence, deltas: [.notesRevision(revision: 1, text: "第二条等待")]) }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while bounded.state.admittedCount < 2 && ProcessInfo.processInfo.systemUptime < deadline { await Task.yield() }
        try require(bounded.state.admittedCount == 2, "bounded pre-validation admission")
        do {
            _ = try await bounded.submit(fence: fence, deltas: [.notesRevision(revision: 2, text: "第三条必须在入队前拒绝")])
            throw BridgeFailure.invalid("unbounded admission accepted")
        } catch ArchiveFailure.queueFull {}
        let snapshotSeconds = await MainActor.run {
            let start = ProcessInfo.processInfo.systemUptime
            _ = bounded.state
            return ProcessInfo.processInfo.systemUptime - start
        }
        try require(snapshotSeconds < 0.5, "state blocked by validation gate")
        pause.release.signal()
        _ = try await one.value; _ = try await two.value
        _ = try await bounded.flush()
        try require(bounded.state.admittedCount == 0 && bounded.state.reservedBytes == 0, "permits released only after ack")
        _ = try await bounded.close()
        print("PASS bounded concurrent admission + MainActor state snapshot during paused validation: \(snapshotSeconds)s")
        print("Synthetic only. No capture, no legacy migration, no full LocalArchive parity. Stores: \(directory.path), \(rejectionDir.path)")
    }
}
