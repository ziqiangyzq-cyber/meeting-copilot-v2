import Foundation
import Darwin
import IncrementalArchive

struct CheckFailure: Error { let message: String }
func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws { if try !value() { throw CheckFailure(message: message) } }
func wait(_ ready: () -> Bool) async throws {
    let end = ProcessInfo.processInfo.systemUptime + 4
    while !ready() { try check(ProcessInfo.processInfo.systemUptime < end, "short check timed out"); try await Task.sleep(nanoseconds: 1_000_000) }
}
final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var a: [ArchiveAcknowledgement] = [], f: [ArchiveFailureNotice] = []
    var acks: [ArchiveAcknowledgement] { lock.lock(); defer { lock.unlock() }; return a }
    var failures: [ArchiveFailureNotice] { lock.lock(); defer { lock.unlock() }; return f }
    func ack(_ value: ArchiveAcknowledgement) { lock.lock(); a.append(value); lock.unlock() }
    func fail(_ value: ArchiveFailureNotice) { lock.lock(); f.append(value); lock.unlock() }
}
final class Faults: @unchecked Sendable {
    let lock = NSLock()
    var point: ArchiveFaultPoint? = nil
    var remaining = 0
    var encoderError = false
    var onMain = false
    var exitPoint: ArchiveFaultPoint? = nil
    var armed = false
    init(_ point: ArchiveFaultPoint? = nil, count: Int = 1) { self.point = point; remaining = count }
    func armCrash(_ point: ArchiveFaultPoint) { lock.lock(); exitPoint = point; armed = true; lock.unlock() }
    func call(_ actual: ArchiveFaultPoint) throws {
        lock.lock(); onMain = onMain || Thread.isMainThread
        let crash = armed && exitPoint == actual
        let fail = remaining > 0 && point == actual
        if fail { remaining -= 1 }
        let encoding = encoderError; lock.unlock()
        if crash { Darwin._exit(actual == .afterPartialWrite ? 92 : 91) }
        if fail {
            if encoding { throw EncodingError.invalidValue("injected encoder failure", .init(codingPath: [], debugDescription: "synthetic codec boundary")) }
            throw ArchiveFailure.injected(actual)
        }
    }
}
let session = ArchiveFence(sessionID: "s")
let generation = UUID(uuidString: "C1111111-2222-4333-8444-555555555555")!
let attempt = ArchiveFence(sessionID: "s", attemptID: "a", generationID: generation)
let childID = UUID(uuidString: "D1111111-2222-4333-8444-555555555555")!
func request(_ head: UInt64, _ deltas: [ArchiveDelta], fence: ArchiveFence = session, id: UUID = UUID(), durability: ArchiveDurability = .readback) -> ArchiveSubmission {
    ArchiveSubmission(id: id, expectedHead: head, fence: fence, deltas: deltas, durability: durability)
}
@discardableResult func commit(_ writer: IncrementalArchiveWriter, _ value: ArchiveSubmission) async throws -> ArchiveAcknowledgement {
    let probe = Probe()
    let token = try writer.submit(value, onAcknowledged: { probe.ack($0) }, onFailure: { probe.fail($0) })
    try await wait { !probe.failures.isEmpty || (!probe.acks.isEmpty && writer.status.confirmedHead >= token.plannedCommitSequence) }
    if let error = probe.failures.first { throw error.error }
    return probe.acks[0]
}
func logBytes(_ directory: URL) throws -> Data { try Data(contentsOf: directory.appendingPathComponent("records.ndjson")) }
@main struct Checks {
    static func main() async {
        do {
            if CommandLine.arguments.count == 3 { try await child(CommandLine.arguments[1], URL(fileURLWithPath: CommandLine.arguments[2])); return }
            let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("evidence/incremental-\(UUID().uuidString)")
            try await metadata(root.appendingPathComponent("metadata"))
            try await normal(root.appendingPathComponent("normal"))
            try await admission(root.appendingPathComponent("admission"))
            try await faults(root.appendingPathComponent("faults"))
            try await ownership(root.appendingPathComponent("ownership"))
            try await dependency(root.appendingPathComponent("dependency"))
            try await processes(root.appendingPathComponent("processes"))
            try await snapshotFailure(root.appendingPathComponent("snapshot-failure"))
            print("PASS ALL incremental-archive checks\nEVIDENCE_ROOT=\(root.path)")
        } catch { print("FAIL incremental-archive checks: \(error)"); exit(1) }
    }
    static func metadata(_ directory: URL) async throws {
        let writer = try await IncrementalArchiveWriter.open(directory: directory)
        let initialTitle = "Initial 标题"
        try await commit(writer, request(0, [.sessionOpened(title: initialTitle)]))
        let exactTags = ["", " duplicate ", " duplicate ", "中文", "\0\"\\\n"]
        let first = request(1, [.sessionMetadataRevision(revision: 1, title: "New 标题", tags: exactTags)])
        let firstAck = try await commit(writer, first)
        let maximumTags = Array(repeating: "", count: 128)
        try await commit(writer, request(2, [.sessionMetadataRevision(revision: 2, title: String(repeating: "\0", count: 15 * 1024), tags: maximumTags)]))
        let beforeDuplicate = try logBytes(directory), duplicate = try await commit(writer, first)
        try check(duplicate.alreadyPresent && duplicate.token == firstAck.token && writer.status.confirmedHead == 3
            && (try logBytes(directory)) == beforeDuplicate, "metadata stable ID not exact idempotent")
        for over in [request(3, [.sessionMetadataRevision(revision: 3, title: "", tags: Array(repeating: "", count: 129))]),
                     request(3, [.sessionMetadataRevision(revision: 3, title: "", tags: Array(repeating: "", count: 64)), .sessionMetadataRevision(revision: 4, title: "", tags: Array(repeating: "", count: 65))]),
                     request(3, [.sessionMetadataRevision(revision: 3, title: "", tags: [])], fence: ArchiveFence(sessionID: String(repeating: "s", count: 257))),
                     request(3, [.sessionMetadataRevision(revision: 3, title: "", tags: [String(repeating: "x", count: 16 * 1024 + 1)])]),
                     request(3, [.sessionMetadataRevision(revision: 3, title: String(repeating: "字", count: 6000), tags: [])]),
                     request(3, [.sessionMetadataRevision(revision: 3, title: "", tags: [String(repeating: "x", count: 13 * 1024), String(repeating: "y", count: 13 * 1024)])])] {
            do { try writer.submit(over, onAcknowledged: { _ in }, onFailure: { _ in }); throw CheckFailure(message: "metadata limit admitted") }
            catch is ArchiveFailure { }
        }
        try check(writer.status.confirmedHead == 3 && writer.status.pendingCount == 0, "metadata admission rejection touched durable/pending state")
        _ = try await writer.checkpoint(); _ = try await writer.close()
        let recovery = try await IncrementalArchiveWriter.inspect(directory: directory)
        var replayTitle = "", replayTags: [String] = [], metadataRevision: UInt64 = 0
        for record in recovery.records {
            for delta in record.submission.deltas {
                switch delta {
                case .sessionOpened(let title): replayTitle = title; replayTags = []; metadataRevision = 0
                case .sessionMetadataRevision(let revision, let title, let tags):
                    try check(revision == metadataRevision + 1, "metadata replay revision gap")
                    if revision == 1 { try check(replayTags.isEmpty && replayTitle == initialTitle && metadataRevision == 0 && tags == exactTags, "initial revision0 or original tags altered") }
                    replayTitle = title; replayTags = tags; metadataRevision = revision
                default: break
                }
            }
        }
        try check(recovery.head == 3 && recovery.records[1].submission == first && metadataRevision == 2 && replayTags == maximumTags
            && replayTitle == String(repeating: "\0", count: 15 * 1024), "metadata exact values lost through actual snapshot/log replay")
        // Same stable ID with changed title/tags is a conflict and remains caller-visible pending.
        let reopened = try await IncrementalArchiveWriter.open(directory: directory), collision = Probe()
        let changed = ArchiveSubmission(id: first.id, expectedHead: first.expectedHead, fence: first.fence,
            deltas: [.sessionMetadataRevision(revision: 1, title: "Different", tags: exactTags)])
        try reopened.submit(changed, onAcknowledged: { collision.ack($0) }, onFailure: { collision.fail($0) })
        try await wait { !collision.failures.isEmpty }
        try check(collision.failures[0].error == .identityConflict(first.id) && reopened.unconfirmedSubmissions == [changed]
            && reopened.status.confirmedHead == 3 && collision.acks.isEmpty, "metadata ID collision silently changed title or dropped pending")
        for mode in 0..<4 {
            let dir = directory.appendingPathComponent("invalid-\(mode)"), invalid = try await IncrementalArchiveWriter.open(directory: dir)
            try await commit(invalid, request(0, [.sessionOpened(title: "zero")]))
            var head: UInt64 = 1, fence = session
            if mode == 2 {
                try await commit(invalid, request(1, [.attemptBegan(requiresTerminalCoverage: false)], fence: attempt)); head = 2; fence = attempt
            }
            if mode == 3 {
                try await commit(invalid, request(1, [.sessionMetadataRevision(revision: 1, title: "one", tags: [])])); head = 2
            }
            let revision: UInt64 = mode == 0 ? 0 : (mode == 1 ? 2 : 1)
            let refused = request(head, [.sessionMetadataRevision(revision: revision, title: "retained", tags: ["", "same", "same"])], fence: fence), probe = Probe()
            try invalid.submit(refused, onAcknowledged: { probe.ack($0) }, onFailure: { probe.fail($0) }); try await wait { !probe.failures.isEmpty }
            let expected: ArchiveFailure = mode == 2 ? .fence("session metadata requires session scope") : .revision("session metadata must retain every revision")
            try check(probe.failures[0].error == expected && invalid.unconfirmedSubmissions == [refused] && invalid.status.confirmedHead == head
                && probe.acks.isEmpty, "metadata scope/revision rejection discarded pending or confirmed invalid edit")
            let disk = try await IncrementalArchiveWriter.inspect(directory: dir); try check(disk.head == head, "invalid metadata appended to actual log")
        }
        let tape = Faults(nil, count: 0), faultDir = directory.appendingPathComponent("ack-failure")
        let ambiguous = try await IncrementalArchiveWriter.open(directory: faultDir, fault: { try tape.call($0) })
        try await commit(ambiguous, request(0, [.sessionOpened(title: "ack-zero")]))
        tape.point = .beforeAcknowledgement; tape.remaining = 1
        let edit = request(1, [.sessionMetadataRevision(revision: 1, title: "Unconfirmed 标题", tags: exactTags)]), probe = Probe()
        try ambiguous.submit(edit, onAcknowledged: { probe.ack($0) }, onFailure: { probe.fail($0) }); try await wait { !probe.failures.isEmpty }
        let written = try logBytes(faultDir)
        try check(ambiguous.status.confirmedHead == 1 && ambiguous.unconfirmedSubmissions == [edit], "metadata ack failure lost actual edit or advanced watermark")
        try ambiguous.retryUnconfirmed(); try await wait { probe.acks.count == 1 && ambiguous.status.confirmedHead >= 2 }
        try check(probe.acks[0].alreadyPresent && ambiguous.unconfirmedSubmissions.isEmpty && (try logBytes(faultDir)) == written,
            "metadata ambiguous write blind append or changed original values")
        _ = try await ambiguous.close()
        print("PASS session metadata revision0/title, strict session-scoped1..N, exact empty/duplicate/ordered tags and escaped title, max count/UTF8/payload limits, replay, stableID conflict and retained ack ambiguity")
    }
    static func normal(_ directory: URL) async throws {
        let trace = Faults(nil, count: 0)
        let writer = try await IncrementalArchiveWriter.open(directory: directory, fault: { try trace.call($0) })
        try await commit(writer, request(0, [.sessionOpened(title: "synthetic"), .speechEvent(eventSequence: 1, wireData: Data("fixture-config".utf8))]))
        try await commit(writer, request(1, [.attemptBegan(requiresTerminalCoverage: true)], fence: attempt))
        let coupled = request(2, [.sourceRevision(segmentID: "seg", revision: 1, eventSequence: 2, wireData: Data("fixture-source-r1".utf8)),
            .canonicalBatch([CanonicalObservation(kind: .associated, fields: ["segmentID": .string("seg"), "fixtureValue": .float64(Double(bitPattern: 0x7ff8000000000042))])])], fence: attempt)
        let oldAck = try await commit(writer, coupled)
        let malicious = String(repeating: "\0", count: 15 * 1024)
        try await commit(writer, request(3, [.notesRevision(revision: 1, text: malicious)]))
        try await commit(writer, request(4, [.sourceRevision(segmentID: "seg", revision: 2, eventSequence: 3, wireData: Data("fixture-source-r2".utf8))], fence: attempt))
        try await commit(writer, request(5, [.translationRevision(translationID: "t", revision: 1, sourceSegmentID: "seg", sourceRevision: 2, eventSequence: 4, wireData: Data("fixture-translation".utf8))]))
        // This is an explicitly synthetic caller declaration; storage never calculates audio coverage.
        try await commit(writer, request(6, [.canonicalBatch([CanonicalObservation(kind: .terminalCoverage, fields: ["completionCoverageValid": .boolean(true), "fixture": .string("caller-declared")])])], fence: attempt))
        try await commit(writer, request(7, [.attemptEnded(outcome: .completed, requiredCommitSequence: 7)], fence: attempt))
        try await commit(writer, request(8, [.sourceRevision(segmentID: "typed", revision: 1, eventSequence: 5, wireData: Data("typed-source".utf8))]))
        try await commit(writer, request(9, [.translationRevision(translationID: "late", revision: 1, sourceSegmentID: "seg", sourceRevision: 2, eventSequence: 6, wireData: Data("delayed-after-attempt".utf8))]))
        try await commit(writer, request(10, [.translationRevision(translationID: "typed-t", revision: 1, sourceSegmentID: "typed", sourceRevision: 1, eventSequence: 7, wireData: Data("typed-translation".utf8))]))
        try await commit(writer, request(11, [.sessionClosed(requiredCommitSequence: 11)]))
        _ = try await writer.flush()
        let before = try logBytes(directory)
        let duplicate = try await commit(writer, coupled)
        _ = try await writer.flush()
        try check(duplicate.alreadyPresent && duplicate.token == oldAck.token && writer.status.confirmedHead == 12, "same ID/seq/content not idempotent or watermark regressed")
        try check(try logBytes(directory) == before, "duplicate blindly appended")
        let nextFence = ArchiveFence(sessionID: "s", attemptID: "new", generationID: UUID())
        try check(!oldAck.matches(oldAck.token, activeFence: nextFence), "old attempt acknowledgement can clear new dirty token")
        let snapshot = try await writer.checkpoint()
        try check(snapshot.confirmedHead == 12 && snapshot.fsyncedHead == 12, "real fsync/checkpoint watermark incorrect")
        _ = try await writer.close()
        let reopened = try await IncrementalArchiveWriter.inspect(directory: directory)
        try check(reopened.head == 12 && reopened.records.count == 12 && reopened.unfinishedAttempts.isEmpty && reopened.incompleteTail == nil, "complete replay/checkpoint incorrect")
        try check(reopened.records[2].submission == coupled, "body/reference metadata did not share one commit")
        if case .notesRevision(let revision, let text) = reopened.records[3].submission.deltas[0] { try check(revision == 1 && text == malicious, "escape-heavy notes silently coalesced/truncated") }
        else { throw CheckFailure(message: "notes lost") }
        try check(!trace.onMain, "encoding/IO fault checkpoints ran on main thread")
        print("PASS typed atomic body+references, independent commit/journal seq, escape-heavy revision, exact replay, stable-ID dedup, old-ack fence, fsync/checkpoint/close")
    }
    static func admission(_ directory: URL) async throws {
        let writer = try await IncrementalArchiveWriter.open(directory: directory)
        try await commit(writer, request(0, [.sessionOpened(title: "batch")]))
        try await commit(writer, request(1, [.attemptBegan(requiresTerminalCoverage: false)], fence: attempt))
        let rows = (0..<128).map { CanonicalObservation(kind: .mapped, fields: ["fixture": .unsigned(UInt64($0))]) }
        try await commit(writer, request(2, [.canonicalBatch(rows)], fence: attempt)); _ = try await writer.flush()
        for value in [request(3, [.canonicalBatch(rows + [rows[0]])], fence: attempt), request(3, [.notesRevision(revision: 1, text: String(repeating: "x", count: 16 * 1024 + 1))]), request(3, [.speechEvent(eventSequence: 1, wireData: Data(repeating: 1, count: 24 * 1024 + 1))])] {
            do { try writer.submit(value, onAcknowledged: { _ in }, onFailure: { _ in }); throw CheckFailure(message: "over-limit input admitted") }
            catch is ArchiveFailure { }
        }
        try check(writer.status.pendingCount == 0 && writer.status.confirmedHead == 3, "admission rejection affected acknowledged state")
        let gate = DispatchSemaphore(value: 0), entered = DispatchSemaphore(value: 0)
        let limits = ArchiveLimits(maximumPendingCount: 2)
        let bounded = try await IncrementalArchiveWriter.open(directory: directory.appendingPathComponent("bounded"), limits: limits, fault: { p in
            if p == .beforeWrite { entered.signal(); _ = gate.wait(timeout: .now() + 3) }
        })
        let probes = [Probe(), Probe()]
        try bounded.submit(request(0, [.sessionOpened(title: "bounded")]), onAcknowledged: { probes[0].ack($0) }, onFailure: { probes[0].fail($0) })
        // Only the test blocks a worker; API admission stays immediate and counts in-flight bytes.
        try check(entered.wait(timeout: .now() + 3) == .success, "writer gate not reached")
        try bounded.submit(request(1, [.notesRevision(revision: 1, text: "kept")]), onAcknowledged: { probes[1].ack($0) }, onFailure: { probes[1].fail($0) })
        let held = bounded.status
        do { try bounded.submit(request(2, [.notesRevision(revision: 2, text: "caller still owns rejected input")]), onAcknowledged: { _ in }, onFailure: { _ in }); throw CheckFailure(message: "unbounded queue") }
        catch ArchiveFailure.queueFull { }
        try check(held.pendingCount == 2 && held.reservedBytes > 0 && bounded.unconfirmedSubmissions.count == 2, "in-flight pending reservation lost")
        gate.signal(); gate.signal()
        try await wait { probes.allSatisfy { $0.acks.count == 1 } }; _ = try await bounded.flush()
        print("PASS maximum typed canonical batch, UTF8/payload rejection before acceptance, conservative escape/header reservation and in-flight queue bounds")
    }
    static func faults(_ directory: URL) async throws {
        for point in [ArchiveFaultPoint.beforeEncode, .beforeWrite, .afterWrite, .beforeReadback, .beforeAcknowledgement, .beforeFsync] {
            let dir = directory.appendingPathComponent(point.rawValue), tape = Faults(point)
            tape.encoderError = point == .beforeEncode
            let writer = try await IncrementalArchiveWriter.open(directory: dir, fault: { try tape.call($0) })
            let value = request(0, [.sessionOpened(title: "retained")], durability: point == .beforeFsync ? .fsync : .readback), probe = Probe()
            try writer.submit(value, onAcknowledged: { probe.ack($0) }, onFailure: { probe.fail($0) })
            try await wait { !probe.failures.isEmpty }
            try check(writer.status.confirmedHead == 0 && writer.status.fsyncedHead == 0 && writer.unconfirmedSubmissions == [value], "failure dropped in-flight increment/advanced ack")
            do { _ = try await writer.close(); throw CheckFailure(message: "normal close during unconfirmed failure") } catch is ArchiveFailure { }
            try writer.retryUnconfirmed(); try await wait { probe.acks.count == 1 }; _ = try await writer.flush()
            let replay = try await IncrementalArchiveWriter.inspect(directory: dir)
            try check(replay.records.count == 1 && replay.records[0].submission == value && writer.status.confirmedHead == 1, "ambiguous full write retried as duplicate append")
        }
        // Actual acknowledgement callback throws AFTER successful disk commit; retain/reconcile same ID.
        let writer = try await IncrementalArchiveWriter.open(directory: directory.appendingPathComponent("callback")), probe = Probe(), once = Faults(nil, count: 1)
        let value = request(0, [.sessionOpened(title: "ack callback")])
        try writer.submit(value, onAcknowledged: { ack in
            once.lock.lock(); let shouldFail = once.remaining > 0; once.remaining = 0; once.lock.unlock()
            if shouldFail { throw CheckFailure(message: "consumer acknowledgement delivery failed") }; probe.ack(ack)
        }, onFailure: { probe.fail($0) })
        try await wait { !probe.failures.isEmpty }
        let before = try logBytes(directory.appendingPathComponent("callback"))
        try writer.retryUnconfirmed(); try await wait { probe.acks.count == 1 }; _ = try await writer.flush()
        try check(probe.acks[0].alreadyPresent && writer.unconfirmedSubmissions.isEmpty && (try logBytes(directory.appendingPathComponent("callback"))) == before, "ack delivery failure blind reappend")
        let changed = ArchiveSubmission(id: value.id, expectedHead: value.expectedHead, fence: value.fence, deltas: [.sessionOpened(title: "DIFFERENT")])
        let collision = Probe(); try writer.submit(changed, onAcknowledged: { collision.ack($0) }, onFailure: { collision.fail($0) })
        try await wait { !collision.failures.isEmpty }
        try check(collision.failures[0].error == .identityConflict(value.id) && writer.unconfirmedSubmissions == [changed] && writer.status.confirmedHead == 1, "same ID different content not conflict/retained")
        print("PASS injected codec/write/readback/fsync/ack faults retain increments; full-write ambiguity reconciles exact stable ID; callback-ack failure and identity conflict never blindly append")
    }
    static func ownership(_ directory: URL) async throws {
        for mode in 0..<3 {
            let dir = directory.appendingPathComponent(String(mode)), writer = try await IncrementalArchiveWriter.open(directory: dir)
            try await commit(writer, request(0, [.sessionOpened(title: "ownership")]))
            try await commit(writer, request(1, [.attemptBegan(requiresTerminalCoverage: false)], fence: attempt))
            try await commit(writer, request(2, [.sourceRevision(segmentID: "captured", revision: 1, eventSequence: 1, wireData: Data("capture-r1".utf8))], fence: attempt))
            var head: UInt64 = 3, wrong = session
            if mode == 1 {
                wrong = ArchiveFence(sessionID: "s", attemptID: "another", generationID: UUID())
                try await commit(writer, request(head, [.attemptBegan(requiresTerminalCoverage: false)], fence: wrong)); head += 1
            }
            if mode == 2 {
                try await commit(writer, request(head, [.sourceRevision(segmentID: "typed", revision: 1, eventSequence: 2, wireData: Data("typed-r1".utf8))])); head += 1; wrong = attempt
            }
            let value = request(head, [.sourceRevision(segmentID: mode == 2 ? "typed" : "captured", revision: 2,
                eventSequence: mode == 2 ? 3 : 2, wireData: Data("must-remain-unconfirmed".utf8))], fence: wrong)
            let probe = Probe(); try writer.submit(value, onAcknowledged: { probe.ack($0) }, onFailure: { probe.fail($0) }); try await wait { !probe.failures.isEmpty }
            try check(probe.failures[0].error == .fence("source segment owner fence cannot change") && writer.status.confirmedHead == head
                && writer.unconfirmedSubmissions == [value] && probe.acks.isEmpty, "source fence bypass cleared unconfirmed or changed owner")
            let replay = try await IncrementalArchiveWriter.inspect(directory: dir)
            try check(replay.head == head && replay.records.last!.submission != value, "rejected ownership changed persisted source history")
        }
        print("PASS captured source cannot switch to session or different generation; typed source cannot switch to capture fence; rejected revision retained without sequence advance")
    }
    static func dependency(_ directory: URL) async throws {
        let writer = try await IncrementalArchiveWriter.open(directory: directory)
        try await commit(writer, request(0, [.sessionOpened(title: "dependency")]))
        try await commit(writer, request(1, [.attemptBegan(requiresTerminalCoverage: true)], fence: attempt))
        let value = request(2, [.attemptEnded(outcome: .completed, requiredCommitSequence: 2)], fence: attempt), probe = Probe()
        try writer.submit(value, onAcknowledged: { probe.ack($0) }, onFailure: { probe.fail($0) }); try await wait { !probe.failures.isEmpty }
        let replay = try await IncrementalArchiveWriter.inspect(directory: directory)
        try check(replay.head == 2 && replay.unfinishedAttempts == [attempt] && replay.requiresExplicitRecovery && writer.unconfirmedSubmissions == [value], "completed without prior acknowledged terminal metadata")
        do { _ = try await writer.flush(); throw CheckFailure(message: "flush falsely succeeded across retained failure") } catch is ArchiveFailure { }
        print("PASS completed dependency/fence rejects missing terminal evidence, keeps pending terminal and unfinished recovery view; flush/normal close cannot hide failure")
    }
    static func processes(_ directory: URL) async throws {
        let full = directory.appendingPathComponent("full"), partial = directory.appendingPathComponent("partial")
        // A child that writes ~1.1 MB to stdout must still terminate under the bounded
        // collector; with an unread Pipe this is exactly the case that hangs forever.
        let noisyStart = ProcessInfo.processInfo.systemUptime
        try runChild("--child-noisy", directory, expected: 0)
        let noisyElapsed = ProcessInfo.processInfo.systemUptime - noisyStart
        try check(noisyElapsed < 25, "noisy child not drained/bounded: \(noisyElapsed)s")
        try runChild("--child-full", full, expected: 91); try runChild("--child-partial", partial, expected: 92)
        let recovered = try await IncrementalArchiveWriter.inspect(directory: full)
        try check(recovered.head == 3 && recovered.unfinishedAttempts == [attempt] && recovered.requiresExplicitRecovery, "complete crash suffix or interrupted attempt lost")
        let writer = try await IncrementalArchiveWriter.open(directory: full), before = try logBytes(full)
        let duplicate = try await commit(writer, request(2, [.notesRevision(revision: 1, text: "child-complete")], fence: attempt, id: childID))
        _ = try await writer.flush(); try check(duplicate.alreadyPresent && (try logBytes(full)) == before, "process crash acknowledgement ambiguity appended twice")
        let tail = try await IncrementalArchiveWriter.inspect(directory: partial)
        try check(tail.head == 2 && tail.incompleteTail?.bytes.isEmpty == false && tail.unfinishedAttempts == [attempt], "partial tail silently truncated/consumed")
        do { _ = try await IncrementalArchiveWriter.open(directory: partial); throw CheckFailure(message: "writer opened over incomplete tail") } catch ArchiveFailure.incompleteTail { }
        var damaged = before
        let newlines = damaged.indices.filter { damaged[$0] == 10 }; try check(newlines.count == 3, "child frame count")
        damaged[newlines[0] + 10] ^= 1; try damaged.write(to: full.appendingPathComponent("records.ndjson"))
        do { _ = try await IncrementalArchiveWriter.inspect(directory: full); throw CheckFailure(message: "middle corruption silently recovered") }
        catch ArchiveFailure.corrupt(let offset, _) { try check(offset > 0, "not middle corruption") }
        // Separate-process stale head conflict, without any overwrite or implicit revision rebase.
        let shared = directory.appendingPathComponent("shared"), sharedWriter = try await IncrementalArchiveWriter.open(directory: shared)
        try await commit(sharedWriter, request(0, [.sessionOpened(title: "shared")]))
        try runChild("--child-external", shared, expected: 0)
        let stale = request(1, [.notesRevision(revision: 1, text: "parent unconfirmed")]), probe = Probe()
        try sharedWriter.submit(stale, onAcknowledged: { probe.ack($0) }, onFailure: { probe.fail($0) }); try await wait { !probe.failures.isEmpty }
        try check(probe.failures[0].error == .conflict(expected: 1, actual: 2) && sharedWriter.unconfirmedSubmissions == [stale], "cross-process expected head overwrite/lost increment")
        // A real child owns the same POSIX lock while parent attempts a transaction.
        let locked = directory.appendingPathComponent("locked"), lockedWriter = try await IncrementalArchiveWriter.open(directory: locked)
        let holder = try spawn("--child-lock", locked)
        try await wait { FileManager.default.fileExists(atPath: locked.appendingPathComponent("held").path) }
        let busy = Probe(); try lockedWriter.submit(request(0, [.sessionOpened(title: "after lock")]), onAcknowledged: { busy.ack($0) }, onFailure: { busy.fail($0) })
        try await wait { !busy.failures.isEmpty }; try check(busy.failures[0].error == .busy && lockedWriter.unconfirmedSubmissions.count == 1, "cross-process lock not enforced")
        try check(collect(holder.process, holder.log, 30, "lock child") == 0, "lock child failed")
        try lockedWriter.retryUnconfirmed(); try await wait { busy.acks.count == 1 }; _ = try await lockedWriter.flush()
        print("PASS real subprocess noisy-stdout drain, full/partial crash replay, explicit incomplete tail, middle corruption failure, stable-ID reconciliation, cross-process expected-head and flock conflict")
    }
    static func snapshotFailure(_ directory: URL) async throws {
        let tape = Faults(.afterSnapshotWrite), writer = try await IncrementalArchiveWriter.open(directory: directory, fault: { try tape.call($0) })
        try await commit(writer, request(0, [.sessionOpened(title: "snapshot failure")]))
        let before = try logBytes(directory)
        do { _ = try await writer.checkpoint(); throw CheckFailure(message: "snapshot fault not injected") } catch ArchiveFailure.injected(.afterSnapshotWrite) { }
        try check((try logBytes(directory)) == before, "log deleted/changed before snapshot acknowledgement")
        let replay = try await IncrementalArchiveWriter.inspect(directory: directory); try check(replay.head == 1, "snapshot ack failure destroyed log replay")
        try writer.retryUnconfirmed(); _ = try await writer.checkpoint(); _ = try await writer.close()
        let completedDir = directory.appendingPathComponent("completed-intent"), completedFault = Faults(nil, count: 0)
        let completedWriter = try await IncrementalArchiveWriter.open(directory: completedDir, fault: { try completedFault.call($0) })
        try await commit(completedWriter, request(0, [.sessionOpened(title: "fsync intent")]))
        try await commit(completedWriter, request(1, [.attemptBegan(requiresTerminalCoverage: false)], fence: attempt))
        completedFault.point = .beforeFsync; completedFault.remaining = 1
        let terminal = request(2, [.attemptEnded(outcome: .completed, requiredCommitSequence: 2)], fence: attempt, durability: .fsync), completedProbe = Probe()
        try completedWriter.submit(terminal, onAcknowledged: { completedProbe.ack($0) }, onFailure: { completedProbe.fail($0) })
        try await wait { !completedProbe.failures.isEmpty }
        try check(completedWriter.status.confirmedHead == 2 && completedWriter.status.fsyncedHead == 0 && completedWriter.unconfirmedSubmissions == [terminal], "fsync request field falsely acknowledged terminal")
        let recoveredWriter = try await IncrementalArchiveWriter.open(directory: completedDir)
        try check(recoveredWriter.status.confirmedHead == 3 && recoveredWriter.status.fsyncedHead == 0, "reopened completed intent inferred historical fsync")
        let durable = try await recoveredWriter.flush(durability: .fsync)
        try check(durable.confirmedHead == 3 && durable.fsyncedHead == 3, "explicit actual reopened flush not required/confirmed")
        try completedWriter.retryUnconfirmed()
        try await wait { completedProbe.acks.count == 1 && completedWriter.status.confirmedHead >= 3 && completedWriter.status.fsyncedHead >= 3 }
        try check(completedProbe.acks[0].alreadyPresent && completedWriter.status.fsyncedHead == 3, "same-ID terminal retry skipped required real sync")
        print("PASS snapshot replayStart/head/readback/fsync and acknowledgement fault preserve original log; recovered completed fsync intent remains unsynced until actual flush/reconcile")
    }
    // Children write their diagnostics to real files, never to unread Pipes: a Pipe
    // whose reader never drains blocks the child once it fills (~64 KiB), and the
    // parent would then wait forever. The wait is also bounded by polling isRunning
    // instead of the runloop-based waitUntilExit, so a stuck child fails closed with
    // a recorded diagnostic instead of hanging the whole check run.
    static func spawn(_ mode: String, _ directory: URL) throws -> (process: Process, log: URL) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("archive-child-\(mode.replacingOccurrences(of: "--", with: ""))-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        p.arguments = [mode, directory.path]; p.standardOutput = handle; p.standardError = handle; try p.run(); return (p, log)
    }
    static func collect(_ process: Process, _ log: URL, _ deadline: Double, _ label: String) throws -> Int32 {
        let end = ProcessInfo.processInfo.systemUptime + deadline
        while process.isRunning {
            if ProcessInfo.processInfo.systemUptime > end {
                kill(process.processIdentifier, SIGKILL); process.waitUntilExit()
                let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
                throw CheckFailure(message: "\(label) did not exit within \(deadline)s; child log: \(text.suffix(2000))")
            }
            usleep(5_000)
        }
        return process.terminationStatus
    }
    static func runChild(_ mode: String, _ directory: URL, expected: Int32) throws {
        let spawned = try spawn(mode, directory)
        let status = try collect(spawned.process, spawned.log, 30, "child \(mode)")
        try check(status == expected, "child \(mode) exit \(status); log: \((try? String(contentsOf: spawned.log, encoding: .utf8))?.suffix(2000) ?? "")")
    }
    static func child(_ mode: String, _ directory: URL) async throws {
        if mode == "--child-noisy" {
            // Writes far more than a pipe buffer holds, so an unread Pipe would block
            // this child forever while the parent waits; the bounded collector must
            // drain it to a file and observe a normal exit.
            var payload = Data(); for i in 0..<20_000 { payload.append(contentsOf: "line \(i) padding padding padding padding padding\n".utf8) }
            FileHandle.standardOutput.write(payload); return
        }
        if mode == "--child-lock" {
            let fd = Darwin.open(directory.appendingPathComponent("writer.lock").path, O_RDWR)
            guard fd >= 0, flock(fd, LOCK_EX) == 0 else { throw CheckFailure(message: "child flock") }
            try Data("held".utf8).write(to: directory.appendingPathComponent("held")); usleep(300_000); flock(fd, LOCK_UN); Darwin.close(fd); return
        }
        if mode == "--child-external" {
            let writer = try await IncrementalArchiveWriter.open(directory: directory)
            try await commit(writer, request(1, [.notesRevision(revision: 1, text: "external confirmed")]))
            _ = try await writer.close(); return
        }
        let tape = Faults(nil, count: 0), writer = try await IncrementalArchiveWriter.open(directory: directory, fault: { try tape.call($0) })
        try await commit(writer, request(0, [.sessionOpened(title: "child")]))
        try await commit(writer, request(1, [.attemptBegan(requiresTerminalCoverage: false)], fence: attempt))
        tape.armCrash(mode == "--child-partial" ? .afterPartialWrite : .afterWrite)
        _ = try await commit(writer, request(2, [.notesRevision(revision: 1, text: "child-complete")], fence: attempt, id: childID))
        throw CheckFailure(message: "child crash hook not reached")
    }
}
