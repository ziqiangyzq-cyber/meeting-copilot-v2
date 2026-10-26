import Foundation

struct SemanticState {
    /// Ordered chunk accumulation for one material. `receivedChunks` counts acknowledged chunks, so a gap,
    /// a repeat or an out-of-range chunk is refused instead of being silently stitched into wrong text.
    struct Material {
        let fileName: String, sha256: String, importedAtReferenceBits: UInt64, chunkCount: UInt64
        var receivedChunks: UInt64 = 0
        var complete: Bool { receivedChunks == chunkCount }
    }
    struct Session {
        var closed = false
        var metadataRevision: UInt64 = 0
        var title: String
        var tags: [String] = []
        init(title: String) { self.title = title }
        var notesRevision: UInt64 = 0, speechSequence: UInt64 = 0
        var source: [String: UInt64] = [:], translations: [String: UInt64] = [:]
        var sourceOwners: [String: ArchiveFence] = [:]
        var presentationIndices: [String: UInt64] = [:]
        var captureIdentities: [String: ArchiveCaptureIdentity] = [:]
        var captureStateRevisions: [String: UInt64] = [:]
        var captureGenerations: [String: String] = [:]
        var captureTasks: [String: [String: String]] = [:]
        var tombstoneRecord = false
        var materials: [String: Material] = [:]
    }
    struct Attempt {
        var finished: Bool
        var requiresCoverage: Bool
        var terminalCoverageSequence: UInt64?
        var terminalCompletionFlag: Bool
        init(requiresCoverage: Bool) {
            finished = false; self.requiresCoverage = requiresCoverage
            terminalCoverageSequence = nil; terminalCompletionFlag = false
        }
    }
    var sessions: [String: Session] = [:]
    var attempts: [ArchiveFence: Attempt] = [:]
    var generations: Set<UUID> = []
    mutating func apply(_ record: ArchiveRecord) throws {
        let request = record.submission, fence = request.fence
        for delta in request.deltas {
            if case .sessionBootstrap(let bootstrap) = delta {
                guard fence.isSession, sessions[fence.sessionID] == nil, Double(bitPattern: bootstrap.createdAtReferenceBits).isFinite else { throw ArchiveFailure.fence("bootstrap reused / wrong scope / invalid date") }
                var value = Session(title: bootstrap.title); value.tags = bootstrap.tags
                sessions[fence.sessionID] = value; continue
            }
            if case .sessionOpened(let title) = delta {
                guard fence.isSession, sessions[fence.sessionID] == nil else { throw ArchiveFailure.fence("session reused / wrong scope") }
                sessions[fence.sessionID] = Session(title: title); continue
            }
            guard var session = sessions[fence.sessionID], !session.closed else { throw ArchiveFailure.fence("unknown/closed session") }
            if case .attemptBegan(let requiresCoverage) = delta {
                guard fence.isAttempt, attempts[fence] == nil, let generation = fence.generationID,
                      !generations.contains(generation), !attempts.keys.contains(where: { $0.sessionID == fence.sessionID && $0.attemptID == fence.attemptID }) else {
                    throw ArchiveFailure.fence("attempt/generation reused or missing")
                }
                attempts[fence] = Attempt(requiresCoverage: requiresCoverage); generations.insert(generation); continue
            }
            if fence.isAttempt {
                guard let attempt = attempts[fence], !attempt.finished else { throw ArchiveFailure.fence("stale/closed attempt or generation") }
            } else if !fence.isSession { throw ArchiveFailure.fence("partial attempt fence") }
            switch delta {
            case .sessionClosed(let through):
                guard fence.isSession, through == request.expectedHead,
                      !attempts.contains(where: { $0.key.sessionID == fence.sessionID && !$0.value.finished }) else { throw ArchiveFailure.fence("unconfirmed head or active attempt at session close") }
                session.closed = true
            case .attemptEnded(let outcome, let through):
                guard fence.isAttempt, through == request.expectedHead, var attempt = attempts[fence] else { throw ArchiveFailure.fence("terminal dependency") }
                if outcome == .completed, attempt.requiresCoverage {
                    guard let coverageSeq = attempt.terminalCoverageSequence, coverageSeq <= through, attempt.terminalCompletionFlag else {
                        throw ArchiveFailure.fence("completed requires previously committed actual terminal coverage flag")
                    }
                }
                attempt.finished = true; attempts[fence] = attempt
            case .sessionMetadataRevision(let revision, let title, let tags):
                guard fence.isSession else { throw ArchiveFailure.fence("session metadata requires session scope") }
                guard session.metadataRevision < UInt64.max, revision == session.metadataRevision + 1 else { throw ArchiveFailure.revision("session metadata must retain every revision") }
                session.metadataRevision = revision; session.title = title; session.tags = tags
            case .notesVersion(let revision, _, let bits):
                guard fence.isSession, Double(bitPattern: bits).isFinite, session.notesRevision < UInt64.max,
                      revision == session.notesRevision + 1 else { throw ArchiveFailure.revision("exact notes date/revision") }
                session.notesRevision = revision
            case .segmentPresentation(let id, _, let index):
                guard fence.isSession, session.source[id] != nil else { throw ArchiveFailure.fence("presentation source missing") }
                if let old = session.presentationIndices[id] {
                    guard old == index else { throw ArchiveFailure.revision("segment insertion order changed") }
                } else {
                    guard index == UInt64(session.presentationIndices.count) else { throw ArchiveFailure.revision("segment insertion order gap") }
                    session.presentationIndices[id] = index
                }
            case .captureInitialized(let identity):
                guard fence.isSession, session.captureIdentities[identity.id] == nil else { throw ArchiveFailure.fence("capture initialized twice/wrong scope") }
                session.captureIdentities[identity.id] = identity
            case .captureState(let id, let revision, let state):
                guard (fence.isSession || (fence.isAttempt && fence.attemptID == id && state.generationID == fence.generationID?.uuidString)), session.captureIdentities[id] != nil, revision == (session.captureStateRevisions[id] ?? 0) + 1 else { throw ArchiveFailure.revision("capture state initialization/revision") }
                if state.lifecycle == "completed" {
                    guard fence.isAttempt, request.deltas.contains(where: { if case .attemptEnded(.completed, _) = $0 { return true }; return false }) else { throw ArchiveFailure.fence("completed capture state requires same completed transaction") }
                }
                if let generation = state.generationID {
                    guard UUID(uuidString: generation) != nil, session.captureGenerations[id] == nil || session.captureGenerations[id] == generation else { throw ArchiveFailure.fence("capture generation changed") }
                    session.captureGenerations[id] = generation
                } else if session.captureGenerations[id] != nil { throw ArchiveFailure.fence("capture generation removed") }
                session.captureStateRevisions[id] = revision
            case .captureTask(let id, let stream, let segment, _, _):
                guard fence.isSession, session.captureIdentities[id] != nil else { throw ArchiveFailure.fence("capture task initialization/scope") }
                var tasks = session.captureTasks[id] ?? [:]
                guard tasks[segment] == nil || tasks[segment] == stream,
                      !tasks.contains(where: { $0.key != segment && $0.value == stream }) else { throw ArchiveFailure.fence("capture task identity changed") }
                tasks[segment] = stream; session.captureTasks[id] = tasks
            case .captureSourceBlock(let id, let segment, let block):
                guard fence.isSession, session.captureTasks[id]?[segment] != nil, block.frameStart >= 0,
                      block.frameEnd > block.frameStart, block.mappingRevision > 0,
                      UInt64(block.startNS) != nil, UInt64(block.endNS) != nil else { throw ArchiveFailure.fence("capture source block owner/range") }
            case .notesRevision(let revision, _):
                guard session.notesRevision < UInt64.max, revision == session.notesRevision + 1 else { throw ArchiveFailure.revision("notes must retain every revision") }
                session.notesRevision = revision
            case .sessionTombstone(let record, let bits, let actor, let reason):
                // Logical deletion only: the session entity, its revisions and journal stay replayable.
                guard fence.isSession, !session.tombstoneRecord, !record.isEmpty, !actor.isEmpty,
                      Double(bitPattern: bits).isFinite, !reason.isEmpty else { throw ArchiveFailure.fence("tombstone scope/duplicate/identity") }
                session.tombstoneRecord = true
            case .materialChunk(let id, let fileName, let sha, let bits, let chunkIndex, let chunkCount, _):
                // Session scope only, index must continue exactly where the previous acknowledged chunk ended,
                // identity/first-import date may never change, and a complete material accepts nothing further.
                guard fence.isSession, chunkCount > 0, chunkIndex < chunkCount,
                      Double(bitPattern: bits).isFinite else { throw ArchiveFailure.fence("material chunk scope/index/date") }
                if var existing = session.materials[id] {
                    guard existing.fileName == fileName, existing.sha256 == sha,
                          existing.importedAtReferenceBits == bits, existing.chunkCount == chunkCount,
                          !existing.complete, chunkIndex == existing.receivedChunks else {
                        throw ArchiveFailure.fence("material chunk identity/gap/complete")
                    }
                    existing.receivedChunks += 1; session.materials[id] = existing
                } else {
                    guard chunkIndex == 0 else { throw ArchiveFailure.fence("material chunk must start at index 0") }
                    var value = Material(fileName: fileName, sha256: sha, importedAtReferenceBits: bits, chunkCount: chunkCount)
                    value.receivedChunks = 1; session.materials[id] = value
                }
            case .speechEvent(let sequence, _): try advance(sequence, session: &session)
            case .sourceRevision(let id, let revision, let sequence, _):
                // Typed sources use session scope; captured sources use an already-validated attempt fence.
                if let owner = session.sourceOwners[id], owner != fence { throw ArchiveFailure.fence("source segment owner fence cannot change") }
                let old = session.source[id] ?? 0
                guard old < UInt64.max, revision == old + 1 else { throw ArchiveFailure.revision("source revision") }
                try advance(sequence, session: &session); session.source[id] = revision; session.sourceOwners[id] = fence
            case .translationRevision(let id, let revision, let segment, let sourceRevision, let sequence, _):
                let old = session.translations[id] ?? 0
                guard old < UInt64.max, revision == old + 1, session.source[segment] == sourceRevision else { throw ArchiveFailure.revision("translation revision/source binding") }
                try advance(sequence, session: &session); session.translations[id] = revision
            case .canonicalBatch(let observations):
                guard fence.isAttempt else { throw ArchiveFailure.fence("canonical requires actual attempt/generation") }
                if let terminal = observations.last(where: { $0.kind == .terminalCoverage }), var attempt = attempts[fence] {
                    attempt.terminalCoverageSequence = record.commitSequence
                    attempt.terminalCompletionFlag = terminal.fields["completionCoverageValid"] == .boolean(true)
                    attempts[fence] = attempt
                }
            default: throw ArchiveFailure.invalidInput("operation state")
            }
            sessions[fence.sessionID] = session
        }
    }
    private func advance(_ sequence: UInt64, session: inout Session) throws {
        guard session.speechSequence < UInt64.max, sequence == session.speechSequence + 1 else { throw ArchiveFailure.revision("supplied SpeechCore sequence must replay contiguously; never allocated here") }
        session.speechSequence = sequence
    }
    var unfinished: [ArchiveFence] {
        attempts.filter { !$0.value.finished }.map(\.key).sorted { ($0.sessionID, $0.attemptID ?? "") < ($1.sessionID, $1.attemptID ?? "") }
    }
}
