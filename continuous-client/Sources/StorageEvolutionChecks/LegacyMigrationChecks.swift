import Foundation
import MeetingCopilotCore
import ClientRuntime
import IncrementalArchive
import ClientIncrementalBridge
import SpeechCore

// Legacy `sessions.json` migration checks. The claims under test, all against the real writer/ledger and the
// real reopened projection (nothing is stubbed):
//  * the original file is byte-identical AND untouched (same mtime/inode) after a migration;
//  * an item the typed contract cannot express is reported item by item ("未迁移该项"), never dropped;
//  * a partial migration never becomes ready;
//  * a re-run of a completed migration writes nothing new and does not double-bootstrap;
//  * a re-run honestly reports what is still un-migrated instead of silently declaring a clean state.
struct LegacyCheckFailure: Error { let message: String }
func legacyRequire(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw LegacyCheckFailure(message: message) }
}

enum LegacyMigrationChecks {
    static func limits() throws -> CoreLimits {
        try CoreLimits(maxBufferedEvents: 64, maxBufferedBytes: 1 << 20, reorderTimeoutMs: 100, recoveryTimeoutMs: 2000)
    }

    /// Builds the exact legacy fixture on disk through the real ArchiveStore (a real pre-incremental file).
    /// Session `legacy-a` carries a genuinely unfinished attempt; `legacy-b` has a segment with no authoritative
    /// journal wire. Both attempts are un-expressible in the typed contract, for different reasons. Attempt
    /// lifecycles are chosen so the model's own launch-time interruption normalisation does not rewrite the file:
    /// that normalisation is pre-existing product behaviour, and this fixture isolates the MIGRATION step.
    static func writeLegacyFixture(directory: URL) throws -> (URL, LocalArchive) {
        var a = LocalSession(id: "legacy-a", title: "旧档会话 A", tags: ["样例", "示例"])
        a.editNotes("旧随记第一版 示例词")
        a.editNotes("旧随记第二版 示例词 😀")
        let source = SpeechEvent(id: "ev-1", session: "legacy-a", sequence: 1, type: "asr.segment", timeNs: "1000")
        var wire1 = source
        wire1.segmentId = "seg-a"; wire1.revision = 1; wire1.status = "final"; wire1.text = "示例 source"
        wire1.startNs = "0"; wire1.endNs = "1000000000"
        var wire2 = SpeechEvent(id: "ev-2", session: "legacy-a", sequence: 2, type: "translation.segment", timeNs: "2000")
        wire2.translationId = "tr-1"; wire2.segmentId = "seg-a"; wire2.revision = 1; wire2.status = "final"
        wire2.sourceRevision = 1; wire2.sourceText = "示例 source"; wire2.targetLanguage = "zh-Hans"
        wire2.translatedText = "示例译文"; wire2.glossaryRevision = 0
        a.speechJournal = [try wire1.encoded(), try wire2.encoded()]
        a.segments = [LocalSegment(id: "seg-a",
            revisions: [SourceRevision(revision: 1, text: "示例 source", status: "final", startNS: "0", endNS: "1000000000")],
            translations: [LocalTranslation(id: "tr-1", revision: 1, sourceRevision: 1, sourceText: "示例 source",
                                            targetLanguage: "zh-Hans", text: "示例译文")])]
        var attempt = LocalCaptureAttempt(id: "attempt-a", channelID: "mic", streamID: "s-1", segmentID: "seg-a", locale: "zh-Hans")
        attempt.lifecycle = "completed"
        attempt.deviceStarted = true; attempt.audioObserved = true; attempt.asrObserved = false
        attempt.history = ["started", "stopped"]
        a.captureAttempts = [attempt]

        var b = LocalSession(id: "legacy-b", title: "旧档会话 B", tags: [])
        b.segments = [LocalSegment(id: "seg-b", revisions: [SourceRevision(revision: 1, text: "无权威 wire")])]
        var attemptB = LocalCaptureAttempt(id: "attempt-b", channelID: "mic", streamID: "s-2", segmentID: "seg-b", locale: "zh-Hans")
        attemptB.lifecycle = "cancelled"
        b.captureAttempts = [attemptB]

        var archive = LocalArchive(); archive.sessions = [a, b]
        let store = ArchiveStore(directory: directory)
        archive = try store.save(archive)
        return (store.fileURL, archive)
    }

