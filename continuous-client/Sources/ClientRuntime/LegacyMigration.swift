import Foundation
import CryptoKit
import Darwin
import MeetingCopilotCore
import IncrementalArchive
import ClientIncrementalBridge
import SpeechCore

// Read-only migration of a legacy `sessions.json` into the incremental store.
//
// Hard rules this file exists to enforce:
//  * the legacy file is opened and hashed, never written, renamed or removed; readiness is only claimed after
//    the same bytes, mtime and inode are re-read (SHA alone cannot tell "unchanged" from "rewritten");
//  * every migrated session is verified durable against the acknowledged projection before readiness;
//  * data the typed contract cannot express is reported item by item ("未迁移该项"), never silently dropped,
//    and an interrupted/partial migration never becomes ready;
//  * a legacy journal wire is migrated with the sequence it already carries - nothing is re-allocated here.

// MARK: - physical identity of the legacy file

/// SHA256 plus mtime and inode. The three together are what makes "never touched" distinguishable from
/// "bytes identical but the file was rewritten".
public struct LegacyFileFingerprint: Equatable, Codable, Sendable {
    public let path: String, sha256: String, size: Int
    public let modifiedNanoseconds: Int64, inode: UInt64
    public static func capture(_ url: URL) throws -> LegacyFileFingerprint {
        var info = Darwin.stat()
        // `Darwin.stat` as a bare call resolves to the zero-argument initializer of the struct, so the POSIX
        // entry point is reached through `fstatat` with an explicit path and no symlink following.
        guard Darwin.fstatat(AT_FDCWD, url.path, &info, 0) == 0 else { throw LegacyMigrationFailure.unreadableLegacyFile(url.path) }
        let data = try Data(contentsOf: url)
        return LegacyFileFingerprint(path: url.path,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            size: Int(info.st_size),
            modifiedNanoseconds: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec),
            inode: UInt64(info.st_ino))
    }
    public var summary: String {
        "sha256 \(sha256.prefix(16))… · \(size) 字节 · mtime \(modifiedNanoseconds)ns · inode \(inode)"
    }
}

public enum LegacyMigrationFailure: Error, LocalizedError, Equatable {
    case unreadableLegacyFile(String)
    case submissionRefused(session: String, reason: String)
    case verificationFailed([String])
    case legacyFileChanged(before: LegacyFileFingerprint, after: LegacyFileFingerprint)
    public var errorDescription: String? {
        switch self {
        case .unreadableLegacyFile(let path): return "旧档无法读取/取证：\(path)"
        case .submissionRefused(let session, let reason): return "迁移提交被拒（\(session)）：\(reason)"
        case .verificationFailed(let failures):
            return "迁移后回读校验未通过（未置就绪）：" + failures.prefix(4).joined(separator: "；")
        case .legacyFileChanged(let before, let after):
            return "迁移前后原档指纹不一致（原档 \(before.summary) / 现在 \(after.summary)）"
        }
    }
}

// MARK: - report

