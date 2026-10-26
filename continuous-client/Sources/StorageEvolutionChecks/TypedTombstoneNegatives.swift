import Foundation
import IncrementalArchive
import MeetingCopilotCore

// Negative tombstone cases. This archive library is deliberately fail-closed: one rejected submission
// poisons its writer, so every rejection is proven on its own writer in its own directory. The exact
// recorded failure is compared; nothing here re-derives an expected error text.
enum TypedTombstoneNegatives {
    /// The rejection must be the exact recorded guard, not an unrelated earlier failure.
    static func expectFailure(_ expected: ArchiveFailure, _ body: () async throws -> Void, label: String) async throws {
        do {
            try await body()
            throw TypedFailure(message: "\(label): rejected submission was accepted")
        } catch let failure as ArchiveFailure {
            try typedRequire(failure == expected, "\(label): unexpected failure \(failure)")
        }
    }

    static func expectFenceFailure(_ body: () async throws -> Void, label: String) async throws {
        try await expectFailure(.fence("tombstone scope/duplicate/identity"), body, label: label)
    }

    static func openedWriter(_ name: String, session: String) async throws -> (IncrementalArchiveWriter, UInt64, URL) {
        let dir = try TypedTombstoneChecks.newDirectory(name)
        let writer = try await IncrementalArchiveWriter.open(directory: dir, limits: ArchiveLimits())
        let ack = try await TypedTombstoneChecks.submit(writer, ArchiveSubmission(
            id: UUID(), expectedHead: 0, fence: ArchiveFence(sessionID: session),
            deltas: [.sessionOpened(title: "negative")], durability: .fsync))
        return (writer, ack.token.plannedCommitSequence, dir)
    }

    static func deletionDelta(record: String, reason: String, head: UInt64, fence: ArchiveFence) -> ArchiveSubmission {
        ArchiveSubmission(id: UUID(), expectedHead: head, fence: fence, deltas: [.sessionTombstone(
            recordID: record, deletedAtReferenceBits: Date().timeIntervalSinceReferenceDate.bitPattern,
            actorKind: "local_user", reason: reason)], durability: .fsync)
    }

    /// Count the deletion records really present in the reopened log.
    static func tombstonesOnDisk(_ dir: URL) async throws -> Int {
        let recovery = try await IncrementalArchiveWriter.inspect(directory: dir)
        var count = 0
        for record in recovery.records {
            for delta in record.submission.deltas { if case .sessionTombstone = delta { count += 1 } }
        }
        return count
    }

    /// Wrong scope: a deletion claiming an attempt/generation fence must never tombstone a session.
    static func rejectsWrongScope() async throws {
        let (writer, head, dir) = try await openedWriter("typed-negative-scope", session: "s-scope")
        let attemptFence = ArchiveFence(sessionID: "s-scope", attemptID: "a-1", generationID: UUID())
        // Open the attempt for real first, so the rejection is the deletion's scope guard itself and not
        // the unknown-attempt guard that would fire for any delta on an unopened attempt.
        let opened = try await TypedTombstoneChecks.submit(writer, ArchiveSubmission(id: UUID(), expectedHead: head,
            fence: attemptFence, deltas: [.attemptBegan(requiresTerminalCoverage: false)], durability: .fsync))
        try await expectFenceFailure({
            _ = try await TypedTombstoneChecks.submit(writer, deletionDelta(record: "scope-record", reason: "user_requested",
                                                                            head: opened.token.plannedCommitSequence, fence: attemptFence))
        }, label: "wrong scope")
        let scopeRecords = try await tombstonesOnDisk(dir)
        try typedRequire(scopeRecords == 0, "rejected scope must leave no deletion record on disk")
        print("PASS negative: attempt-fenced tombstone rejected, log unchanged")
    }

    /// Empty reason: an unexplained deletion is not auditable and must be refused.
    static func rejectsEmptyReason() async throws {
        let (writer, head, dir) = try await openedWriter("typed-negative-reason", session: "s-reason")
        try await expectFenceFailure({
            _ = try await TypedTombstoneChecks.submit(writer, deletionDelta(record: "reason-record", reason: "", head: head, fence: ArchiveFence(sessionID: "s-reason")))
        }, label: "empty reason")
        let reasonRecords = try await tombstonesOnDisk(dir)
        try typedRequire(reasonRecords == 0, "rejected empty reason must leave no deletion record on disk")
        print("PASS negative: empty reason rejected, log unchanged")
    }

    /// Empty record identity: a deletion that cannot be named afterwards is not auditable.
    static func rejectsEmptyIdentity() async throws {
        let (writer, head, dir) = try await openedWriter("typed-negative-identity", session: "s-identity")
        // An empty identity is refused at admission (before any record is written), not at the fence guard.
        try await expectFailure(.invalidInput("tombstone identity/date"), {
            _ = try await TypedTombstoneChecks.submit(writer, deletionDelta(record: "", reason: "user_requested", head: head, fence: ArchiveFence(sessionID: "s-identity")))
        }, label: "empty identity")
        let identityRecords = try await tombstonesOnDisk(dir)
        try typedRequire(identityRecords == 0, "rejected empty identity must leave no deletion record on disk")
        print("PASS negative: empty identity rejected, log unchanged")
    }

    /// Duplicate deletion on the same session: the first record is acknowledged, the second is refused,
    /// and the reopened log still holds exactly one deletion record.
    static func rejectsDuplicate() async throws {
        let (writer, head, dir) = try await openedWriter("typed-negative-duplicate", session: "s-dup")
        let fence = ArchiveFence(sessionID: "s-dup")
        let accepted = try await TypedTombstoneChecks.submit(writer, deletionDelta(record: "dup-record-1", reason: "user_requested", head: head, fence: fence))
        try await expectFenceFailure({
            _ = try await TypedTombstoneChecks.submit(writer, deletionDelta(record: "dup-record-2", reason: "user_requested",
                                                                            head: accepted.token.plannedCommitSequence, fence: fence))
        }, label: "duplicate")
        let duplicateRecords = try await tombstonesOnDisk(dir)
        try typedRequire(duplicateRecords == 1, "duplicate rejection must leave exactly the first deletion record")
        print("PASS negative: duplicate tombstone rejected, single record retained")
    }
}