    /// The whole read-only migration through the real public product path, then a reopen of the same store.
    @MainActor static func migrationIsReadOnlyAndHonest() async throws {
        let dir = try StorageEvolutionChecks.newDirectory("legacy-migration")
        let (legacyURL, legacy) = try writeLegacyFixture(directory: dir)
        let before = try LegacyFileFingerprint.capture(legacyURL)

        let model = ClientModel(directory: dir, configURL: materialCheckConfigURL)
        try legacyRequire(model.loaded && model.archive.sessions.count == 2, "the legacy archive loads before enabling")

        let enabled = await model.enableIncrementalPersistence(limits: try limits())
        try legacyRequire(enabled, "a migratable legacy archive enables the incremental store: \(model.incrementalSavingStatus)")
        guard let report = model.incrementalMigrationReport else { throw LegacyCheckFailure(message: "no migration report was produced") }

        // 1. the original is untouched: identical bytes, mtime and inode.
        let after = try LegacyFileFingerprint.capture(legacyURL)
        try legacyRequire(after == before, "legacy file must be byte-identical and untouched (\(before.summary) vs \(after.summary))")
        try legacyRequire(after.inode == before.inode && after.modifiedNanoseconds == before.modifiedNanoseconds,
                          "legacy file must not be rewritten (same inode and mtime)")
        // Always emit the raw fingerprint pair: a parent can re-check these numbers itself, and can tell
        // "bytes unchanged but the file was rewritten" (new inode/mtime) from "never touched at all".
        print("EVIDENCE legacy original BEFORE: \(before.summary)")
        print("EVIDENCE legacy original AFTER : \(after.summary)")
        print("EVIDENCE legacy original path  : \(legacyURL.path)")
        let stillOnDisk = try ArchiveStore(directory: dir).load()
        try legacyRequire(stillOnDisk == legacy, "the legacy archive content is still exactly what it was")
        try legacyRequire(stillOnDisk.sessions[1].segments.count == 1, "the un-migrated segment still exists in the untouched original")

        // 2. explicit, item-by-item account of what was NOT migrated.
        try legacyRequire(report.migratedSessions == ["legacy-a", "legacy-b"], "both session identities are migrated")
        try legacyRequire(report.notMigrated(item: "capture-attempt", identity: "attempt-a") != nil,
                          "the unfinished attempt is reported as not migrated, not dropped")
        try legacyRequire(report.notMigrated(item: "capture-attempt", identity: "attempt-b") != nil,
                          "a second not-migrated attempt is reported too")
        try legacyRequire(report.notMigrated(item: "segment", identity: "seg-b") != nil,
                          "the segment without an authoritative wire is reported as not migrated")
        try legacyRequire(report.notMigratedCount >= 3, "the report counts every not-migrated item (\(report.notMigratedCount))")
        try legacyRequire(model.incrementalSavingStatus.contains("未迁移项"),
                          "the user-visible status names the un-migrated items: \(model.incrementalSavingStatus)")
        try legacyRequire(model.incrementalMigrationBlock == nil, "a completed migration has no block")

        // 3. the migrated subset is really durable and really reopens.
        let recordsAfterMigration = try await IncrementalArchiveWriter.inspect(directory: dir.appendingPathComponent("incremental")).records.count
        try legacyRequire(recordsAfterMigration > 0, "the migration wrote real records (\(recordsAfterMigration))")
        let reopened = ClientModel(directory: dir, configURL: materialCheckConfigURL)
        let restored = await reopened.enableIncrementalPersistence(limits: try limits())
        try legacyRequire(restored, "the migrated store reopens: \(reopened.incrementalSavingStatus)")
        try legacyRequire(reopened.archive.sessions.map(\.id) == ["legacy-a", "legacy-b"], "reopen keeps the legacy session order")
        let sessionA = reopened.archive.sessions[0]
        try legacyRequire(sessionA.title == "旧档会话 A" && sessionA.tags == ["样例", "示例"], "title and tags survived")
        try legacyRequire(sessionA.noteHistory.map(\.revision) == [1, 2] && sessionA.noteHistory[1].text.contains("😀"),
                          "every legacy note revision survived with its text")
        try legacyRequire(sessionA.segments.count == 1 && sessionA.segments[0].id == "seg-a", "the authoritative segment survived")
        try legacyRequire(sessionA.segments[0].revisions.map(\.revision) == [1] && sessionA.segments[0].revisions[0].text == "示例 source",
                          "the migrated source revision matches the legacy one")
        try legacyRequire(sessionA.segments[0].translations.map(\.id) == ["tr-1"]
                            && sessionA.segments[0].translations[0].text == "示例译文", "the migrated translation matches the legacy one")
        try legacyRequire(sessionA.captureAttempts.isEmpty, "an attempt that could not be expressed is absent from the new store")
        try legacyRequire(reopened.incrementalMigrationReport?.alreadyMigratedSessions == ["legacy-a", "legacy-b"],
                          "the second run is reported as a read-only verification")
        try legacyRequire(reopened.incrementalSavingStatus.contains("只读校验"),
                          "the second run says it was read-only: \(reopened.incrementalSavingStatus)")

        // 4. a re-run writes nothing new and never bootstraps twice.
        let recordsAfterRerun = try await IncrementalArchiveWriter.inspect(directory: dir.appendingPathComponent("incremental")).records.count
        try legacyRequire(recordsAfterRerun == recordsAfterMigration,
                          "a re-run must not add records (\(recordsAfterMigration) -> \(recordsAfterRerun))")
        let finalFingerprint = try LegacyFileFingerprint.capture(legacyURL)
        try legacyRequire(finalFingerprint == before, "the original is still untouched after a re-run")
        print("PASS legacy read-only migration (\(recordsAfterMigration) records, \(report.notMigratedCount) 未迁移项, original untouched)")
    }

