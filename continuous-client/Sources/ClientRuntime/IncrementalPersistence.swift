import Foundation
import CryptoKit
import MeetingCopilotCore
import IncrementalArchive
import ClientIncrementalBridge
import SpeechCore
import RotatingSpeechSession

// Explicit incremental-persistence wiring for ClientModel.
// MainActor owns the dirty ledger and user-visible status only. Wire encoding, validation and IO run on the
// bridge admission queue / writer queue. This is not a drop-in ArchiveStore replacement and it never migrates
// a legacy file. Callers keep their own dirty ledger: a revision is "saved" only after its own ack.
@MainActor public final class IncrementalPersistence: ObservableObject {
    public enum Status: Equatable {
        case opening, ready
        case saving(unconfirmed: Int)
        case saved(head: UInt64)
        case blocked(reason: String, unconfirmed: Int)
        case closing(unconfirmed: Int)
        case closed
        case unavailable(reason: String)
    }
    public struct Dirty: Equatable {
        public let id: UUID, key: String, keyGeneration: Int
        public let fence: ArchiveFence, attempt: String?
        public var admitted: Bool, failure: String?
    }
    /// One ordered text chunk of a material. Chunking is by UTF-8 byte budget so a chunk never splits a
    /// scalar; the identity plus `chunkIndex/chunkCount` is what makes the file reconstructible.
    public struct MaterialChunk: Equatable, Sendable {
        public let materialID: String, fileName: String, sha256: String, importedAtReferenceBits: UInt64
        public let chunkIndex: Int, chunkCount: Int, text: String
    }
    /// Splits `text` into UTF-8-bounded chunks without ever cutting a scalar. `chunkCount` is decided here and
    /// travels with every chunk, so a reader can tell an incomplete material from a complete one.
    /// Pure function: no store state, callable from any context.
    public nonisolated static func materialChunks(id: String, fileName: String, text: String, sha256: String,
                                      importedAtReferenceBits: UInt64, maximumChunkBytes: Int = 12_000) -> [MaterialChunk] {
        precondition(maximumChunkBytes > 0)
        var pieces: [String] = []
        var current = ""
        var currentBytes = 0
        for character in text {
            let size = String(character).utf8.count
            if currentBytes > 0, currentBytes + size > maximumChunkBytes {
                pieces.append(current); current = ""; currentBytes = 0
            }
            current.append(character); currentBytes += size
        }
        // A material is always at least one chunk, even when its text is empty: chunkCount 1 is the identity
        // record, never zero chunks (zero would be indistinguishable from "never submitted").
        if !current.isEmpty || pieces.isEmpty { pieces.append(current) }
        return pieces.enumerated().map { index, piece in
            MaterialChunk(materialID: id, fileName: fileName, sha256: sha256, importedAtReferenceBits: importedAtReferenceBits,
                          chunkIndex: index, chunkCount: pieces.count, text: piece)
        }
    }
    private struct Barrier {
        let attempt: String, fence: ArchiveFence, requiresCoverage: Bool
        var coverageAcked: Bool, completedSubmitted: Bool
    }
    /// Caller-held content that is still not durable, plus unresolved caller-side failures.
    /// This is a caller report, not a durability proof: only the ledger ack/fsync is that.
    public struct CallerPending: Equatable, Sendable {
        public struct Session: Equatable, Sendable {
            public var notesVersions = 0, journalWires = 0, captureStates = 0, presentations = 0, metadataVersions = 0, tombstones = 0, materials = 0
            public var total: Int { notesVersions + journalWires + captureStates + presentations + metadataVersions + tombstones + materials }
            public init() {}
        }
        public var sessions: [String: Session] = [:]
        public var unresolvedFailure: String?
        public var activeTranslations = 0
        /// Cancelled-but-not-yet-ended translation bodies. Reported for honesty; they never block a close
        /// because their output can no longer be accepted.
        public var cancelledTranslations = 0
        public var capturePending = false
        /// Sessions the caller holds that have no durable opening record at all (their sessionOpened/bootstrap
        /// is still only in memory). Counted separately from per-revision pending.
        public var unopenedSessions = 0
        public init() {}
        public var total: Int { sessions.values.reduce(0) { $0 + $1.total } + activeTranslations + (capturePending ? 1 : 0) + unopenedSessions }
        public var isClean: Bool { total == 0 && unresolvedFailure == nil }
        public var reason: String? {
            var parts: [String] = []
            if total > 0 {
                let detail = sessions.sorted { $0.key < $1.key }.map { "\($0.key)[notes \($0.value.notesVersions), wire \($0.value.journalWires), capture \($0.value.captureStates), text \($0.value.presentations), title/tags \($0.value.metadataVersions), deletions \($0.value.tombstones), materials \($0.value.materials)]" }
                parts.append("caller 仍有未提交内容 \(total) 项: " + detail.joined(separator: "; "))
                if unopenedSessions > 0 { parts.append("\(unopenedSessions) 个会话尚无已持久化的开档记录") }
                if activeTranslations > 0 { parts.append("在途翻译任务 \(activeTranslations) 个") }
                if capturePending { parts.append("采集终态未确认") }
            } else if activeTranslations > 0 { parts.append("在途翻译任务 \(activeTranslations) 个") }
            else if capturePending { parts.append("采集终态未确认") }
            if cancelledTranslations > 0 { parts.append("已取消但尚未结束的翻译任务 \(cancelledTranslations) 个（结果不再被采纳）") }
            if let unresolvedFailure { parts.append("未解决失败: \(unresolvedFailure)") }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }
    public let directory: URL
    @Published public private(set) var status: Status = .opening
    @Published public private(set) var lastConfirmedHead: UInt64 = 0
    @Published public private(set) var lastFailure: String?
    public private(set) var recoveredUnfinishedAttempts: [ArchiveFence] = []
    public private(set) var projection: BridgeProjection?
    public var onAcknowledged: (@MainActor (UInt64) -> Void)?
    public var onAttemptTerminalCommitted: (@MainActor (String) -> Void)?
    public var onFailure: (@MainActor (String) -> Void)?
    public var onAvailabilityChanged: (@MainActor (Bool) -> Void)?
    /// Caller-side readiness: what the owner of the in-memory model still holds back. Set by ClientModel.
    /// It is a report (counts + unresolved failure), never a durability proof.
    public var callerPendingProvider: (@MainActor () -> CallerPending)?
    /// Caller-side drain run BEFORE the closing gate: re-submits every session's held-back notes/journal/
    /// capture/presentation so an accepted, budget-free store can really reach zero. Bounded and synchronous
    /// with respect to the ledger: it only enqueues; acks still arrive through the normal ledger.
    public var callerDrainForClose: (@MainActor () async -> Void)?

