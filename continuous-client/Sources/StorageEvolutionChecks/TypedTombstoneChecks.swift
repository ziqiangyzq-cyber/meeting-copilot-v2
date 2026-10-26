import Foundation
import MeetingCopilotCore
import IncrementalArchive
import ClientIncrementalBridge
import SpeechCore

// Typed tombstone checks: the delta must be a real reversible record, never an entity removal, and the
// client must be able to explain a deletion after a reopen. Synthetic records only; no capture.
struct TypedFailure: Error { let message: String }
func typedRequire(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw TypedFailure(message: message) }
}

enum TypedTombstoneChecks {
    /// Real acknowledgement wait: the token is confirmed only through the writer's own callback and head.
    static func submit(_ writer: IncrementalArchiveWriter, _ request: ArchiveSubmission) async throws -> ArchiveAcknowledgement {
        let lock = NSLock()
        var acks: [ArchiveAcknowledgement] = [], failures: [ArchiveFailure] = []
        let token = try writer.submit(request, onAcknowledged: { ack in lock.lock(); acks.append(ack); lock.unlock() },
                                      onFailure: { notice in lock.lock(); failures.append(notice.error); lock.unlock() })
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while true {
            lock.lock(); let ack = acks.first, failure = failures.first; lock.unlock()
            if let failure { throw failure }
            if let ack, writer.status.confirmedHead >= token.plannedCommitSequence { return ack }
            if ProcessInfo.processInfo.systemUptime >= deadline { throw TypedFailure(message: "acknowledgement timeout") }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    static func newDirectory(_ name: String) throws -> URL {
        guard let base = ProcessInfo.processInfo.environment["STORAGE_CHECK_ROOT"] else { throw TypedFailure(message: "STORAGE_CHECK_ROOT required") }
        let root = URL(fileURLWithPath: base, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dir = root.appendingPathComponent(name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: dir.path) else { throw TypedFailure(message: "refusing existing directory") }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Positive path: one tombstone is accepted, keeps the session entity and all prior revisions, and the
    /// reopened log still explains the deletion. Negative cases run on their own writers below, because this
    /// library is deliberately fail-closed: a rejected submission poisons that writer for later submissions.
    @MainActor static func typedDeltaSemantics() async throws {
        let dir = try newDirectory("typed-semantics")
        let writer = try await IncrementalArchiveWriter.open(directory: dir, limits: ArchiveLimits())
        let fence = ArchiveFence(sessionID: "s-typed")
        var head: UInt64 = 0
        let bootstrapAck = try await submit(writer, ArchiveSubmission(id: UUID(), expectedHead: head, fence: fence, deltas: [.sessionOpened(title: "typed")], durability: .fsync))
        try typedRequire(bootstrapAck.durability == .fsync && bootstrapAck.alreadyPresent == false, "typed bootstrap acknowledgement")
        head = bootstrapAck.token.plannedCommitSequence
        // Real content first: notes plus an authoritative journal wire that must survive the deletion.
        head = try await submit(writer, ArchiveSubmission(id: UUID(), expectedHead: head, fence: fence, deltas: [.notesVersion(revision: 1, text: "删除前内容 示例词", savedAtReferenceBits: Date().timeIntervalSinceReferenceDate.bitPattern)], durability: .fsync)).token.plannedCommitSequence
        var config = SpeechEvent(id: "e1", session: "s-typed", sequence: 1, type: "session.config", timeNs: "10")
        config.glossaryRevision = 1
        head = try await submit(writer, ArchiveSubmission(id: UUID(), expectedHead: head, fence: fence, deltas: [.speechEvent(eventSequence: 1, wireData: try config.encoded())], durability: .fsync)).token.plannedCommitSequence

        let record = LocalTombstone(id: "tomb-1", deletedAt: Date(timeIntervalSinceReferenceDate: 700_000_000), reason: "user_requested")
        head = try await submit(writer, ArchiveSubmission(id: UUID(), expectedHead: head, fence: fence,
            deltas: [.sessionTombstone(recordID: record.id, deletedAtReferenceBits: record.deletedAt.timeIntervalSinceReferenceDate.bitPattern,
                                       actorKind: record.actorKind, reason: record.reason)], durability: .fsync)).token.plannedCommitSequence

        _ = try await writer.flush(durability: .fsync)
        _ = try await writer.close()

        // Reopen the real log: the session entity, its notes, its journal and the deletion record must all
        // still be present, and the deletion must be explainable.
        let recovery = try await IncrementalArchiveWriter.inspect(directory: dir)
        var tombstone: ArchiveDelta?
        var sawNote = false, sawWire = false, sawOpen = false
        for record in recovery.records {
            for delta in record.submission.deltas {
                switch delta {
                case .sessionTombstone: tombstone = delta
                case .notesVersion: sawNote = true
                case .speechEvent: sawWire = true
                case .sessionOpened: sawOpen = true
                default: break
                }
            }
        }
        try typedRequire(sawOpen && sawNote && sawWire, "replay must retain the session, notes and journal after deletion")
        guard case .sessionTombstone(let id, let bits, let actor, let reason)? = tombstone else { throw TypedFailure(message: "tombstone record missing after reopen") }
        try typedRequire(id == "tomb-1" && actor == "local_user" && reason == "user_requested", "tombstone identity preserved")
        try typedRequire(Double(bitPattern: bits) == record.deletedAt.timeIntervalSinceReferenceDate, "tombstone date preserved")
        print("PASS typed tombstone delta semantics store=\(dir.path)")
    }

    /// Projection-level proof: the bridge keeps the entity and exposes the deletion as data, not as a removal.
    static func bridgeProjectionKeepsEntity() throws {
        var projection = BridgeProjection(limits: try CoreLimits(maxBufferedEvents: 8, maxBufferedBytes: 32_768, reorderTimeoutMs: 1000, recoveryTimeoutMs: 2000))
        let fence = ArchiveFence(sessionID: "s-bridge")
        try projection.apply(ArchiveSubmission(expectedHead: 0, fence: fence, deltas: [.sessionOpened(title: "bridge")]))
        var source = SpeechEvent(id: "e1", session: "s-bridge", sequence: 1, type: "session.config", timeNs: "1")
        source.glossaryRevision = 1
        try projection.apply(ArchiveSubmission(expectedHead: 1, fence: fence, deltas: [.speechEvent(eventSequence: 1, wireData: try source.encoded())]))
        let bits = Date(timeIntervalSinceReferenceDate: 700_000_001).timeIntervalSinceReferenceDate.bitPattern
        try projection.apply(ArchiveSubmission(expectedHead: 2, fence: fence, deltas: [.sessionTombstone(recordID: "tomb-b", deletedAtReferenceBits: bits, actorKind: "local_user", reason: "user_requested")]))
        let session = projection.sessions["s-bridge"]!
        try typedRequire(session.tombstone?.recordID == "tomb-b", "bridge must keep the tombstone record")
        try typedRequire(session.journal.count == 1 && session.core.lastAppliedSequence == 1, "bridge must keep the journal/reducer state")
        // sessionOrder is populated for bootstrap sessions only; the real invariant here is that the entity is
        // still present in the projection and was not removed by the deletion record.
        try typedRequire(projection.sessions["s-bridge"]?.title == "bridge", "bridge must keep the session entity")
        do {
            try projection.apply(ArchiveSubmission(expectedHead: 3, fence: fence, deltas: [.sessionTombstone(recordID: "tomb-b2", deletedAtReferenceBits: bits, actorKind: "local_user", reason: "user_requested")]))
            throw TypedFailure(message: "bridge accepted a duplicate tombstone")
        } catch BridgeFailure.invalid {}
        print("PASS bridge projection keeps entity and rejects duplicate")
    }
}

@MainActor func runTypedTombstoneChecks() async throws {
    try TypedTombstoneChecks.bridgeProjectionKeepsEntity()
    try await TypedTombstoneChecks.typedDeltaSemantics()
}