    /// A store that only holds PART of the legacy sessions must refuse: no readiness, no silent completion,
    /// and the original file is left exactly as it was.
    @MainActor static func partialMigrationIsNeverReady() async throws {
        let dir = try StorageEvolutionChecks.newDirectory("legacy-partial")
        let (legacyURL, legacy) = try writeLegacyFixture(directory: dir)
        let before = try LegacyFileFingerprint.capture(legacyURL)

        // A real partial state: exactly what an interrupted migration leaves behind. Session A's typed
        // bootstrap really reached the log (submitted by the writer itself, with A's own identity), session B's
        // never did. Nothing about A is invented here: title/date/tags are the legacy session's own values.
        guard let partial = legacy.sessions.first(where: { $0.id == "legacy-a" }) else {
            throw LegacyCheckFailure(message: "fixture missing legacy-a")
        }
        let incrementalDir = dir.appendingPathComponent("incremental", isDirectory: true)
        let writer = try await IncrementalArchiveWriter.open(directory: incrementalDir, limits: ArchiveLimits())
        _ = try await TypedTombstoneChecks.submit(writer, ArchiveSubmission(id: UUID(), expectedHead: 0,
            fence: ArchiveFence(sessionID: partial.id),
            deltas: [.sessionBootstrap(ArchiveSessionBootstrap(title: partial.title,
                createdAtReferenceBits: partial.createdAt.timeIntervalSinceReferenceDate.bitPattern,
                isDemo: partial.isDemo, initialNotes: "", tags: partial.tags))], durability: .fsync))
        _ = try await writer.close()
        let recordsOfPartial = try await IncrementalArchiveWriter.inspect(directory: incrementalDir).records.count
        try legacyRequire(recordsOfPartial == 1, "the partial state has exactly one record (\(recordsOfPartial))")

        let model = ClientModel(directory: dir, configURL: materialCheckConfigURL)
        let enabled = await model.enableIncrementalPersistence(limits: try limits())
        try legacyRequire(!enabled, "a partial migration must not enable the store")
        try legacyRequire(model.incremental == nil, "a partial migration must not create an incremental store")
        let block = model.incrementalMigrationBlock ?? ""
        try legacyRequire(block.contains("legacy-a") && block.contains("未置就绪"),
                          "the refusal names the half-migrated session and says it is not ready: \(block)")
        try legacyRequire(model.incrementalSavingStatus.contains("原档未改动"), "the status says the original was not modified")
        let after = try LegacyFileFingerprint.capture(legacyURL)
        try legacyRequire(after == before, "a refused migration leaves the original untouched")
        let recordsAfterRefusal = try await IncrementalArchiveWriter.inspect(directory: incrementalDir).records.count
        try legacyRequire(recordsAfterRefusal == recordsOfPartial, "a refused migration writes nothing further (\(recordsAfterRefusal))")
        print("PASS partial legacy migration refused, not ready, original untouched")
    }