/// Item-by-item account of what a migration did. `notMigrated` is the explicit "未迁移该项" record: the item
/// stays in the untouched original and is named here instead of disappearing.
public struct LegacyMigrationReport: Equatable, Sendable {
    public enum Disposition: Equatable, Sendable {
        case notMigrated(String)
        case reconciled(String)
    }
    public struct Entry: Equatable, Sendable {
        public let sessionID: String, item: String, identity: String
        public let disposition: Disposition
    }
    public var entries: [Entry] = []
    public var alreadyMigratedSessions: [String] = []
    public var migratedSessions: [String] = []
    public var migratedBatches = 0
    public var notMigratedCount: Int {
        entries.filter { if case .notMigrated = $0.disposition { return true }; return false }.count
    }
    public func notMigrated(item: String, identity: String) -> Entry? {
        entries.first { entry in
            entry.item == item && entry.identity == identity && {
                if case .notMigrated = entry.disposition { return true }
                return false
            }()
        }
    }
    public var summary: String {
        var parts = ["已迁移会话 \(migratedSessions.count) 个", "未迁移项 \(notMigratedCount) 个", "对账项 \(entries.count - notMigratedCount) 个"]
        if !alreadyMigratedSessions.isEmpty { parts.append("本次为只读校验 · 已迁移会话 \(alreadyMigratedSessions.count) 个") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - expectation (what a migrated store must be able to reproduce)

/// The migratable subset of one legacy session. Verification only ever checks this subset, so an item the
/// typed contract cannot express is reported instead of making the whole session look broken.
public struct LegacySessionExpectation: Equatable, Sendable {
    public struct Note: Equatable, Sendable { public let revision: Int, text: String, savedAtReferenceBits: UInt64 }
    public struct Revision: Equatable, Sendable {
        public let revision: Int, text: String, status: String, startNS: String, endNS: String
    }
    public struct Translation: Equatable, Sendable {
        public let id: String, revision: Int, sourceRevision: Int, sourceText: String, targetLanguage: String, text: String
    }
    public struct Segment: Equatable, Sendable {
        public let id: String, sourceLanguage: String?
        public let revisions: [Revision], translations: [Translation]
    }
    public let title: String, createdAtReferenceBits: UInt64, isDemo: Bool, tags: [String]
    public var notes: [Note] = []
    public var segments: [Segment] = []
    public var materials: [LocalMaterial] = []
    public var tombstone: LocalTombstone?
    public init(title: String, createdAtReferenceBits: UInt64, isDemo: Bool, tags: [String],
                notes: [Note] = [], segments: [Segment] = [], materials: [LocalMaterial] = [],
                tombstone: LocalTombstone? = nil) {
        self.title = title; self.createdAtReferenceBits = createdAtReferenceBits; self.isDemo = isDemo
        self.tags = tags; self.notes = notes; self.segments = segments; self.materials = materials
        self.tombstone = tombstone
    }
}

public struct LegacyMigrationPlan: Equatable, Sendable {
    public struct Batch: Equatable, Sendable {
        public let session: String
        public let deltas: [ArchiveDelta]
    }
    public var batches: [Batch] = []
    public var expectations: [String: LegacySessionExpectation] = [:]
    public var expectedOrder: [String] = []
    public var report = LegacyMigrationReport()
    /// Non-nil means no migration may run at all (a session's own bootstrap is not expressible). The report is
    /// still populated so the caller can show exactly why.
    public var fatal: String?
}

public enum LegacyMigrationOutcome {
    case fresh(LegacyMigrationPlan)
    /// Some legacy sessions are already fully migrated. Only the missing ones are submitted; the present ones
    /// are read-only verified, so a retry after an interruption never bootstraps a session twice.
    case resume(LegacyMigrationPlan, missing: [String])
    case alreadyMigrated(LegacyMigrationPlan)
    case refused(reason: String, plan: LegacyMigrationPlan?)
}

// MARK: - planner (pure; no IO, no store state)

public enum LegacyMigrationPlanner {
    public static func plan(_ archive: LocalArchive, coreLimits: CoreLimits,
                            archiveLimits: ArchiveLimits = ArchiveLimits()) -> LegacyMigrationPlan {
        var plan = LegacyMigrationPlan()
        // BridgeProjection inserts every new bootstrap at index 0, so replaying the legacy array in reverse is
        // what preserves the visible session order after a reopen.
        for session in archive.sessions.reversed() {
            plan.expectedOrder.append(session.id)
            planSession(session, plan: &plan, coreLimits: coreLimits, archiveLimits: archiveLimits)
        }
        plan.expectedOrder.reverse()   // report in the legacy file's own order
        return plan
    }

    private static func note(_ plan: inout LegacyMigrationPlan, session: String, item: String, identity: String, reason: String) {
        plan.report.entries.append(.init(sessionID: session, item: item, identity: identity, disposition: .notMigrated(reason)))
    }
    private static func reconcile(_ plan: inout LegacyMigrationPlan, session: String, item: String, identity: String, reason: String) {
        plan.report.entries.append(.init(sessionID: session, item: item, identity: identity, disposition: .reconciled(reason)))
    }
    private static func expressible(_ fence: ArchiveFence, _ deltas: [ArchiveDelta], _ limits: ArchiveLimits) -> Bool {
        guard !deltas.isEmpty else { return true }
        return (try? limits.reservation(ArchiveSubmission(expectedHead: 0, fence: fence, deltas: deltas))) != nil
    }
    /// Accumulates deltas into one commit while the commit stays expressible; flushes when it would not.
    private struct Grouper {
        var pending: [ArchiveDelta] = []
        mutating func add(_ delta: ArchiveDelta, fence: ArchiveFence, limits: ArchiveLimits, into plan: inout LegacyMigrationPlan, session: String) {
            if !pending.isEmpty, !LegacyMigrationPlanner.expressible(fence, pending + [delta], limits) {
                plan.batches.append(.init(session: session, deltas: pending)); pending = []
            }
            pending.append(delta)
        }
        mutating func flush(into plan: inout LegacyMigrationPlan, session: String) {
            guard !pending.isEmpty else { return }
            plan.batches.append(.init(session: session, deltas: pending)); pending = []
        }
    }

    private static func planSession(_ session: LocalSession, plan: inout LegacyMigrationPlan,
                                    coreLimits: CoreLimits, archiveLimits: ArchiveLimits) {
        let id = session.id
        let fence = ArchiveFence(sessionID: id)
        let bits = session.createdAt.timeIntervalSinceReferenceDate.bitPattern

        // 1. typed bootstrap. Tags and the initial note are downgraded (and reported) rather than losing the
        //    whole session when a single field cannot be expressed.
        var tags = session.tags
        var initialNotes = session.noteHistory.isEmpty ? session.notes : ""
        var bootstrap = ArchiveSessionBootstrap(title: session.title, createdAtReferenceBits: bits, isDemo: session.isDemo,
                                                initialNotes: initialNotes, tags: tags)
        if !expressible(fence, [.sessionBootstrap(bootstrap)], archiveLimits) {
            if !tags.isEmpty {
                tags = []; bootstrap = ArchiveSessionBootstrap(title: session.title, createdAtReferenceBits: bits, isDemo: session.isDemo,
                                                               initialNotes: initialNotes, tags: tags)
                note(&plan, session: id, item: "tags", identity: "bootstrap", reason: "TAGS_NOT_EXPRESSIBLE")
            }
            if !expressible(fence, [.sessionBootstrap(bootstrap)], archiveLimits), !initialNotes.isEmpty {
                initialNotes = ""
                bootstrap = ArchiveSessionBootstrap(title: session.title, createdAtReferenceBits: bits, isDemo: session.isDemo,
                                                    initialNotes: initialNotes, tags: tags)
                note(&plan, session: id, item: "notes", identity: "initial", reason: "INITIAL_NOTES_NOT_EXPRESSIBLE")
            }
            if !expressible(fence, [.sessionBootstrap(bootstrap)], archiveLimits) {
                plan.fatal = "会话 \(id) 的 typed bootstrap 无法表达（标题/日期/标签超出记录上限），未迁移任何内容"
                return
            }
        }
        plan.batches.append(.init(session: id, deltas: [.sessionBootstrap(bootstrap)]))
        var expectation = LegacySessionExpectation(title: session.title, createdAtReferenceBits: bits, isDemo: session.isDemo, tags: tags)
        if !session.noteHistory.isEmpty, session.notes != session.noteHistory.last?.text {
            note(&plan, session: id, item: "notes", identity: "current", reason: "LEGACY_NOTES_DIVERGE_FROM_HISTORY")
        }

        // 2. the authoritative journal, replayed through a real reducer so a wire the contract would reject is
        //    reported and the (still contiguous) prefix is migrated instead of the whole session failing.
        var journalSegments: [String: [SpeechEvent]] = [:]
        var journalTranslations: [SpeechEvent] = []
        var wireGroup = Grouper()
        var reducer: SpeechReducer?
        do { reducer = try SpeechReducer(sessionId: id, limits: coreLimits) }
        catch { plan.fatal = "会话 \(id) 的 reducer 无法建立：\(error)"; return }
        var prefixStopped = false
        for (index, data) in session.speechJournal.enumerated() {
            if prefixStopped {
                note(&plan, session: id, item: "journal-wire", identity: "#\(index + 1)", reason: "AFTER_REJECTED_WIRE")
                continue
            }
            let event: SpeechEvent
            do { event = try SpeechEvent.decode(data) }
            catch {
                note(&plan, session: id, item: "journal-wire", identity: "#\(index + 1)", reason: "UNDECODABLE_WIRE")
                prefixStopped = true; continue
            }
            guard event.sessionId == id else {
                note(&plan, session: id, item: "journal-wire", identity: "#\(index + 1)", reason: "WIRE_BELONGS_TO_\(event.sessionId)")
                prefixStopped = true; continue
            }
            guard let applied = reducer?.receive(data, nowMs: 0), case .applied = applied else {
                note(&plan, session: id, item: "journal-wire", identity: "#\(index + 1)", reason: "AUTHORITATIVE_REDUCER_REJECTED")
                prefixStopped = true; continue
            }
            let delta: ArchiveDelta
            do { delta = try speechDelta(from: data) }
            catch {
                note(&plan, session: id, item: "journal-wire", identity: "#\(index + 1)", reason: "DELTA_NOT_DERIVABLE")
                prefixStopped = true; continue
            }
            guard expressible(fence, [delta], archiveLimits) else {
                note(&plan, session: id, item: "journal-wire", identity: "#\(index + 1)", reason: "WIRE_NOT_EXPRESSIBLE")
                prefixStopped = true; continue
            }
            wireGroup.add(delta, fence: fence, limits: archiveLimits, into: &plan, session: id)
            if event.type == "asr.segment", let segmentID = event.segmentId { journalSegments[segmentID, default: []].append(event) }
            if event.type == "translation.segment" { journalTranslations.append(event) }
        }
        wireGroup.flush(into: &plan, session: id)

        // 3. presentations: a segment is only visible once its authoritative source wire exists, and the
        //    insertion index must equal the number of already recorded presentations.
        var presentations: [ArchiveDelta] = []
        var insertionIndex: UInt64 = 0
        var legacySegmentIDs: Set<String> = []
        for segment in session.segments {
            legacySegmentIDs.insert(segment.id)
            guard let events = journalSegments[segment.id], !events.isEmpty else {
                note(&plan, session: id, item: "segment", identity: segment.id, reason: "NO_AUTHORITATIVE_SOURCE_WIRE")
                for translation in segment.translations {
                    note(&plan, session: id, item: "translation", identity: "\(segment.id)/\(translation.id)", reason: "SOURCE_SEGMENT_NOT_MIGRATED")
                }
                continue
            }
            let language = segment.current?.sourceLanguage
            presentations.append(.segmentPresentation(segmentID: segment.id, sourceLanguage: language, insertionIndex: insertionIndex))
            insertionIndex += 1
            // Only the revisions the journal really carries are claimed; the rest stay in the original.
            let journalRevisions = events.map { ($0.revision ?? 0, $0.text ?? "", $0.status ?? "", $0.startNs ?? "", $0.endNs ?? "") }
            var revisions: [LegacySessionExpectation.Revision] = []
            for revision in segment.revisions {
                guard let match = journalRevisions.first(where: { $0.0 == revision.revision && $0.1 == revision.text && $0.2 == revision.status
                    && $0.3 == revision.startNS && $0.4 == revision.endNS }) else {
                    note(&plan, session: id, item: "segment-revision", identity: "\(segment.id)/r\(revision.revision)", reason: "REVISION_NOT_IN_JOURNAL")
                    continue
                }
                _ = match
                revisions.append(.init(revision: revision.revision, text: revision.text, status: revision.status,
                                       startNS: revision.startNS, endNS: revision.endNS))
            }
            if revisions.count != journalRevisions.count {
                reconcile(&plan, session: id, item: "segment-revision", identity: segment.id, reason: "JOURNAL_HAS_REVISIONS_NOT_IN_LEGACY_SEGMENTS")
            }
            var translations: [LegacySessionExpectation.Translation] = []
            for translation in segment.translations {
                let match = journalTranslations.first {
                    $0.translationId == translation.id && ($0.revision ?? 0) == translation.revision
                        && ($0.segmentId ?? "") == segment.id && ($0.sourceRevision ?? 0) == translation.sourceRevision
                        && ($0.sourceText ?? "") == translation.sourceText && ($0.targetLanguage ?? "") == translation.targetLanguage
                        && ($0.translatedText ?? "") == translation.text
                }
                guard match != nil else {
                    note(&plan, session: id, item: "translation", identity: "\(segment.id)/\(translation.id)", reason: "TRANSLATION_NOT_IN_JOURNAL")
                    continue
                }
                translations.append(.init(id: translation.id, revision: translation.revision, sourceRevision: translation.sourceRevision,
                                          sourceText: translation.sourceText, targetLanguage: translation.targetLanguage, text: translation.text))
            }
            expectation.segments.append(.init(id: segment.id, sourceLanguage: language, revisions: revisions, translations: translations))
        }
        for extra in journalSegments.keys.filter({ !legacySegmentIDs.contains($0) }).sorted() {
            reconcile(&plan, session: id, item: "segment", identity: extra, reason: "PRESENT_IN_JOURNAL_ONLY")
            let events = journalSegments[extra] ?? []
            presentations.append(.segmentPresentation(segmentID: extra, sourceLanguage: nil, insertionIndex: insertionIndex))
            insertionIndex += 1
            expectation.segments.append(.init(id: extra, sourceLanguage: nil,
                revisions: events.map { .init(revision: $0.revision ?? 0, text: $0.text ?? "", status: $0.status ?? "",
                                              startNS: $0.startNs ?? "", endNS: $0.endNs ?? "") }, translations: []))
        }
        for group in stride(from: 0, to: presentations.count, by: 64).map({ Array(presentations[$0..<min($0 + 64, presentations.count)]) }) {
            plan.batches.append(.init(session: id, deltas: group))
        }

        // 4. notes: an unexpressible or out-of-order revision breaks the chain, so the following revisions are
        //    reported too instead of being silently renumbered.
        var expectedRevision = 1
        var notesGroup = Grouper()
        for noteVersion in session.noteHistory.sorted(by: { $0.revision < $1.revision }) {
            guard noteVersion.revision == expectedRevision else {
                note(&plan, session: id, item: "notes", identity: "r\(noteVersion.revision)", reason: "NOTES_REVISION_GAP")
                expectedRevision += 1
                continue
            }
            let delta = ArchiveDelta.notesVersion(revision: UInt64(noteVersion.revision), text: noteVersion.text,
                savedAtReferenceBits: noteVersion.savedAt.timeIntervalSinceReferenceDate.bitPattern)
            guard expressible(fence, [delta], archiveLimits) else {
                note(&plan, session: id, item: "notes", identity: "r\(noteVersion.revision)", reason: "NOTES_REVISION_NOT_EXPRESSIBLE")
                expectedRevision += 1
                continue
            }
            notesGroup.add(delta, fence: fence, limits: archiveLimits, into: &plan, session: id)
            expectation.notes.append(.init(revision: noteVersion.revision, text: noteVersion.text,
                                           savedAtReferenceBits: noteVersion.savedAt.timeIntervalSinceReferenceDate.bitPattern))
            expectedRevision += 1
        }
        notesGroup.flush(into: &plan, session: id)

        // 5. materials in ordered chunks. A material that cannot be expressed stays in the original and is named.
        for material in session.materials {
            guard material.sha256.count == 64, !material.fileName.isEmpty else {
                note(&plan, session: id, item: "material", identity: material.id, reason: "MATERIAL_IDENTITY_NOT_MIGRATABLE")
                continue
            }
            let bits = material.importedAt.timeIntervalSinceReferenceDate.bitPattern
            let chunks = IncrementalPersistence.materialChunks(id: material.id, fileName: material.fileName, text: material.text,
                                                               sha256: material.sha256, importedAtReferenceBits: bits)
            let deltas = chunks.map { chunkDelta($0) }
            guard deltas.allSatisfy({ expressible(fence, [$0], archiveLimits) }) else {
                note(&plan, session: id, item: "material", identity: material.id, reason: "MATERIAL_CHUNK_NOT_EXPRESSIBLE")
                continue
            }
            for delta in deltas { plan.batches.append(.init(session: id, deltas: [delta])) }
            expectation.materials.append(material)
        }

        // 6. logical deletion record.
        if let tombstone = session.tombstone {
            let delta = ArchiveDelta.sessionTombstone(recordID: tombstone.id,
                deletedAtReferenceBits: tombstone.deletedAt.timeIntervalSinceReferenceDate.bitPattern,
                actorKind: tombstone.actorKind, reason: tombstone.reason)
            if expressible(fence, [delta], archiveLimits) {
                plan.batches.append(.init(session: id, deltas: [delta]))
                expectation.tombstone = tombstone
            } else {
                note(&plan, session: id, item: "tombstone", identity: tombstone.id, reason: "TOMBSTONE_NOT_EXPRESSIBLE")
            }
        }

        // 7. capture state: the typed contract needs a renewed attempt fence plus an acknowledged terminal, and
        //    a legacy attempt carries no renewed generation. It is reported, never re-derived or invented.
        for attempt in session.captureAttempts {
            note(&plan, session: id, item: "capture-attempt", identity: attempt.id,
                 reason: "CAPTURE_ATTEMPT_NOT_EXPRESSIBLE_WITHOUT_RENEWED_FENCE")
        }
        plan.expectations[id] = expectation
    }

    static func chunkDelta(_ chunk: IncrementalPersistence.MaterialChunk) -> ArchiveDelta {
        .materialChunk(materialID: chunk.materialID, fileName: chunk.fileName, sha256: chunk.sha256,
                       importedAtReferenceBits: chunk.importedAtReferenceBits,
                       chunkIndex: UInt64(chunk.chunkIndex), chunkCount: UInt64(chunk.chunkCount), text: chunk.text)
    }
}

// MARK: - verifier (against the real acknowledged projection)

public enum LegacyMigrationVerifier {
    public static func failures(_ expectations: [String: LegacySessionExpectation], order: [String],
                                projection: BridgeProjection) -> [String] {
        var failures: [String] = []
        // Visible order is part of what a reopen must reproduce. A migration that landed the right sessions in
        // the wrong order is not equivalent to the original, so it is a failure, never a silent difference.
        let migrated = projection.sessionOrder.filter { expectations[$0] != nil }
        if migrated != order {
            failures.append("会话可见顺序与旧档不一致（旧档 \(order.joined(separator: ",")) / 迁移后 \(migrated.joined(separator: ","))）")
        }
        for id in order {
            guard let expectation = expectations[id] else { continue }
            guard let session = projection.sessions[id] else { failures.append("会话 \(id) 不在增量存档中"); continue }
            guard let bootstrap = session.bootstrap else { failures.append("会话 \(id) 缺 typed bootstrap"); continue }
            if bootstrap.title != expectation.title { failures.append("会话 \(id) 标题不一致") }
            if bootstrap.isDemo != expectation.isDemo { failures.append("会话 \(id) 演示标记不一致") }
            if bootstrap.createdAtReferenceBits != expectation.createdAtReferenceBits { failures.append("会话 \(id) 创建时间位不一致") }
            if bootstrap.tags != expectation.tags { failures.append("会话 \(id) 标签不一致") }
            for note in expectation.notes {
                guard let actual = session.notes.first(where: { $0.revision == UInt64(note.revision) }) else {
                    failures.append("会话 \(id) 缺随记 r\(note.revision)"); continue
                }
                if actual.text != note.text { failures.append("会话 \(id) 随记 r\(note.revision) 文本不一致") }
                if actual.savedAtReferenceBits != note.savedAtReferenceBits { failures.append("会话 \(id) 随记 r\(note.revision) 时间不一致") }
            }
            for segment in expectation.segments {
                guard let presentation = session.presentations[segment.id] else {
                    failures.append("会话 \(id) 段 \(segment.id) 缺插入记录"); continue
                }
                if presentation.sourceLanguage != segment.sourceLanguage { failures.append("会话 \(id) 段 \(segment.id) 源语言不一致") }
                let events = session.core.segments[segment.id] ?? []
                for revision in segment.revisions {
                    let found = events.contains {
                        ($0.revision ?? -1) == revision.revision && ($0.text ?? "") == revision.text && ($0.status ?? "") == revision.status
                            && ($0.startNs ?? "") == revision.startNS && ($0.endNs ?? "") == revision.endNS
                    }
                    if !found { failures.append("会话 \(id) 段 \(segment.id) 缺原文 r\(revision.revision)") }
                }
                for translation in segment.translations {
                    let found = (session.core.translations[translation.id] ?? []).contains {
                        ($0.revision ?? -1) == translation.revision && ($0.segmentId ?? "") == segment.id
                            && ($0.sourceRevision ?? -1) == translation.sourceRevision && ($0.sourceText ?? "") == translation.sourceText
                            && ($0.targetLanguage ?? "") == translation.targetLanguage && ($0.translatedText ?? "") == translation.text
                    }
                    if !found { failures.append("会话 \(id) 段 \(segment.id) 缺译文 \(translation.id) r\(translation.revision)") }
                }
            }
            for material in expectation.materials {
                guard let actual = session.materials[material.id], actual.complete else {
                    failures.append("会话 \(id) 资料 \(material.id) 未完整落盘"); continue
                }
                if actual.sha256 != material.sha256 || actual.fileName != material.fileName { failures.append("会话 \(id) 资料 \(material.id) 身份不一致") }
                if actual.text != material.text { failures.append("会话 \(id) 资料 \(material.id) 文本不一致") }
                if actual.importedAtReferenceBits != material.importedAt.timeIntervalSinceReferenceDate.bitPattern {
                    failures.append("会话 \(id) 资料 \(material.id) 导入时间不一致")
                }
            }
            if let tombstone = expectation.tombstone {
                guard let actual = session.tombstone else { failures.append("会话 \(id) 缺删除记录"); continue }
                if actual.recordID != tombstone.id || actual.actorKind != tombstone.actorKind || actual.reason != tombstone.reason
                    || actual.deletedAtReferenceBits != tombstone.deletedAt.timeIntervalSinceReferenceDate.bitPattern {
                    failures.append("会话 \(id) 删除记录不一致")
                }
            }
        }
        return failures
    }
}

// MARK: - MainActor orchestration

struct LegacyMigrationSetup {
    let outcome: LegacyMigrationOutcome
    let before: LegacyFileFingerprint
    let legacyURL: URL
    var plan: LegacyMigrationPlan? {
        switch outcome {
        case .fresh(let value), .alreadyMigrated(let value), .resume(let value, _): return value
        case .refused(_, let value): return value
        }
    }
    var isFresh: Bool { if case .fresh = outcome { return true }; return false }
    var isResume: Bool { if case .resume = outcome { return true }; return false }
    var isAlreadyMigrated: Bool { if case .alreadyMigrated = outcome { return true }; return false }
    /// True when at least one session still needs real submissions (a fresh store, or a resumed one).
    var needsSubmission: Bool { isFresh || isResume }
    /// Sessions already durable and verified, so they must not be submitted again.
    var alreadyDurable: [String] {
        switch outcome {
        case .alreadyMigrated(let plan): return plan.expectedOrder
        case .resume(let plan, let missing):
            let missingSet = Set(missing)
            return plan.expectedOrder.filter { !missingSet.contains($0) }
        default: return []
        }
    }
    var refusal: String? { if case .refused(let reason, _) = outcome { return reason }; return nil }
}

@MainActor extension ClientModel {
    /// Read-only pre-flight: hash the legacy file, plan the migration, classify what the incremental store
    /// already holds. Never writes, renames or removes anything.
    func incrementalLegacySetup(legacyURL: URL, limits: CoreLimits) async -> LegacyMigrationSetup {
        let directory = legacyURL.deletingLastPathComponent()
        var before: LegacyFileFingerprint
        do { before = try await Task.detached { try LegacyFileFingerprint.capture(legacyURL) }.value }
        catch { return LegacyMigrationSetup(outcome: .refused(reason: "旧档取证失败：\(error)", plan: nil), before: LegacyFileFingerprint(path: legacyURL.path, sha256: "", size: 0, modifiedNanoseconds: 0, inode: 0), legacyURL: legacyURL) }
        let archive: LocalArchive
        do { archive = try await Task.detached { try ArchiveStore(directory: directory).load() }.value }
        catch { return LegacyMigrationSetup(outcome: .refused(reason: "旧档无法解析：\(error)", plan: nil), before: before, legacyURL: legacyURL) }
        let plan = await Task.detached { LegacyMigrationPlanner.plan(archive, coreLimits: limits) }.value
        if let fatal = plan.fatal {
            return LegacyMigrationSetup(outcome: .refused(reason: fatal, plan: plan), before: before, legacyURL: legacyURL)
        }
        do {
            let recovery = try await IncrementalArchiveWriter.inspect(directory: incrementalDataDirectory)
            let projection = try await Task.detached {
                var value = BridgeProjection(limits: limits)
                for record in recovery.records { try value.apply(record.submission) }
                return value
            }.value
            if recovery.records.isEmpty {
                return LegacyMigrationSetup(outcome: .fresh(plan), before: before, legacyURL: legacyURL)
            }
            var absent: [String] = [], conflicting: [String] = [], incomplete: [String] = []
            for id in plan.expectedOrder {
                guard let expectation = plan.expectations[id] else { continue }
                guard let session = projection.sessions[id], let bootstrap = session.bootstrap else { absent.append(id); continue }
                let sameIdentity = bootstrap.title == expectation.title && bootstrap.isDemo == expectation.isDemo
                    && bootstrap.createdAtReferenceBits == expectation.createdAtReferenceBits && bootstrap.tags == expectation.tags
                guard sameIdentity else { conflicting.append(id); continue }
                let failures = LegacyMigrationVerifier.failures([id: expectation], order: [id], projection: projection)
                if failures.isEmpty { continue }
                // The session exists with the right identity but its content is not all durable: a migration was
                // interrupted INSIDE this session. Continuing would mean re-deciding per-delta idempotence, which
                // this path does not claim to do, so it stays an explicit not-ready state instead of a guess.
                incomplete.append(id)
            }
            if !conflicting.isEmpty {
                return LegacyMigrationSetup(outcome: .refused(reason: "增量存档已有同 id 但身份不同的会话 \(conflicting.joined(separator: ", "))；拒绝自动覆盖", plan: plan), before: before, legacyURL: legacyURL)
            }
            if !incomplete.isEmpty {
                return LegacyMigrationSetup(outcome: .refused(reason: "增量存档只在会话 \(incomplete.joined(separator: ", ")) 内完成了部分旧档迁移（内容不完整）；未置就绪（部分迁移不得置 ready），原档未改动", plan: plan), before: before, legacyURL: legacyURL)
            }
            if absent.isEmpty {
                return LegacyMigrationSetup(outcome: .alreadyMigrated(plan), before: before, legacyURL: legacyURL)
            }
            // Some whole sessions are already migrated and verified, others never started: a retry after an
            // interruption only submits the missing ones. Nothing already durable is ever bootstrapped twice.
            if absent.count < plan.expectedOrder.count {
                return LegacyMigrationSetup(outcome: .resume(plan, missing: absent), before: before, legacyURL: legacyURL)
            }
            return LegacyMigrationSetup(outcome: .fresh(plan), before: before, legacyURL: legacyURL)
        } catch {
            return LegacyMigrationSetup(outcome: .refused(reason: "增量存档无法读取：\(error)", plan: plan), before: before, legacyURL: legacyURL)
        }
    }

    /// Submits the plan in order, waits for the real durability barrier, re-reads the legacy file, and verifies
    /// every migrated item against the acknowledged projection. Any refusal or mismatch throws.
    /// `skipping` names sessions that are already durable and verified: their batches are never submitted again,
    /// so a retry after an interruption cannot double-bootstrap or replay a conflicting revision.
    func incrementalRunLegacyMigration(_ setup: LegacyMigrationSetup, plan: LegacyMigrationPlan,
                                       persistence: IncrementalPersistence,
                                       skipping: [String] = []) async throws -> LegacyMigrationReport {
        var report = plan.report
        report.alreadyMigratedSessions = skipping
        let skip = Set(skipping)
        var index = 0
        for batch in plan.batches where !skip.contains(batch.session) {
            index += 1
            let key = "migration:\(batch.session):\(index)"
            let fence = ArchiveFence(sessionID: batch.session)
            var admitted = persistence.enqueueDelta(key: key, fence: fence, attempt: nil, deltas: batch.deltas)
            if !admitted {
                _ = try? await persistence.awaitQuiescence()
                admitted = persistence.enqueueDelta(key: key, fence: fence, attempt: nil, deltas: batch.deltas)
            }
            guard admitted else {
                throw LegacyMigrationFailure.submissionRefused(session: batch.session,
                    reason: persistence.lastFailure ?? "未知原因")
            }
            report.migratedBatches += 1
            if persistence.retainedAdmissionCount >= 16 || persistence.reservedLedgerBytes >= 4 * 1024 * 1024 {
                _ = try await persistence.awaitQuiescence()
            }
        }
        _ = try await persistence.awaitQuiescence()
        persistence.resyncOwnershipFromProjection()
        guard let projection = persistence.projection else {
            throw LegacyMigrationFailure.verificationFailed(["增量投影不可用"])
        }
        let failures = LegacyMigrationVerifier.failures(plan.expectations, order: plan.expectedOrder, projection: projection)
        guard failures.isEmpty else { throw LegacyMigrationFailure.verificationFailed(failures) }
        try verifyLegacyFileUnchanged(setup)
        report.migratedSessions = plan.expectedOrder
        if persistence.lastFailure != nil { _ = persistence.resolveCallerRejections() }
        return report
    }

    /// Confirms the legacy file was not rewritten during the migration: identical bytes, mtime and inode.
    func verifyLegacyFileUnchanged(_ setup: LegacyMigrationSetup) throws {
        let after = try LegacyFileFingerprint.capture(setup.legacyURL)
        guard after == setup.before else {
            throw LegacyMigrationFailure.legacyFileChanged(before: setup.before, after: after)
        }
    }

    func legacyMigrationStatusText(_ report: LegacyMigrationReport, alreadyVerified: Bool) -> String {
        let prefix: String
        if alreadyVerified, report.migratedBatches == 0 { prefix = "旧档已迁移 · 本次只读校验 · " }
        else if alreadyVerified { prefix = "旧档迁移续做完成 · 先前已迁移会话只读校验 · " }
        else { prefix = "旧档只读迁移完成 · " }
        return prefix + report.summary
    }

    /// Human-readable account of what a migration still left in the untouched original. Never a summary that
    /// hides an item: each one is named with its session, identity and reason.
    func legacyNotMigratedLines(_ report: LegacyMigrationReport) -> [String] {
        report.entries.compactMap { entry in
            guard case .notMigrated(let reason) = entry.disposition else { return nil }
            return "\(entry.sessionID) · \(entry.item) · \(entry.identity) · \(reason)"
        }
    }
}
