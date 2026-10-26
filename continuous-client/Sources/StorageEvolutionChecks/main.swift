import Foundation
import MeetingCopilotCore

// Independent storage-evolution checks for the client tree. Synthetic records only, no capture.
// Real ArchiveStore/NoteOperations APIs are exercised; nothing is stubbed or re-derived.
struct StorageFailure: Error { let message: String }
func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw StorageFailure(message: message) }
}

enum StorageEvolutionChecks {
    static func newDirectory(_ name: String) throws -> URL {
        guard let base = ProcessInfo.processInfo.environment["STORAGE_CHECK_ROOT"] else { throw StorageFailure(message: "STORAGE_CHECK_ROOT required") }
        let root = URL(fileURLWithPath: base, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dir = root.appendingPathComponent(name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: dir.path) else { throw StorageFailure(message: "refusing existing directory \(dir.path)") }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func tombstoneSurvivesReopenAndKeepsContent() throws {
        let dir = try newDirectory("tombstone-reopen")
        var archive = LocalArchive()
        var kept = LocalSession(id: "keep", title: "保留会话", tags: ["样例"])
        kept.editNotes("保留内容 😀 USD 2,450.75")
        kept.segments = [LocalSegment(id: "seg-keep", revisions: [SourceRevision(revision: 1, text: "keep source")],
                                      translations: [LocalTranslation(revision: 1, sourceRevision: 1, sourceText: "keep source", targetLanguage: "zh-Hans", text: "保留译文")])]
        var doomed = LocalSession(id: "doomed", title: "待删除会话", tags: ["示例"])
        doomed.editNotes("删除前内容 示例词")
        doomed.editNotes("删除前内容 示例词\n追加一行")
        doomed.segments = [LocalSegment(id: "seg-1", revisions: [SourceRevision(revision: 1, text: "source r1"), SourceRevision(revision: 2, text: "source r2", status: "corrected")],
                                        translations: [LocalTranslation(revision: 1, sourceRevision: 1, sourceText: "source r1", targetLanguage: "zh-Hans", text: "译文 r1")])]
        archive.sessions = [doomed, kept]

        var store: ArchiveStore? = ArchiveStore(directory: dir)
        archive = try store!.save(archive)
        let record = try LocalDeletion.tombstone(&archive, sessionID: "doomed", reason: "user_requested")
        // Deleting never removes content, revisions or the authoritative journal from the record.
        let deletedSource = archive.sessions.first { $0.id == "doomed" }!
        try require(deletedSource.segments.count == 1 && deletedSource.segments[0].revisions.count == 2, "tombstone must not drop revisions")
        try require(deletedSource.segments[0].translations.count == 1 && deletedSource.noteHistory.count == 2, "tombstone must not drop translations/notes")
        try require(archive.activeSessions.map(\.id) == ["keep"], "deleted session must leave the active view")
        archive = try store!.save(archive)
        store = nil

        // Reopen with a fresh store instance: the deletion must still be explainable from disk.
        let reopened = try ArchiveStore(directory: dir).load()
        try require(reopened.sessions.count == 2, "reopen must keep both records")
        let reopenedDeleted = reopened.sessions.first { $0.id == "doomed" }!
        try require(reopenedDeleted.tombstone?.id == record.id, "reopen must preserve the tombstone record id")
        try require(reopenedDeleted.tombstone?.reason == "user_requested", "reopen must preserve the deletion reason")
        try require(reopenedDeleted.notes.contains("追加一行"), "reopen must retain deleted content for audit")
        try require(reopened.activeSessions.map(\.id) == ["keep"], "reopen must keep the deleted session out of the active view")
        let audit = LocalDeletion.auditLines(reopened)
        try require(audit.count == 1 && audit[0].contains(record.id) && audit[0].contains("待删除会话"), "audit must explain the deletion")

        // Idempotence: a second delete attempt must not create a second tombstone or change content.
        var again = reopened
        do { _ = try LocalDeletion.tombstone(&again, sessionID: "doomed"); throw StorageFailure(message: "duplicate tombstone was accepted") }
        catch LocalDeletion.Failure.alreadyDeleted {}
        try require(again == reopened, "duplicate delete must not mutate the archive")

        // Reopen twice more: repeated reopen must be stable, not accumulate records.
        let second = try ArchiveStore(directory: dir).load()
        let third = try ArchiveStore(directory: dir).load()
        try require(second == third, "repeated reopen must be stable")
        try require(third.deletedSessions.count == 1, "repeated reopen must not duplicate tombstones")
        print("PASS tombstone reopen/audit/idempotence store=\(dir.path)")
    }

    static func legacyFileWithoutTombstoneStillOpens() throws {
        let dir = try newDirectory("legacy-no-tombstone")
        // A pre-tombstone record on disk: no tombstone key at all.
        let legacy = """
        {"schemaVersion":1,"generation":3,"sessions":[{"id":"legacy","title":"旧会话","createdAt":760000000.0,"isDemo":false,"notes":"旧内容","tags":["旧"],"noteHistory":[{"revision":1,"text":"旧内容","savedAt":760000000.0}],"segments":[],"speechJournal":[]}]}
        """
        try Data(legacy.utf8).write(to: dir.appendingPathComponent("sessions.json"))
        let archive = try ArchiveStore(directory: dir).load()
        try require(archive.sessions.count == 1, "legacy record must still load")
        try require(archive.sessions[0].tombstone == nil && !archive.sessions[0].isDeleted, "legacy record must read as not deleted")
        try require(archive.activeSessions.count == 1, "legacy record must stay active")
        try require(archive.sessions[0].notes == "旧内容" && archive.sessions[0].tags == ["旧"], "legacy notes/tags must be preserved")
        print("PASS legacy compatibility store=\(dir.path)")
    }
}

@main struct StorageEvolutionMain {
    @MainActor static func main() async {
        do {
            try StorageEvolutionChecks.tombstoneSurvivesReopenAndKeepsContent()
            try StorageEvolutionChecks.legacyFileWithoutTombstoneStillOpens()
            try await runTypedTombstoneChecks()
            // One rejected submission poisons its writer by design: each negative case gets its own.
            try await TypedTombstoneNegatives.rejectsWrongScope()
            try await TypedTombstoneNegatives.rejectsEmptyReason()
            try await TypedTombstoneNegatives.rejectsEmptyIdentity()
            try await TypedTombstoneNegatives.rejectsDuplicate()
            try await runMaterialChunkChecks()
            try await runLegacyMigrationChecks()
            try await runReopenSelectionChecks()
            try await runLegacyVisibilityChecks()
            try await runEngineIdentityChecks()
            print("STORAGE_EVOLUTION_CHECKS_COMPLETE")
        } catch {
            print("STORAGE_EVOLUTION_CHECKS_FAILED: \(error)")
            exit(2)
        }
    }
}