    /// An incremental store that already holds the same session id with a DIFFERENT identity must refuse rather
    /// than overwrite it, and must not adopt the legacy file.
    @MainActor static func conflictingIdentityIsRefused() async throws {
        let dir = try StorageEvolutionChecks.newDirectory("legacy-conflict")
        // 1. an incremental store on its own (no legacy file yet) holding session `legacy-a`.
        let first = ClientModel(directory: dir, configURL: materialCheckConfigURL)
        first.archive.sessions = [LocalSession(id: "legacy-a", title: "不同的标题")]
        let opened = await first.enableIncrementalPersistence(limits: try limits())
        try legacyRequire(opened, "the conflicting fixture opens an incremental store")
        _ = try await first.incremental!.awaitQuiescence()
        let records = try await IncrementalArchiveWriter.inspect(directory: dir.appendingPathComponent("incremental")).records.count
        try legacyRequire(records == 1, "the conflicting fixture has one record")

        // 2. now a legacy file appears beside it, with the same id but a different identity.
        var archive = LocalArchive()
        archive.sessions = [LocalSession(id: "legacy-a", title: "旧档标题")]
        _ = try ArchiveStore(directory: dir).save(archive)
        let legacyURL = dir.appendingPathComponent("sessions.json")
        let before = try LegacyFileFingerprint.capture(legacyURL)

        let model = ClientModel(directory: dir, configURL: materialCheckConfigURL)
        let enabled = await model.enableIncrementalPersistence(limits: try limits())
        try legacyRequire(!enabled, "a conflicting identity must not enable the store")
        let block = model.incrementalMigrationBlock ?? ""
        try legacyRequire(block.contains("拒绝自动覆盖"), "the refusal explains why it will not overwrite: \(block)")
        try legacyRequire(model.incremental == nil, "no store is adopted on a conflict")
        let after = try LegacyFileFingerprint.capture(legacyURL)
        try legacyRequire(after == before, "the conflicting legacy file is untouched")
        let recordsAfter = try await IncrementalArchiveWriter.inspect(directory: dir.appendingPathComponent("incremental")).records.count
        try legacyRequire(recordsAfter == records, "a conflict writes nothing (\(recordsAfter))")
        print("PASS conflicting legacy identity refused, existing records untouched")
    }