    private var bridge: ClientArchiveBridge?
    private var ledger: [UUID: Dirty] = [:]
    private var deltas: [UUID: [ArchiveDelta]] = [:]
    private var builders: [UUID: @Sendable () throws -> [ArchiveDelta]] = [:]
    private var ledgerReservations: [UUID: Int] = [:]
    private var ledgerBytes = 0
    private var ackHooks: [UUID: @MainActor () -> Void] = [:]
    private var order: [UUID] = []
    /// In-flight admission handoffs. A durability barrier must await these before flushing the writer,
    /// otherwise a revision still queued for validation would be missed by the barrier.
    private var admissionTasks: [UUID: Task<Void, Never>] = [:]
    /// Serial admission chain: each handoff awaits the previous one so storage order matches ledger order.
    private var admissionChain: Task<Void, Never>?
    private var keyGeneration: [String: Int] = [:]
    private var nextGeneration = 0
    private var barriers: [String: Barrier] = [:]
    private var acceptedFences: [String: ArchiveFence] = [:]
    private var failedAttempts: Set<String> = []
    private var rawTerminalAttempts: Set<String> = []
    private var coveredAttempts: Set<String> = []
    /// Attempts whose acknowledged completed/cancelled/incomplete record already retired the barrier. A late raw
    /// terminal or capture-failure callback for such an attempt is a real no-op, never a new blocking failure:
    /// after success the controller can still deliver one more callback, and it must not poison the close gate.
    /// Bounded (oldest retired attempt is forgotten first) so a long session cannot grow it without limit.
    private var retiredAttempts: Set<String> = []
    private var retiredOrder: [String] = []
    private func retire(attempt: String) {
        guard retiredAttempts.insert(attempt).inserted else { return }
        retiredOrder.append(attempt)
        while retiredOrder.count > 256 { retiredAttempts.remove(retiredOrder.removeFirst()) }
    }
    private var completionProjectionDeltas: [String: [ArchiveDelta]] = [:]
    private var terminalOutcomes: [String: ArchiveAttemptOutcome] = [:]
    func setTerminalOutcome(attempt: String, outcome: ArchiveAttemptOutcome) { terminalOutcomes[attempt] = outcome }
    func setCompletionProjection(attempt: String, deltas: [ArchiveDelta]) { completionProjectionDeltas[attempt] = deltas }
    private var metadataRevision: [String: UInt64] = [:]
    /// Sessions whose real sessionOpened record was already submitted; a session is opened exactly once.
    private var openedSessions: Set<String> = []
    /// Sessions whose tombstone record was already handed to the ledger (dedupe before the ack lands).
    private var submittedTombstones: Set<String> = []
    /// Authoritative journal wires still not handed to the writer, per session. Completion must wait for zero.
    private var journalBacklog: [String: Int] = [:]
    private var closing = false
    /// Explicit caller-reported local inconsistency. Never set by a writer call, never auto-cleared by a drain.
    private var callerReportedFailure: String?
    /// A store that really closed stays closed: no new admission, and no later status refresh can turn it into
    /// `.saving`/`.closing` again just because a late acknowledgement callback arrived.
    /// Terminal closed state. Read-only for callers so a UI can distinguish a failed close from a finished one
    /// without being able to set the flag itself.
    public private(set) var isClosed = false
    private let limits: CoreLimits
    private let budget: BridgeLimits
    private let fault: (@Sendable (ArchiveFaultPoint) throws -> Void)?

