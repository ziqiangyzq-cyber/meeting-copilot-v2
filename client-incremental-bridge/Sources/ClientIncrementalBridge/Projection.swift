import Foundation
import IncrementalArchive
import SpeechCore

public enum BridgeFailure: Error { case invalid(String), unsupportedBootstrap(String) }
public struct BridgeNote: Equatable { public let revision: UInt64, text: String; public var savedAtReferenceBits: UInt64? = nil }
public struct BridgeCaptureTask {
    public let streamID: String, segmentID: String, firstObservedBy: String
    public var finalObserved: Bool
    public var blocks: [ArchiveCaptureSourceBlock]? = nil
}
public struct BridgeCapture {
    public let identity: ArchiveCaptureIdentity
    public var state: ArchiveCaptureState?
    public var stateRevision: UInt64 = 0
    public var history: [String] = []
    public var tasks: [BridgeCaptureTask]? = nil
}
public struct BridgeSegmentPresentation { public let insertionIndex: UInt64; public let sourceLanguage: String? }
public struct BridgeAttempt: Equatable {
    public let fence: ArchiveFence
    public var observations: [CanonicalObservation] = []
    public var outcome: ArchiveAttemptOutcome?
    public var requiredCommitSequence: UInt64?
}
public struct BridgeTombstone: Equatable {
    public let recordID: String, deletedAtReferenceBits: UInt64, actorKind: String, reason: String
    public init(recordID: String, deletedAtReferenceBits: UInt64, actorKind: String, reason: String) {
        self.recordID = recordID; self.deletedAtReferenceBits = deletedAtReferenceBits; self.actorKind = actorKind; self.reason = reason
    }
}
/// Accumulated chunks of one material. `text` is the concatenation of the acknowledged chunks only, so an
/// incomplete material exposes partial text together with `complete == false` and is never shown as full.
public struct BridgeMaterial: Equatable {
    public let materialID: String, fileName: String, sha256: String, importedAtReferenceBits: UInt64, chunkCount: UInt64
    public var receivedChunks: UInt64 = 0
    public var text: String = ""
    public var complete: Bool { receivedChunks == chunkCount }
}
// Exact subset of LocalArchive: no invented createdAt/savedAt/locale/material fields.
public struct BridgeSession {
    public let id: String
    public var title: String
    public var bootstrap: ArchiveSessionBootstrap?
    public var captureOrder: [String] = []
    public var captures: [String: BridgeCapture] = [:]
    public var presentations: [String: BridgeSegmentPresentation] = [:]
    public var metadataRevision: UInt64 = 0
    public var tags: [String] = []
    public var notes: [BridgeNote] = []
    public var journal: [Data] = []
    public var core: SpeechReducer
    public var attempts: [ArchiveFence: BridgeAttempt] = [:]
    public var tombstone: BridgeTombstone? = nil
    public var materialOrder: [String] = []
    public var materials: [String: BridgeMaterial] = [:]
    public var closed = false
}
public struct BridgeProjection {
    public private(set) var head: UInt64 = 0
    public private(set) var sessions: [String: BridgeSession] = [:]
    public private(set) var sessionOrder: [String] = []
    public let limits: CoreLimits
    public init(limits: CoreLimits) { self.limits = limits }
    public mutating func apply(_ submission: ArchiveSubmission) throws {
        guard submission.expectedHead == head, head < UInt64.max else { throw BridgeFailure.invalid("projection head") }
        // Apply transactionally: no partially applied projection if wire decoding/reducer rejects.
        var next = self
        for delta in submission.deltas { try next.apply(delta, fence: submission.fence) }
        next.head += 1; self = next
    }
    private mutating func apply(_ delta: ArchiveDelta, fence: ArchiveFence) throws {
        if case .sessionBootstrap(let bootstrap) = delta {
            guard fence.attemptID == nil, fence.generationID == nil, sessions[fence.sessionID] == nil,
                  Double(bitPattern: bootstrap.createdAtReferenceBits).isFinite else { throw BridgeFailure.invalid("bootstrap scope/date/reused") }
            var value = BridgeSession(id: fence.sessionID, title: bootstrap.title, core: try SpeechReducer(sessionId: fence.sessionID, limits: limits))
            value.bootstrap = bootstrap; value.tags = bootstrap.tags; sessions[fence.sessionID] = value
            sessionOrder.insert(fence.sessionID, at: 0)
            return
        }
        if case .sessionOpened(let title) = delta {
            guard sessions[fence.sessionID] == nil else { throw BridgeFailure.invalid("session reused") }
            sessions[fence.sessionID] = BridgeSession(id: fence.sessionID, title: title,
                core: try SpeechReducer(sessionId: fence.sessionID, limits: limits))
            return
        }
        guard var session = sessions[fence.sessionID] else { throw BridgeFailure.invalid("unknown session") }
        switch delta {
        case .sessionMetadataRevision(let revision, let title, let tags):
            guard fence.attemptID == nil, fence.generationID == nil, session.metadataRevision < UInt64.max,
                  revision == session.metadataRevision + 1 else { throw BridgeFailure.invalid("metadata fence/revision") }
            session.metadataRevision = revision; session.title = title; session.tags = tags
        case .notesVersion(let revision, let text, let date):
            guard revision == (session.notes.last?.revision ?? 0) + 1, Double(bitPattern: date).isFinite else { throw BridgeFailure.invalid("note version/date") }
            session.notes.append(BridgeNote(revision: revision, text: text, savedAtReferenceBits: date))
        case .segmentPresentation(let id, let language, let index):
            guard session.core.segments[id] != nil else { throw BridgeFailure.invalid("presentation unknown segment") }
            if let existing = session.presentations[id] { guard existing.insertionIndex == index else { throw BridgeFailure.invalid("presentation index changed") } }
            else { guard index == UInt64(session.presentations.count) else { throw BridgeFailure.invalid("presentation index gap") } }
            session.presentations[id] = BridgeSegmentPresentation(insertionIndex: index, sourceLanguage: language)
        case .captureInitialized(let identity):
            guard session.captures[identity.id] == nil else { throw BridgeFailure.invalid("capture init reused") }
            var capture = BridgeCapture(identity: identity); capture.tasks = identity.tasksPresent ? [] : nil
            session.captures[identity.id] = capture; session.captureOrder.append(identity.id)
        case .captureState(let id, let revision, let state):
            guard var value = session.captures[id], revision == value.stateRevision + 1 else { throw BridgeFailure.invalid("capture state gap") }
            value.state = state; value.stateRevision = revision; value.history.append(contentsOf: state.appendedHistory)
            session.captures[id] = value
        case .captureTask(let id, let stream, let segment, let observed, let final):
            guard var capture = session.captures[id] else { throw BridgeFailure.invalid("capture task init missing") }
            var tasks = capture.tasks ?? []
            if let index = tasks.firstIndex(where: { $0.segmentID == segment }) {
                guard tasks[index].streamID == stream, tasks[index].firstObservedBy == observed,
                      !tasks[index].finalObserved || final else { throw BridgeFailure.invalid("capture task changed") }
                tasks[index].finalObserved = final
            } else { tasks.append(BridgeCaptureTask(streamID: stream, segmentID: segment, firstObservedBy: observed, finalObserved: final)) }
            capture.tasks = tasks; session.captures[id] = capture
        case .captureSourceBlock(let id, let segment, let block):
            guard var capture = session.captures[id], let index = capture.tasks?.firstIndex(where: { $0.segmentID == segment }) else { throw BridgeFailure.invalid("capture block task missing") }
            var blocks = capture.tasks![index].blocks ?? []
            if !blocks.contains(block) { blocks.append(block) }
            capture.tasks![index].blocks = blocks; session.captures[id] = capture
        case .notesRevision(let revision, let text):
            guard revision == (session.notes.last?.revision ?? 0) + 1 else { throw BridgeFailure.invalid("notes revision") }
            session.notes.append(BridgeNote(revision: revision, text: text))
        case .sessionTombstone(let record, let bits, let actor, let reason):
            guard fence.attemptID == nil, fence.generationID == nil, session.tombstone == nil,
                  !record.isEmpty, !actor.isEmpty, Double(bitPattern: bits).isFinite, !reason.isEmpty else { throw BridgeFailure.invalid("tombstone scope/duplicate") }
            session.tombstone = BridgeTombstone(recordID: record, deletedAtReferenceBits: bits, actorKind: actor, reason: reason)
        case .materialChunk(let id, let fileName, let sha, let bits, let chunkIndex, let chunkCount, let text):
            // Mirror of the archive's own invariant, checked here as well so a caller can never be shown a
            // stitched-together material whose chunks arrived out of order or with a changed identity.
            guard fence.attemptID == nil, fence.generationID == nil, chunkCount > 0, chunkIndex < chunkCount,
                  Double(bitPattern: bits).isFinite else { throw BridgeFailure.invalid("material chunk scope/index/date") }
            if var existing = session.materials[id] {
                guard existing.fileName == fileName, existing.sha256 == sha, existing.importedAtReferenceBits == bits,
                      existing.chunkCount == chunkCount, !existing.complete, chunkIndex == existing.receivedChunks else {
                    throw BridgeFailure.invalid("material chunk identity/gap/complete")
                }
                existing.receivedChunks += 1; existing.text += text; session.materials[id] = existing
            } else {
                guard chunkIndex == 0 else { throw BridgeFailure.invalid("material chunk must start at index 0") }
                var value = BridgeMaterial(materialID: id, fileName: fileName, sha256: sha,
                                           importedAtReferenceBits: bits, chunkCount: chunkCount)
                value.receivedChunks = 1; value.text = text
                session.materials[id] = value; session.materialOrder.append(id)
            }
        case .speechEvent(let seq, let wire):
            let event = try checked(wire, sequence: seq, sessionID: fence.sessionID)
            guard event.type != "asr.segment", event.type != "translation.segment" else { throw BridgeFailure.invalid("use typed source/translation delta") }
            try receive(wire, event: event, session: &session)
        case .sourceRevision(let id, let rev, let seq, let wire):
            let event = try checked(wire, sequence: seq, sessionID: fence.sessionID)
            guard event.type == "asr.segment", event.segmentId == id, event.revision.flatMap(UInt64.init(exactly:)) == rev else { throw BridgeFailure.invalid("source wire binding") }
            try receive(wire, event: event, session: &session)
        case .translationRevision(let id, let rev, let segment, let sourceRev, let seq, let wire):
            let event = try checked(wire, sequence: seq, sessionID: fence.sessionID)
            guard event.type == "translation.segment", event.translationId == id,
                  event.revision.flatMap(UInt64.init(exactly:)) == rev, event.segmentId == segment,
                  event.sourceRevision.flatMap(UInt64.init(exactly:)) == sourceRev else { throw BridgeFailure.invalid("translation wire binding") }
            try receive(wire, event: event, session: &session)
        case .attemptBegan:
            guard session.attempts[fence] == nil else { throw BridgeFailure.invalid("attempt reused") }
            session.attempts[fence] = BridgeAttempt(fence: fence)
        case .canonicalBatch(let actual):
            guard var attempt = session.attempts[fence] else { throw BridgeFailure.invalid("unknown canonical owner") }
            attempt.observations.append(contentsOf: actual); session.attempts[fence] = attempt
        case .attemptEnded(let outcome, let dependency):
            guard dependency == head, var attempt = session.attempts[fence] else { throw BridgeFailure.invalid("terminal watermark") }
            attempt.outcome = outcome; attempt.requiredCommitSequence = dependency; session.attempts[fence] = attempt
        case .sessionClosed(let dependency):
            guard dependency == head else { throw BridgeFailure.invalid("session watermark") }; session.closed = true
        default: throw BridgeFailure.invalid("unsupported delta")
        }
        sessions[fence.sessionID] = session
    }
    private func checked(_ wire: Data, sequence: UInt64, sessionID: String) throws -> SpeechEvent {
        let event = try SpeechEvent.decode(wire)
        guard event.sessionId == sessionID, UInt64(exactly: event.eventSeq) == sequence else { throw BridgeFailure.invalid("actual wire session/sequence") }
        return event
    }
    private func receive(_ wire: Data, event: SpeechEvent, session: inout BridgeSession) throws {
        guard session.core.receive(wire, nowMs: 0) == .applied(event.eventSeq) else { throw BridgeFailure.invalid("authoritative reducer rejected") }
        session.journal.append(wire)
    }
}

// Caller supplies the existing wire; bridge does not allocate an event or reinterpret source timestamps.
public func speechDelta(from wire: Data) throws -> ArchiveDelta {
    let event = try SpeechEvent.decode(wire)
    guard let sequence = UInt64(exactly: event.eventSeq), sequence > 0 else { throw BridgeFailure.invalid("event sequence") }
    if event.type == "asr.segment" {
        guard let id = event.segmentId, let r = event.revision, let revision = UInt64(exactly: r) else { throw BridgeFailure.invalid("source fields") }
        return .sourceRevision(segmentID: id, revision: revision, eventSequence: sequence, wireData: wire)
    }
    if event.type == "translation.segment" {
        guard let id = event.translationId, let r = event.revision, let revision = UInt64(exactly: r),
              let segment = event.segmentId, let sr = event.sourceRevision, let sourceRevision = UInt64(exactly: sr) else { throw BridgeFailure.invalid("translation fields") }
        return .translationRevision(translationID: id, revision: revision, sourceSegmentID: segment,
                                   sourceRevision: sourceRevision, eventSequence: sequence, wireData: wire)
    }
    return .speechEvent(eventSequence: sequence, wireData: wire)
}