    /// The retry-after-interruption case in its clean form: one whole session is already fully migrated and
    /// verified, the other never started. The retry must submit ONLY the missing one, add records, and never
    /// bootstrap the already-migrated session a second time.
    @MainActor static func resumeCompletesOnlyMissingSessions() async throws {
        let dir = try StorageEvolutionChecks.newDirectory("legacy-resume")
        let (legacyURL, legacy) = try writeLegacyFixture(directory: dir)
        let before = try LegacyFileFingerprint.capture(legacyURL)

        // Build the real plan and submit ONLY legacy-a's batches, exactly as an interrupted run would leave it.
        let plan = LegacyMigrationPlanner.plan(legacy, coreLimits: try limits())
        try legacyRequire(plan.fatal == nil, "the fixture plans cleanly")
        let incrementalDir = dir.appendingPathComponent("incremental", isDirectory: true)
        let writer = try await IncrementalArchiveWriter.open(directory: incrementalDir, limits: ArchiveLimits())
        var head: UInt64 = 0
        // A genuine interruption leaves a PREFIX of the real submission order, and the plan groups each
        // session's batches consecutively. The prefix used here ends exactly on a session boundary, which is the
        // only prefix shape that leaves whole sessions intact: everything before the cut is durable, the rest
        // never started.
        let allBatches = plan.batches
        guard let firstSession = allBatches.first?.session else { throw LegacyCheckFailure(message: "empty plan") }
        let prefixCount = allBatches.prefix { $0.session == firstSession }.count
        try legacyRequire(prefixCount < allBatches.count, "the boundary prefix really leaves a session unstarted")
        for batch in allBatches.prefix(prefixCount) {
            head = try await TypedTombstoneChecks.submit(writer, ArchiveSubmission(id: UUID(), expectedHead: head,
                fence: ArchiveFence(sessionID: batch.session), deltas: batch.deltas, durability: .fsync)).token.plannedCommitSequence
        }
        _ = try await writer.flush(durability: .fsync)
        _ = try await writer.close()
        let recordsBefore = try await IncrementalArchiveWriter.inspect(directory: incrementalDir).records.count
        try legacyRequire(head == UInt64(recordsBefore), "the interrupted prefix accounts for all \(recordsBefore) records")
        let durableSession = firstSession
        let untouchedSession = plan.expectedOrder.first { $0 != durableSession }!
        try legacyRequire(plan.expectedOrder.contains(durableSession), "the durable session is a real legacy session")

        let model = ClientModel(directory: dir, configURL: materialCheckConfigURL)
        let enabled = await model.enableIncrementalPersistence(limits: try limits())
        try legacyRequire(enabled, "a resumable store enables: \(model.incrementalSavingStatus)")
        guard let report = model.incrementalMigrationReport else { throw LegacyCheckFailure(message: "no report on resume") }
        try legacyRequire(report.alreadyMigratedSessions == [durableSession], "the already-durable session is reported as skipped (\(report.alreadyMigratedSessions))")
        try legacyRequire(report.migratedSessions == ["legacy-a", "legacy-b"], "both sessions are accounted for after the resume")
        try legacyRequire(model.incrementalSavingStatus.contains("续做"), "the status says the migration was continued: \(model.incrementalSavingStatus)")

        let recordsAfter = try await IncrementalArchiveWriter.inspect(directory: incrementalDir).records.count
        try legacyRequire(recordsAfter > recordsBefore, "the resume really added the missing session's records (\(recordsBefore) -> \(recordsAfter))")
        // The already-migrated session must not have been bootstrapped a second time: exactly one bootstrap per session.
        let records = try await IncrementalArchiveWriter.inspect(directory: incrementalDir).records
        let bootstraps = records.flatMap(\.submission.deltas).filter {
            if case .sessionBootstrap = $0 { return true }; return false
        }.count
        try legacyRequire(bootstraps == 2, "exactly one bootstrap per session, no duplicate bootstrap (\(bootstraps) for 2 sessions)")
        let after = try LegacyFileFingerprint.capture(legacyURL)
        try legacyRequire(after == before, "a resumed migration still leaves the original untouched")

        // And the resumed store reopens with both sessions' real content, in the legacy order.
        let reopened = ClientModel(directory: dir, configURL: materialCheckConfigURL)
        let restoredAgain = await reopened.enableIncrementalPersistence(limits: try limits())
        try legacyRequire(restoredAgain, "the resumed store reopens")
        try legacyRequire(reopened.archive.sessions.map(\.id) == ["legacy-a", "legacy-b"],
                          "reopen keeps both sessions in the legacy order (\(reopened.archive.sessions.map(\.id)))")
        let skipped = reopened.archive.sessions.first { $0.id == durableSession }!
        let added = reopened.archive.sessions.first { $0.id == untouchedSession }!
        try legacyRequire(skipped.title == "旧档会话 A" || skipped.title == "旧档会话 B", "the skipped session kept its title")
        try legacyRequire(added.title == "旧档会话 B" || added.title == "旧档会话 A", "the newly migrated session is present")
        try legacyRequire(reopened.archive.sessions.reduce(0) { $0 + $1.noteHistory.count } == 2,
                          "the originally migrated session's note revisions are intact after the resume")
        print("PASS resume completes only missing sessions (\(recordsBefore) -> \(recordsAfter) records, no duplicate bootstrap, order kept)")
    }