    public init(directory: URL, limits: CoreLimits, budget: BridgeLimits = BridgeLimits(),
                fault: (@Sendable (ArchiveFaultPoint) throws -> Void)? = nil) {
        self.directory = directory; self.limits = limits; self.budget = budget; self.fault = fault
    }
    public func start() async {
        guard bridge == nil else { return }
        do {
            let opened = try await ClientArchiveBridge.open(directory: directory, limits: limits, budget: budget, fault: fault)
            let recovery = try await IncrementalArchiveWriter.inspect(directory: directory)
            // A recovered completed intent is not proof that the previous process reached fsync/ack.
            // Establish a real durability barrier in this process before exposing any restored lifecycle.
            _ = try await opened.flush(durability: .fsync)
            bridge = opened
            recoveredUnfinishedAttempts = recovery.unfinishedAttempts
            projection = opened.state.acknowledgedProjection
            lastConfirmedHead = opened.writer.status.confirmedHead
            resyncOwnershipFromProjection()
            // Unfinished attempts are exposed as interrupted recovery state only. No terminal barrier is
            // re-armed on open: a previous process's coverage does not establish a new raw terminal.
            status = .ready; onAvailabilityChanged?(true)
        } catch {
            let reason = String(describing: error)
            status = .unavailable(reason: reason); lastFailure = reason
            onFailure?(reason); onAvailabilityChanged?(false)
        }
    }
    /// Re-derives the writer-side ownership caches from the acknowledged projection. Used by `start()` and after
    /// a legacy migration, so a re-run never opens a session a second time or restarts metadata/notes counters.
    func resyncOwnershipFromProjection() {
        guard let projection else { return }
        for (id, session) in projection.sessions {
            openedSessions.insert(id)
            metadataRevision[id] = session.metadataRevision
            if session.tombstone != nil { submittedTombstones.insert(id) }
            for materialID in session.materialOrder {
                if let material = session.materials[materialID] {
                    submittedMaterialChunks["\(id):\(materialID)"] = Set(0..<Int(material.receivedChunks))
                }
            }
        }
    }
    public var isAvailable: Bool { if case .unavailable = status { return false }; return true }
    public var unconfirmedRevisionCount: Int { ledger.count }
    public var hasUnconfirmedWork: Bool { !ledger.isEmpty }
    public var canSubmit: Bool { bridge != nil && !closing && !isClosed }
    /// True only while a close is genuinely in progress. After a successful close the store is closed, not
    /// "closing", so a caller can tell a failed close from a finished one.
    public var isClosing: Bool { closing }
    public var retainedAdmissionCount: Int { admissionTasks.count }
    public var reservedLedgerBytes: Int { ledgerBytes }
    /// Capture attempts that began but never reached an acknowledged terminal record. A store with open
    /// attempts is NOT closed-able: `close()` refuses so a caller cannot exit on an unretired capture.
    public var openAttemptCount: Int { barriers.count }
    /// Sessions whose authoritative journal wires the caller still holds back (never handed to the writer).
    public var sessionsWithHeldJournal: Int { journalBacklog.values.filter { $0 > 0 }.count }
    /// A failure that genuinely means "nothing durable happened": caller content rejected before the ledger,
    /// an admitted revision whose write failed, or an explicit caller-reported local inconsistency. A transient
    /// capture failure is not one of these: it is resolved by the real terminal record and cleared by its own ack.
    public var blockingFailure: String? {
        if let failure = ledger.values.compactMap(\.failure).sorted().first { return failure }
        if let reported = callerReportedFailure { return reported }
        guard let last = lastFailure else { return nil }
        return last.hasPrefix("CAPTURE_FAILED[") ? nil : last
    }
    public var isCleanForTermination: Bool {
        !closing && ledger.isEmpty && admissionTasks.isEmpty && barriers.isEmpty
            && journalBacklog.values.allSatisfy { $0 == 0 } && blockingFailure == nil
    }
    /// The subset of `blockingFailure` that means admitted/attempted work did NOT become durable: a failed write,
    /// an admission rejection, or an explicit caller report. A pure caller-side rejection (budget full, input too
    /// large, gate closed) is excluded: the caller still holds that content, so making every ordinary
    /// `awaitQuiescence` throw would turn a normal editing state into a false failure. It stays visible through
    /// `blockingFailure` and `callerPendingProvider`, and `close()` still refuses on the full `blockingFailure`.
    public var durableFailure: String? {
        if let failure = ledger.values.compactMap(\.failure).sorted().first { return failure }
        if let reported = callerReportedFailure { return reported }
        guard let last = lastFailure, !last.hasPrefix("CAPTURE_FAILED[") else { return nil }
        return Self.isCallerSideRejection(last) ? nil : last
    }
    /// Explicit caller report for a local inconsistency that no writer call can repair (for example a rewritten
    /// capture history or source-block suffix). It is NOT a ledger entry and it is NOT auto-cleared by a drain:
    /// only `clearCallerReportedFailure()` after a real caller-side repair removes it.
    public func reportCallerFailure(reason: String) { callerReportedFailure = reason; refreshStatus() }
    public func clearCallerReportedFailure() { callerReportedFailure = nil; refreshStatus() }
    /// The caller-visible blocker, if any. Capture-side transient failures are excluded here because they are
    /// resolved by the real terminal record, not by a close gate.
    public var callerBlockingFailure: String? { blockingFailure }
    public func dirtyRevisions(session: String) -> [Dirty] {
        ledger.values.filter { $0.fence.sessionID == session }.sorted { $0.key < $1.key }
    }
    public var allDirtyRevisions: [Dirty] { ledger.values.sorted { $0.key < $1.key } }
    private func refreshStatus() {
        if case .unavailable = status { return }
        if isClosed { status = .closed; return }
        if closing { status = .closing(unconfirmed: ledger.count); return }
        if let failure = lastFailure ?? ledger.values.compactMap(\.failure).sorted().first { status = .blocked(reason: failure, unconfirmed: ledger.count) }
        else if rawTerminalAttempts.contains(where: { barriers[$0] != nil }) { status = .saving(unconfirmed: ledger.count) }
        else if ledger.isEmpty { status = .saved(head: lastConfirmedHead) }
        else { status = .saving(unconfirmed: ledger.count) }
    }
    private func stableID(_ parts: [String]) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8)))
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
    private func fail(_ reason: String) { lastFailure = reason; onFailure?(reason); refreshStatus() }
    /// Used by the ClientModel extension for a typed wire it cannot build itself.
    @discardableResult func enqueueDelta(key: String, fence: ArchiveFence, attempt: String?, deltas new: [ArchiveDelta]) -> Bool {
        enqueue(key: key, fence: fence, attempt: attempt, deltas: new)
    }
    /// Typed material in ordered chunks. Each chunk is its own real submission with its own acknowledgement, so
    /// "the material is saved" is only ever claimed after the last chunk's own ack. A chunk that is refused stays
    /// caller-side pending: the caller keeps the text and the UI must keep showing it as unsaved.
    @discardableResult public func submitMaterialChunk(session: String, chunk: MaterialChunk) -> Bool {
        guard chunk.chunkCount > 0, chunk.chunkIndex >= 0, chunk.chunkIndex < chunk.chunkCount,
              !chunk.materialID.isEmpty, !chunk.fileName.isEmpty else { fail("MATERIAL_CHUNK_INVALID"); return false }
        let accepted = enqueue(key: "material:\(session):\(chunk.materialID):\(chunk.chunkIndex)",
                               fence: ArchiveFence(sessionID: session), attempt: nil,
            deltas: [.materialChunk(materialID: chunk.materialID, fileName: chunk.fileName, sha256: chunk.sha256,
                                    importedAtReferenceBits: chunk.importedAtReferenceBits,
                                    chunkIndex: UInt64(chunk.chunkIndex), chunkCount: UInt64(chunk.chunkCount),
                                    text: chunk.text)])
        if accepted { submittedMaterialChunks["\(session):\(chunk.materialID)", default: []].insert(chunk.chunkIndex) }
        return accepted
    }
    /// Chunk indices already handed to the ledger, per `session:materialID`. Used to make a caller retry
    /// idempotent (a chunk is never submitted twice) and to report how much of a material is really durable.
    public private(set) var submittedMaterialChunks: [String: Set<Int>] = [:]
    /// The durable, acknowledged state of one material in the projection: how many chunks landed and whether
    /// that is all of them. `nil` means nothing about this material is durable yet.
    public func durableMaterialChunks(session: String, materialID: String) -> (received: Int, total: Int)? {
        guard let material = projection?.sessions[session]?.materials[materialID] else { return nil }
        return (Int(material.receivedChunks), Int(material.chunkCount))
    }
    @discardableResult public func bootstrapSession(_ session: LocalSession) -> Bool {
        if openedSessions.contains(session.id) { return true }
        guard session.segments.isEmpty, session.speechJournal.isEmpty, session.noteHistory.isEmpty,
              session.captureAttempts.isEmpty, session.materials.isEmpty else { fail("NONEMPTY_BOOTSTRAP_NOT_SUPPORTED"); return false }
        let bootstrap = ArchiveSessionBootstrap(title: session.title, createdAtReferenceBits: session.createdAt.timeIntervalSinceReferenceDate.bitPattern,
            isDemo: session.isDemo, initialNotes: session.notes, tags: session.tags)
        let accepted = enqueue(key: "bootstrap:\(session.id)", fence: ArchiveFence(sessionID: session.id), attempt: nil, deltas: [.sessionBootstrap(bootstrap)])
        if accepted { openedSessions.insert(session.id) }; return accepted
    }
    @discardableResult public func submitNoteVersion(session: String, note: NoteVersion) -> Bool {
        guard note.revision > 0 else { fail("NOTES_REVISION_INVALID"); return false }
        return enqueue(key: "notes:\(session):\(note.revision)", fence: ArchiveFence(sessionID: session), attempt: nil,
            deltas: [.notesVersion(revision: UInt64(note.revision), text: note.text, savedAtReferenceBits: note.savedAt.timeIntervalSinceReferenceDate.bitPattern)])
    }
    func markLocalFailure(_ reason: String) { fail(reason) }

    // MARK: - explicit submit surface
    public func openSession(id: String, title: String) {
        // A session opens exactly once. Re-opening with the same title is a real no-op; a different title is a
        // visible conflict, never a silent second record.
        if openedSessions.contains(id) {
            if let durable = projection?.sessions[id], durable.title != title { fail("SESSION-TITLE-CONFLICT: \(id)") }
            return
        }
        let accepted = enqueue(key: "opened:\(id)", fence: ArchiveFence(sessionID: id), attempt: nil, deltas: [.sessionOpened(title: title)])
        if accepted { openedSessions.insert(id) }
    }
    /// Returns true only when the metadata revision was really admitted to the ledger. The caller keeps its own
    /// "submitted" marker, so a rejected title/tag revision stays caller-side pending instead of being reported saved.
    @discardableResult public func submitMetadata(session: String, title: String, tags: [String]) -> Bool {
        let next = (metadataRevision[session] ?? 0) + 1
        let accepted = enqueue(key: "metadata:\(session):\(next)", fence: ArchiveFence(sessionID: session), attempt: nil,
                deltas: [.sessionMetadataRevision(revision: next, title: title, tags: tags)])
        if accepted { metadataRevision[session] = next }
        return accepted
    }
    /// Typed logical deletion. Returns true only when the record was really admitted; a session that already has
    /// one durable tombstone is refused rather than silently accepted twice.
    @discardableResult public func submitTombstone(session: String, record: LocalTombstone) -> Bool {
        guard !record.id.isEmpty, !record.actorKind.isEmpty, !record.reason.isEmpty else { fail("TOMBSTONE_IDENTITY_INVALID"); return false }
        guard projection?.sessions[session]?.tombstone == nil, !submittedTombstones.contains(session) else { fail("TOMBSTONE_ALREADY_PRESENT: \(session)"); return false }
        let accepted = enqueue(key: "tombstone:\(session)", fence: ArchiveFence(sessionID: session), attempt: nil,
            deltas: [.sessionTombstone(recordID: record.id, deletedAtReferenceBits: record.deletedAt.timeIntervalSinceReferenceDate.bitPattern,
                                       actorKind: record.actorKind, reason: record.reason)])
        if accepted { submittedTombstones.insert(session) }
        return accepted
    }
    @discardableResult public func submitNotes(session: String, revision: Int, text: String) -> Bool {
        guard revision > 0 else { fail("NOTES_REVISION_INVALID; no invented rev1"); return false }
        return enqueue(key: "notes:\(session):\(revision)", fence: ArchiveFence(sessionID: session), attempt: nil,
                deltas: [.notesRevision(revision: UInt64(revision), text: text)])
    }
    /// Accepts the producer's original bytes; decoding and typed validation happen on the bridge queue.
    @discardableResult public func submitWire(session: String, fence: ArchiveFence, wire: Data, sequence: Int) -> Bool {
        guard wire.count <= 24 * 1024 else { fail("WIRE_INPUT_LIMIT; caller journal retained"); return false }
        return enqueue(key: "speech:\(session):\(sequence)", fence: fence, attempt: fence.attemptID, deltas: [],
                       reservation: wire.count * 8 + 4096, build: { [wire] in [try speechDelta(from: wire)] })
    }
    public func beginAttempt(fence: ArchiveFence, requiresTerminalCoverage: Bool) {
        guard let attempt = fence.attemptID else { fail("ATTEMPT_FENCE_INCOMPLETE"); return }
        if let existing = acceptedFences[attempt], existing != fence { fail("GENERATION_FENCE_MISMATCH: \(attempt)"); return }
        acceptedFences[attempt] = fence
        // Restart recovery: a coverage revision that is already durable counts as acknowledged, so a retried
        // attempt does not wait forever for an ack that happened in a previous process.
        let durableCoverage = projection?.sessions[fence.sessionID]?.attempts[fence]?
            .observations.contains { $0.kind == .terminalCoverage } == true
        if durableCoverage { coveredAttempts.insert(attempt) }
        barriers[attempt] = Barrier(attempt: attempt, fence: fence, requiresCoverage: requiresTerminalCoverage,
                                    coverageAcked: !requiresTerminalCoverage || durableCoverage, completedSubmitted: false)
        enqueue(key: "attemptBegan:\(attempt)", fence: fence, attempt: attempt,
                deltas: [.attemptBegan(requiresTerminalCoverage: requiresTerminalCoverage)])
    }
    public func submitCanonical(fence: ArchiveFence, observations: [CanonicalObservation]) {
        guard !observations.isEmpty, let attempt = fence.attemptID else { return }
        guard acceptedFences[attempt] != nil else { fail("CANONICAL-WITHOUT-ATTEMPT-BEGIN: \(attempt)"); return }
        if let existing = acceptedFences[attempt], existing != fence { fail("GENERATION_FENCE_MISMATCH: \(attempt)"); return }
        let hasCoverage = observations.contains { $0.kind == .terminalCoverage }
        let kindKey = stableID(observations.map { String(describing: $0.kind) }).uuidString
        let key = "canonical:\(attempt):\(kindKey)"
        if hasCoverage { coveredAttempts.insert(attempt); barriers[attempt]?.coverageAcked = false }
        let coverageKey = hasCoverage ? attempt : nil
        enqueue(key: key, fence: fence, attempt: attempt, deltas: [.canonicalBatch(observations)],
                onAck: coverageKey.map { attempt in { @MainActor [weak self] in self?.barriers[attempt]?.coverageAcked = true } })
    }
    /// Raw terminal means "saving started", never "saved". Release capture only in onAttemptTerminalCommitted,
    /// which runs after text + associations + terminalCoverage + completed are all acknowledged.
    /// A repeat raw terminal for an attempt that already reached its acknowledged completed record is a real
    /// no-op: it must never be reported as a missing fence, which would poison the close gate after success.
    public func markRawTerminal(attempt: String) {
        if retiredAttempts.contains(attempt) { refreshStatus(); return }
        guard acceptedFences[attempt] != nil else { fail("TERMINAL-WITHOUT-ATTEMPT-FENCE: \(attempt)"); return }
        guard barriers[attempt] != nil else { fail("TERMINAL-WITHOUT-ATTEMPT-BEGIN: \(attempt)"); return }
        rawTerminalAttempts.insert(attempt)
        refreshStatus(); evaluateBarriers()
    }
    public func markCaptureFailed(attempt: String, reason: String) {
        if retiredAttempts.contains(attempt) { refreshStatus(); return }
        failedAttempts.insert(attempt)
        lastFailure = "CAPTURE_FAILED[\(attempt)]: \(reason)"
        refreshStatus()
    }
    /// Authoritative journal wires a session still holds back. Completion waits for zero, so an attempt can never
    /// be marked completed while transcript revisions are still only in the caller's journal.
    public func noteJournalBacklog(session: String, remaining: Int) {
        journalBacklog[session] = max(0, remaining); evaluateBarriers()
    }

    // MARK: - ledger and admission
    @discardableResult private func enqueue(key: String, fence: ArchiveFence, attempt: String?, deltas new: [ArchiveDelta],
                         onAck: (@MainActor () -> Void)? = nil, reservation: Int? = nil,
                         build: (@Sendable () throws -> [ArchiveDelta])? = nil) -> Bool {
        guard !closing, !isClosed else { fail("CLOSING_GATE; caller input retained"); return false }
        let bytes: Int
        do { bytes = try reservation ?? ClientArchiveBridge.reservation(fence: fence, deltas: new) }
        catch { fail("INPUT_REJECTED; caller input retained: \(error)"); return false }
        guard ledger.count < budget.maximumAdmittedCount, bytes <= budget.maximumReservedBytes - ledgerBytes else {
            fail("LEDGER_BUDGET_FULL; admitted revisions and caller input retained"); return false
        }
        nextGeneration += 1
        let generation = nextGeneration
        keyGeneration[key] = generation
        let id = stableID([key, String(generation)])
        ledger[id] = Dirty(id: id, key: key, keyGeneration: generation, fence: fence, attempt: attempt,
                           admitted: false, failure: nil)
        deltas[id] = new; builders[id] = build
        ledgerReservations[id] = bytes; ledgerBytes += bytes
        order.append(id)
        if let onAck { ackHooks[id] = onAck }
        refreshStatus(); drainLedger(); return true
    }
    private func drainLedger() {
        guard let bridge else { return }
        order.removeAll { ledger[$0] == nil }
        for id in order {
            guard let entry = ledger[id], !entry.admitted, entry.failure == nil else { continue }
            var admitted = entry; admitted.admitted = true; ledger[id] = admitted
            let requestDeltas = deltas[id] ?? []
            let requestBuilder: @Sendable () throws -> [ArchiveDelta] = builders[id] ?? { requestDeltas }
            // Admission must preserve submission order: revision N+1 is only valid after N is admitted.
            let previous = admissionChain
            admissionChain = Task { [weak self] in
                await previous?.value
                await self?.admit(id: id, entry: admitted, build: requestBuilder, bridge: bridge)
            }
            if let chain = admissionChain { admissionTasks[id] = chain }
        }
        order.removeAll { ledger[$0]?.admitted == true }
    }
    private func admit(id: UUID, entry: Dirty, build requestBuilder: @escaping @Sendable () throws -> [ArchiveDelta], bridge: ClientArchiveBridge) async {
        defer { admissionTasks.removeValue(forKey: id) }
        do {
            _ = try await bridge.submit(id: id, fence: entry.fence,
                onAcknowledged: { ack in Task { @MainActor in self.handleAck(ack) } },
                onFailure: { notice in Task { @MainActor in self.handleFailure(notice) } }
            ) { head in
                if entry.key.hasPrefix("completed:") { return [.attemptEnded(outcome: .completed, requiredCommitSequence: head)] }
                return try requestBuilder()
            }
        } catch {
            await MainActor.run { self.handleAdmissionRejection(id: id, error: error) }
        }
    }
    private func handleAdmissionRejection(id: UUID, error: Error) {
        guard var entry = ledger[id] else { return }
        entry.failure = String(describing: error); entry.admitted = false; ledger[id] = entry
        fail("提交被拒（原始输入仍由调用方持有）：\(entry.failure!)")
    }
    private func handleAck(_ ack: ArchiveAcknowledgement) {
        guard let entry = ledger[ack.token.submissionID] else { return }
        guard entry.fence == ack.token.fence else { fail("ACK_FENCE_MISMATCH: \(ack.token.submissionID)"); return }
        // Every acknowledgement clears exactly its own submission. A newer dirty entry has a different ID
        // and remains intact; retaining an older acknowledged entry would stall the terminal barrier forever.
        ledger.removeValue(forKey: entry.id); deltas.removeValue(forKey: entry.id)
        builders.removeValue(forKey: entry.id)
        if let bytes = ledgerReservations.removeValue(forKey: entry.id) { ledgerBytes -= bytes }
        admissionTasks.removeValue(forKey: entry.id)
        if keyGeneration[entry.key] == entry.keyGeneration { keyGeneration.removeValue(forKey: entry.key) }
        ackHooks.removeValue(forKey: entry.id)?()
        if let bridge {
            lastConfirmedHead = max(lastConfirmedHead, bridge.writer.status.confirmedHead)
            // Snapshot read outside any long lock; the bridge exposes an immutable COW projection.
            projection = bridge.state.acknowledgedProjection
        }
        if entry.key.hasPrefix("completed:") {
            let attempt = entry.attempt ?? ""
            retire(attempt: attempt)
            barriers.removeValue(forKey: attempt); coveredAttempts.remove(attempt)
            rawTerminalAttempts.remove(attempt); acceptedFences.removeValue(forKey: attempt)
            completionProjectionDeltas.removeValue(forKey: attempt)
            if terminalOutcomes[attempt] != nil, terminalOutcomes[attempt] != .completed,
               lastFailure?.hasPrefix("CAPTURE_FAILED[") == true { lastFailure = nil }
            terminalOutcomes.removeValue(forKey: attempt); failedAttempts.remove(attempt)
            onAttemptTerminalCommitted?(attempt)
        }
        refreshStatus(); onAcknowledged?(lastConfirmedHead); evaluateBarriers()
    }
    private func handleFailure(_ notice: ArchiveFailureNotice) {
        guard var entry = ledger[notice.token.submissionID] else { return }
        entry.failure = String(describing: notice.error); ledger[notice.token.submissionID] = entry
        fail("写入失败（全部未确认修订保留，未清除任何编辑）：\(entry.failure!)")
    }

    // MARK: - completed barrier
    private func evaluateBarriers() {
        for (attempt, barrier) in barriers where !barrier.completedSubmitted {
            guard rawTerminalAttempts.contains(attempt) else { continue }
            let outcome = terminalOutcomes[attempt] ?? .completed
            if outcome == .completed {
                guard !failedAttempts.contains(attempt), lastFailure == nil, barrier.coverageAcked else { continue }
            } else {
                guard lastFailure == nil || lastFailure?.hasPrefix("CAPTURE_FAILED[") == true else { continue }
            }
            guard ledger.isEmpty else { continue }
            // No transcript wire may still be held by the caller's journal when an attempt is declared complete.
            guard (journalBacklog[barrier.fence.sessionID] ?? 0) == 0 else { continue }
            guard !ledger.values.contains(where: { $0.attempt == attempt }) else { continue }
            submitCompleted(attempt: attempt, barrier: barrier)
        }
    }
    private func submitCompleted(attempt: String, barrier: Barrier) {
        guard let bridge else { return }
        var updated = barrier; updated.completedSubmitted = true; barriers[attempt] = updated
        let key = "completed:\(attempt)"
        nextGeneration += 1
        let generation = nextGeneration
        keyGeneration[key] = generation
        let id = stableID([key, String(generation)])
        ledger[id] = Dirty(id: id, key: key, keyGeneration: generation, fence: barrier.fence, attempt: attempt,
                           admitted: true, failure: nil)
        let outcome = terminalOutcomes[attempt] ?? .completed
        let finalProjection = outcome == .completed ? (completionProjectionDeltas[attempt] ?? []) : []
        let bytes = (try? ClientArchiveBridge.reservation(fence: barrier.fence,
            deltas: finalProjection + [.attemptEnded(outcome: outcome, requiredCommitSequence: 0)])) ?? 4096
        ledgerReservations[id] = bytes; ledgerBytes += bytes
        refreshStatus()
        let previous = admissionChain
        let task = Task {
            await previous?.value
            defer { admissionTasks.removeValue(forKey: id) }
            do {
                _ = try await bridge.submit(id: id, fence: barrier.fence, durability: .fsync,
                    onAcknowledged: { ack in Task { @MainActor in self.handleAck(ack) } },
                    onFailure: { notice in Task { @MainActor in self.handleFailure(notice) } }
                ) { plannedHead in finalProjection + [.attemptEnded(outcome: outcome, requiredCommitSequence: plannedHead)] }
            } catch {
                await MainActor.run { self.handleAdmissionRejection(id: id, error: error) }
            }
        }
        admissionChain = task
        admissionTasks[id] = task
    }

    // MARK: - barriers / close
    /// Waits until every accepted revision is acknowledged by the writer, then takes the real fsync barrier.
    /// A revision still queued for admission/validation must never be missed by this barrier, and a rejection
    /// that left caller content outside the ledger is surfaced instead of being reported as quiescent.
    public func awaitQuiescence() async throws -> ArchiveWatermark {
        guard let bridge else { throw BridgeFailure.invalid("bridge not open") }
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while true {
            drainLedger()
            for task in Array(admissionTasks.values) { await task.value }
            let watermark = try await bridge.flush(durability: .fsync)
            lastConfirmedHead = max(lastConfirmedHead, watermark.confirmedHead)
            await Task.yield()
            refreshStatus()
            if let failure = ledger.values.compactMap(\.failure).first { throw BridgeFailure.invalid(failure) }
            if ledger.isEmpty && admissionTasks.isEmpty {
                // Everything accepted is durable. Only a failure that means "admitted/attempted work did not
                // become durable" throws here; a pure caller-side rejection is reported through
                // `blockingFailure`/`callerPendingProvider` and is enforced by `close()`, not by this barrier.
                if let failure = durableFailure { throw BridgeFailure.invalid(failure) }
                return watermark
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw BridgeFailure.invalid("quiescence timeout; unconfirmed revisions retained")
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
    /// Explicit idempotent retry: same stable IDs, same expected head and payload. Conflicts stay visible.
    public func retryUnconfirmed() {
        do { try bridge?.retryUnconfirmed() }
        catch { fail("重试失败（未确认修订仍保留）：\(error)") }
        for (id, var entry) in ledger where entry.failure != nil {
            entry.failure = nil
            if !entry.admitted { order.append(id) }
            ledger[id] = entry
        }
        if ledger.values.allSatisfy({ $0.failure == nil }) { lastFailure = nil }
        refreshStatus(); drainLedger()
    }
    /// Failures recorded before any ledger entry exists: the caller's content was rejected and is still held
    /// by the caller. They stay visible until the content itself has been re-submitted and confirmed.
    static func isCallerSideRejection(_ text: String) -> Bool {
        ["LEDGER_BUDGET_FULL", "INPUT_REJECTED", "WIRE_INPUT_LIMIT", "NOTES_REVISION_INVALID", "CLOSING_GATE"]
            .contains { text.contains($0) }
    }
    /// Explicit resolution of a caller-side rejection: only valid once no admitted revision is failing and the
    /// recorded failure came from a rejection (never from a failed write). Bounded, never a blanket clearer.
    @discardableResult public func resolveCallerRejections() -> Bool {
        guard ledger.values.allSatisfy({ $0.failure == nil }), admissionTasks.isEmpty else { return false }
        guard let last = lastFailure, Self.isCallerSideRejection(last) else { return false }
        lastFailure = nil; refreshStatus(); return true
    }
    /// Closing gate: refuse new writes, wait the real durability barrier, and succeed only with zero
    /// unconfirmed revisions, zero caller-held content, zero unresolved caller failure and no open capture.
    /// A failure never closes the store: the caller keeps the window and every unconfirmed revision.
    public func close() async -> (closed: Bool, unconfirmed: Int, reason: String?) {
        guard let bridge else { return (false, ledger.count, "bridge not open") }
        guard !closing else { return (false, ledger.count, "CLOSE_IN_PROGRESS") }
        // Preflight (bounded): hand every held-back caller revision to the writer BEFORE the closing gate exists,
        // then take a real barrier so the next round sees the freed budget. Never unbounded, never a snapshot.
        for _ in 0..<4 {
            if let drain = callerDrainForClose { await drain() }
            // `awaitQuiescence` also reports a caller-side rejection; the drain above may have just confirmed the
            // very content that record referred to, so the throw is only noted, never treated as close success.
            _ = try? await awaitQuiescence()
            if callerPendingProvider == nil { break }
            let pending = callerPendingProvider?()
            if ledger.isEmpty, admissionTasks.isEmpty, (pending?.total ?? 0) == 0 {
                // Nothing at all is held back any more. A caller-side rejection recorded earlier ("budget full",
                // "input rejected", "wire too long") is then stale bookkeeping, not a real blocker: resolve it.
                // A failed write or an explicit caller report is never cleared here.
                resolveCallerRejections()
                break
            }
        }
        // MARK: store-side close conditions, none of which may be hidden by an empty ledger
        if sessionsWithHeldJournal > 0 {
            return (false, ledger.count, "caller 仍持有 \(sessionsWithHeldJournal) 个会话的未提交转写 wire；未关闭存储")
        }
        if !barriers.isEmpty {
            return (false, ledger.count, "采集终态未确认（\(barriers.count) 个 attempt 尚无已完成记录）；未关闭存储")
        }
        if let failure = blockingFailure { return (false, ledger.count, failure) }
        if let pending = callerPendingProvider?(), !pending.isClean {
            return (false, ledger.count + pending.total, pending.reason ?? "caller 仍有未提交内容；未关闭存储")
        }
        if !ledger.isEmpty || !admissionTasks.isEmpty {
            return (false, ledger.count + admissionTasks.count, "仍有未确认修订，未关闭存储")
        }
        closing = true; refreshStatus()
        do {
            let watermark = try await awaitQuiescence()
            lastConfirmedHead = max(lastConfirmedHead, watermark.confirmedHead)
            guard ledger.isEmpty, admissionTasks.isEmpty else {
                closing = false; refreshStatus(); return (false, ledger.count, "仍有未确认修订，未关闭存储")
            }
            if let pending = callerPendingProvider?(), !pending.isClean {
                closing = false; refreshStatus()
                return (false, pending.total, pending.reason ?? "caller 仍有未提交内容；未关闭存储")
            }
            _ = try await bridge.close(durability: .fsync)
            closing = false; isClosed = true
            status = .closed; return (true, 0, nil)
        } catch {
            closing = false; refreshStatus(); return (false, ledger.count, String(describing: error))
        }
    }
}