    /// Adversarial resume: the durable set is the EARLIER legacy session only. New bootstraps insert at the
    /// front, so naively submitting the missing later session would produce [later, earlier] and silently
    /// reorder the list. This must end as a not-ready state, never as a reordered store.
    @MainActor static func resumeNeverReordersTheList() async throws {
        let dir = try StorageEvolutionChecks.newDirectory("legacy-resume-order")
        let (legacyURL, legacy) = try writeLegacyFixture(directory: dir)
        let before = try LegacyFileFingerprint.capture(legacyURL)
        let plan = LegacyMigrationPlanner.plan(legacy, coreLimits: try limits())
        try legacyRequire(plan.expectedOrder == ["legacy-a", "legacy-b"], "fixture order")
        // Only the earlier legacy session's batches are durable, which is NOT a prefix of the plan's own
        // batch order (the plan emits the later session first).
        let incrementalDir = dir.appendingPathComponent("incremental", isDirectory: true)
        let writer = try await IncrementalArchiveWriter.open(directory: incrementalDir, limits: ArchiveLimits())
        var head: UInt64 = 0
        for batch in plan.batches where batch.session == "legacy-a" {
            head = try await TypedTombstoneChecks.submit(writer, ArchiveSubmission(id: UUID(), expectedHead: head,
                fence: ArchiveFence(sessionID: batch.session), deltas: batch.deltas, durability: .fsync)).token.plannedCommitSequence
        }
        _ = try await writer.flush(durability: .fsync)
        _ = try await writer.close()
        let recordsBefore = try await IncrementalArchiveWriter.inspect(directory: incrementalDir).records.count

        let model = ClientModel(directory: dir, configURL: materialCheckConfigURL)
        let enabled = await model.enableIncrementalPersistence(limits: try limits())
        try legacyRequire(!enabled, "a resume that would reorder the list must not become ready")
        try legacyRequire(model.incremental == nil, "no store is adopted on an order conflict")
        let block = model.incrementalMigrationBlock ?? ""
        try legacyRequire(block.contains("可见顺序"),
                          "the refusal names the real reason (visible order): \(block)")
        let after = try LegacyFileFingerprint.capture(legacyURL)
        try legacyRequire(after == before, "an order-refused migration leaves the original untouched")
        let recordsAfter = try await IncrementalArchiveWriter.inspect(directory: incrementalDir).records.count
        try legacyRequire(recordsAfter > recordsBefore, "the refused attempt may add records, but must not claim readiness")
        // The store, read directly, really does hold the WRONG order: that is why refusing was correct.
        let recovery = try await IncrementalArchiveWriter.inspect(directory: incrementalDir)
        var projection = BridgeProjection(limits: try limits())
        for record in recovery.records { try projection.apply(record.submission) }
        try legacyRequire(projection.sessionOrder == ["legacy-b", "legacy-a"],
                          "the underlying projection really is reordered (\(projection.sessionOrder))")
        print("PASS resume never silently reorders the session list (refused, original untouched)")
    }

    /// The verifier must reject a migrated store whose visible session order differs from the legacy order.
    /// This is a real failure mode: a resumed migration that skips a session and later re-bootstraps an earlier
    /// one inserts it at the front, which silently reorders the list. It must be caught, not accepted.
    static func verifierRejectsWrongVisibleOrder() throws {
        var projection = BridgeProjection(limits: try limits())
        let bits = Date(timeIntervalSinceReferenceDate: 700_000_123).timeIntervalSinceReferenceDate.bitPattern
        // Bootstrapped in the WRONG order: "second" first, then "first". Each bootstrap lands at index 0, so the
        // visible order ends up ["first", "second"], while the legacy order we ask to verify is the reverse.
        for id in ["second", "first"] {
            try projection.apply(ArchiveSubmission(expectedHead: projection.head, fence: ArchiveFence(sessionID: id),
                deltas: [.sessionBootstrap(ArchiveSessionBootstrap(title: id, createdAtReferenceBits: bits,
                                                                   isDemo: false, initialNotes: "", tags: []))]))
        }
        func expectation(_ id: String) -> LegacySessionExpectation {
            LegacySessionExpectation(title: id, createdAtReferenceBits: bits, isDemo: false, tags: [])
        }
        let correct = LegacyMigrationVerifier.failures(["first": expectation("first"), "second": expectation("second")],
                                                       order: ["first", "second"], projection: projection)
        try legacyRequire(correct.isEmpty, "the correct visible order verifies clean: \(correct)")
        let wrong = LegacyMigrationVerifier.failures(["first": expectation("first"), "second": expectation("second")],
                                                     order: ["second", "first"], projection: projection)
        try legacyRequire(wrong.contains { $0.contains("可见顺序") },
                          "a wrong visible order is reported as a failure, never accepted: \(wrong)")
        print("PASS verifier rejects a wrong visible session order")
    }

    /// The planner itself must account for data the typed contract cannot express, without inventing it.
    static func plannerReportsUnrepresentableItems() throws {
        let dir = try StorageEvolutionChecks.newDirectory("legacy-planner")
        let (_, archive) = try writeLegacyFixture(directory: dir)
        let plan = LegacyMigrationPlanner.plan(archive, coreLimits: try limits())
        try legacyRequire(plan.fatal == nil, "the fixture is migratable: \(plan.fatal ?? "")")
        try legacyRequire(plan.expectedOrder == ["legacy-a", "legacy-b"], "the plan keeps the legacy session order")
        // The journal is replayed as-is: the sequence the wire already carries is never re-allocated.
        let sourceDelta = plan.batches.flatMap(\.deltas).first { if case .sourceRevision = $0 { return true }; return false }
        guard case .sourceRevision(let id, let revision, let sequence, _)? = sourceDelta else {
            throw LegacyCheckFailure(message: "the journal wire must become a typed source revision")
        }
        try legacyRequire(id == "seg-a" && revision == 1 && sequence == 1, "source revision keeps the wire's own id/revision/sequence")
        let translations = plan.batches.flatMap(\.deltas).filter { if case .translationRevision = $0 { return true }; return false }
        try legacyRequire(translations.count == 1, "exactly one translation revision is planned")
        try legacyRequire(plan.report.notMigrated(item: "capture-attempt", identity: "attempt-a") != nil,
                          "the plan reports the un-expressible attempt")
        try legacyRequire(plan.report.notMigrated(item: "segment", identity: "seg-b") != nil,
                          "the plan reports the segment with no authoritative wire")
        print("PASS planner accounts for unrepresentable items (\(plan.report.notMigratedCount) 未迁移项)")
    }

    /// The physical-identity fingerprint must be able to tell "rewritten with identical bytes" from "untouched".
    static func fingerprintDistinguishesRewrite() throws {
        let dir = try StorageEvolutionChecks.newDirectory("legacy-fingerprint")
        let url = dir.appendingPathComponent("sessions.json")
        try Data("{\"schemaVersion\":1,\"generation\":0,\"sessions\":[]}".utf8).write(to: url)
        let before = try LegacyFileFingerprint.capture(url)
        // Identical bytes, but a real rewrite: mtime must change, so the fingerprint must differ.
        try await_(0.02)
        let same = try Data(contentsOf: url)
        try same.write(to: url, options: .atomic)
        let after = try LegacyFileFingerprint.capture(url)
        try legacyRequire(after.sha256 == before.sha256, "the rewritten file really has identical bytes")
        try legacyRequire(after.modifiedNanoseconds != before.modifiedNanoseconds || after.inode != before.inode,
                          "a byte-identical rewrite is still distinguishable from 'never touched'")
        print("PASS fingerprint distinguishes a byte-identical rewrite from an untouched file")
    }
    private static func await_(_ seconds: TimeInterval) throws {
        Thread.sleep(forTimeInterval: seconds)
    }
}

@MainActor func runLegacyMigrationChecks() async throws {
    try LegacyMigrationChecks.fingerprintDistinguishesRewrite()
    try LegacyMigrationChecks.verifierRejectsWrongVisibleOrder()
    try LegacyMigrationChecks.plannerReportsUnrepresentableItems()
    try await LegacyMigrationChecks.migrationIsReadOnlyAndHonest()
    try await LegacyMigrationChecks.resumeCompletesOnlyMissingSessions()
    try await LegacyMigrationChecks.partialMigrationIsNeverReady()
    try await LegacyMigrationChecks.conflictingIdentityIsRefused()
    try await LegacyMigrationChecks.resumeNeverReordersTheList()
}
