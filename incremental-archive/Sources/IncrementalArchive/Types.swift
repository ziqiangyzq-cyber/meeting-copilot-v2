import Foundation

public enum ArchiveDurability: String, Codable, Sendable { case readback, fsync }
public struct ArchiveFence: Codable, Equatable, Hashable, Sendable {
    public let sessionID: String, attemptID: String?, generationID: UUID?
    public init(sessionID: String, attemptID: String? = nil, generationID: UUID? = nil) {
        self.sessionID = sessionID; self.attemptID = attemptID; self.generationID = generationID
    }
    var isSession: Bool { attemptID == nil && generationID == nil }
    var isAttempt: Bool { attemptID != nil && generationID != nil }
}
// Actual scalar values supplied by the adapter. The library never maps audio or computes coverage.
public enum CanonicalScalar: Codable, Equatable, Sendable {
    case string(String), signed(Int64), unsigned(UInt64), boolean(Bool), uuid(UUID), float64Bits(UInt64), null
    public static func float64(_ actual: Double) -> Self { .float64Bits(actual.bitPattern) }
    var inputBytes: Int {
        if case .string(let value) = self { return value.utf8.count }
        return 64
    }
}
public struct CanonicalObservation: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case mapped, associated, settled, terminalCoverage }
    public let kind: Kind, fields: [String: CanonicalScalar]
    public init(kind: Kind, fields: [String: CanonicalScalar]) { self.kind = kind; self.fields = fields }
}
public enum ArchiveAttemptOutcome: Codable, Equatable, Sendable {
    case completed, cancelled, incomplete(String)
}
public struct ArchiveSessionBootstrap: Codable, Equatable, Sendable {
    public let title: String, createdAtReferenceBits: UInt64, isDemo: Bool, initialNotes: String, tags: [String]
    public init(title: String, createdAtReferenceBits: UInt64, isDemo: Bool, initialNotes: String, tags: [String]) {
        self.title = title; self.createdAtReferenceBits = createdAtReferenceBits; self.isDemo = isDemo
        self.initialNotes = initialNotes; self.tags = tags
    }
}
public struct ArchiveCaptureIdentity: Codable, Equatable, Sendable {
    public let id: String, channelID: String, streamID: String, segmentID: String, locale: String
    public let tasksPresent: Bool
    public let engineVersion: String?, modelVersion: String?
    public let sourceKind: String?, sourceURL: String?
    public init(id: String, channelID: String, streamID: String, segmentID: String, locale: String, tasksPresent: Bool = false,
                engineVersion: String? = nil, modelVersion: String? = nil, sourceKind: String? = nil, sourceURL: String? = nil) {
        self.id = id; self.channelID = channelID; self.streamID = streamID; self.segmentID = segmentID; self.locale = locale; self.tasksPresent = tasksPresent
        self.engineVersion = engineVersion; self.modelVersion = modelVersion
        self.sourceKind = sourceKind; self.sourceURL = sourceURL
    }
}
public struct ArchiveCaptureState: Codable, Equatable, Sendable {
    public let lifecycle: String, failure: String?, deviceStarted: Bool, audioObserved: Bool, asrObserved: Bool
    public let mode: String?, generationID: String?, appendedHistory: [String]
    public let streamID: String, segmentID: String
    public init(lifecycle: String, failure: String?, deviceStarted: Bool, audioObserved: Bool, asrObserved: Bool,
                mode: String?, generationID: String?, appendedHistory: [String], streamID: String = "", segmentID: String = "") {
        self.lifecycle = lifecycle; self.failure = failure; self.deviceStarted = deviceStarted
        self.audioObserved = audioObserved; self.asrObserved = asrObserved; self.mode = mode
        self.generationID = generationID; self.appendedHistory = appendedHistory
        self.streamID = streamID; self.segmentID = segmentID
    }
}
// All Doubles use actual IEEE-754 bits, including optional/nonfinite raw observations.
public struct ArchiveCaptureSourceBlock: Codable, Equatable, Sendable {
    public let frameStart: Int, frameEnd: Int, mappingRevision: Int, startNS: String, endNS: String
    public let hostSecondsBits: UInt64?, samplePosition: Int64?, sampleRateBits: UInt64
    public let presentationSecondsBits: UInt64?, receivedUptimeBits: UInt64
    public init(frameStart: Int, frameEnd: Int, mappingRevision: Int, startNS: String, endNS: String,
                hostSecondsBits: UInt64?, samplePosition: Int64?, sampleRateBits: UInt64,
                presentationSecondsBits: UInt64?, receivedUptimeBits: UInt64) {
        self.frameStart = frameStart; self.frameEnd = frameEnd; self.mappingRevision = mappingRevision
        self.startNS = startNS; self.endNS = endNS; self.hostSecondsBits = hostSecondsBits
        self.samplePosition = samplePosition; self.sampleRateBits = sampleRateBits
        self.presentationSecondsBits = presentationSecondsBits; self.receivedUptimeBits = receivedUptimeBits
    }
}
public enum ArchiveDelta: Codable, Equatable, Sendable {
    case sessionBootstrap(ArchiveSessionBootstrap)
    case notesVersion(revision: UInt64, text: String, savedAtReferenceBits: UInt64)
    case segmentPresentation(segmentID: String, sourceLanguage: String?, insertionIndex: UInt64)
    case captureInitialized(ArchiveCaptureIdentity)
    case captureState(attemptID: String, revision: UInt64, state: ArchiveCaptureState)
    case captureTask(attemptID: String, streamID: String, segmentID: String, firstObservedBy: String, finalObserved: Bool)
    case captureSourceBlock(attemptID: String, segmentID: String, block: ArchiveCaptureSourceBlock)
    case sessionOpened(title: String)
    case sessionMetadataRevision(revision: UInt64, title: String, tags: [String])
    case sessionClosed(requiredCommitSequence: UInt64)
    case attemptBegan(requiresTerminalCoverage: Bool)
    case attemptEnded(outcome: ArchiveAttemptOutcome, requiredCommitSequence: UInt64)
    case notesRevision(revision: UInt64, text: String)
    /// Logical deletion record. It never removes the session entity, its revisions or its journal:
    /// the identity stays in the archive and only the active view hides it.
    case sessionTombstone(recordID: String, deletedAtReferenceBits: UInt64, actorKind: String, reason: String)
    /// Typed material in ordered text chunks. A material is only complete once chunk `chunkCount - 1` is
    /// acknowledged; an incomplete material is a real, visible state and is never presented as full text.
    /// Chunks of one material can span submissions (the per-record payload bound is smaller than the file cap),
    /// so no reader may treat a single chunk as the whole material.
    case materialChunk(materialID: String, fileName: String, sha256: String, importedAtReferenceBits: UInt64,
                       chunkIndex: UInt64, chunkCount: UInt64, text: String)
    // Existing authoritative SpeechCore wire bytes and sequence; never allocated by this library.
    case speechEvent(eventSequence: UInt64, wireData: Data)
    case sourceRevision(segmentID: String, revision: UInt64, eventSequence: UInt64, wireData: Data)
    case translationRevision(translationID: String, revision: UInt64, sourceSegmentID: String, sourceRevision: UInt64, eventSequence: UInt64, wireData: Data)
    case canonicalBatch([CanonicalObservation])
}
public struct ArchiveSubmission: Codable, Equatable, Sendable {
    public let id: UUID, expectedHead: UInt64, fence: ArchiveFence, deltas: [ArchiveDelta], durability: ArchiveDurability
    public init(id: UUID = UUID(), expectedHead: UInt64, fence: ArchiveFence, deltas: [ArchiveDelta], durability: ArchiveDurability = .readback) {
        self.id = id; self.expectedHead = expectedHead; self.fence = fence; self.deltas = deltas; self.durability = durability
    }
}
public struct ArchiveRecord: Codable, Equatable, Sendable {
    public let schemaVersion: Int, commitSequence: UInt64, submission: ArchiveSubmission
    init(_ request: ArchiveSubmission) throws {
        guard request.expectedHead < UInt64.max else { throw ArchiveFailure.sequenceOverflow }
        schemaVersion = 1; commitSequence = request.expectedHead + 1; submission = request
    }
}
public struct ArchiveToken: Equatable, Sendable {
    public let submissionID: UUID, plannedCommitSequence: UInt64, fence: ArchiveFence
}
public struct ArchiveAcknowledgement: Equatable, Sendable {
    public let token: ArchiveToken, alreadyPresent: Bool, durability: ArchiveDurability
    public func matches(_ pending: ArchiveToken, activeFence: ArchiveFence) -> Bool { token == pending && token.fence == activeFence }
}
public struct ArchiveWatermark: Equatable, Sendable {
    public let confirmedHead: UInt64, fsyncedHead: UInt64
}
public struct ArchiveTail: Equatable, Sendable {
    public let offset: UInt64, bytes: Data
}
public struct ArchiveRecovery: Sendable {
    public let records: [ArchiveRecord], head: UInt64, incompleteTail: ArchiveTail?, unfinishedAttempts: [ArchiveFence]
    // Unfinished attempts are interrupted/incomplete views; no synthetic persisted record or seq is created.
    public let requiresExplicitRecovery: Bool
}
public struct ArchiveWriterStatus: Sendable {
    public let pendingCount: Int, reservedBytes: Int, confirmedHead: UInt64, fsyncedHead: UInt64
    public let blocked: ArchiveFailure?, closing: Bool, closed: Bool
}
public enum ArchiveFaultPoint: String, Sendable {
    case beforeEncode, beforeWrite, afterPartialWrite, afterWrite, beforeReadback, beforeAcknowledgement
    case beforeFsync, beforeSnapshotWrite, afterSnapshotWrite
}
public enum ArchiveFailure: Error, Equatable, Sendable {
    case invalidLimits, invalidInput(String), sequenceOverflow, busy, closed, legacyMigrationRequired
    case queueFull, recordTooLarge(actual: Int, limit: Int), replayLimit
    case conflict(expected: UInt64, actual: UInt64), identityConflict(UUID), fence(String), revision(String)
    case incompleteTail(offset: UInt64, bytes: Int), corrupt(offset: UInt64, reason: String), unsupportedSchema(Int)
    case io(String, Int32), acknowledgementFailed(String), injected(ArchiveFaultPoint)
}
public struct ArchiveLimits: Sendable {
    public let maximumPendingCount: Int, maximumPendingBytes: Int, maximumEncodedRecordBytes: Int
    public let maximumPayloadBytes: Int, maximumStringUTF8Bytes: Int, maximumCanonicalBatchCount: Int
    public let maximumFieldsPerObservation: Int, maximumDeltasPerCommit: Int, maximumReplayBytes: Int, maximumReplayRecords: Int
    public let maximumMetadataTags: Int
    public init(maximumPendingCount: Int = 32, maximumPendingBytes: Int = 8 * 1024 * 1024,
                maximumEncodedRecordBytes: Int = 256 * 1024, maximumPayloadBytes: Int = 24 * 1024,
                maximumStringUTF8Bytes: Int = 16 * 1024, maximumCanonicalBatchCount: Int = 128,
                maximumFieldsPerObservation: Int = 128, maximumDeltasPerCommit: Int = 256,
                maximumReplayBytes: Int = 64 * 1024 * 1024, maximumReplayRecords: Int = 100_000,
                maximumMetadataTags: Int = 128) {
        self.maximumPendingCount = maximumPendingCount; self.maximumPendingBytes = maximumPendingBytes
        self.maximumEncodedRecordBytes = maximumEncodedRecordBytes; self.maximumPayloadBytes = maximumPayloadBytes
        self.maximumStringUTF8Bytes = maximumStringUTF8Bytes; self.maximumCanonicalBatchCount = maximumCanonicalBatchCount
        self.maximumFieldsPerObservation = maximumFieldsPerObservation; self.maximumDeltasPerCommit = maximumDeltasPerCommit
        self.maximumReplayBytes = maximumReplayBytes; self.maximumReplayRecords = maximumReplayRecords
        self.maximumMetadataTags = maximumMetadataTags
    }
    func validate() throws {
        guard [maximumPendingCount, maximumPendingBytes, maximumEncodedRecordBytes, maximumPayloadBytes,
               maximumStringUTF8Bytes, maximumCanonicalBatchCount, maximumFieldsPerObservation,
               maximumDeltasPerCommit, maximumReplayBytes, maximumReplayRecords].allSatisfy({ $0 > 0 }),
              maximumEncodedRecordBytes >= 4096, maximumEncodedRecordBytes <= 64 * 1024 * 1024,
              maximumPendingBytes >= maximumEncodedRecordBytes, maximumPendingBytes <= 512 * 1024 * 1024,
              maximumPayloadBytes <= 8 * 1024 * 1024, maximumStringUTF8Bytes <= 8 * 1024 * 1024,
              maximumCanonicalBatchCount <= 65536, maximumFieldsPerObservation <= 4096,
              maximumDeltasPerCommit <= 65536, maximumReplayRecords <= 1_000_000,
              maximumMetadataTags > 0, maximumMetadataTags <= 65536,
              maximumReplayBytes <= 1024 * 1024 * 1024 else { throw ArchiveFailure.invalidLimits }
    }
    // Conservative closed-grammar reservation, not an encoded byte measurement or heap statistic.
    // UTF8 string escaping <=6x, outer base64 <=4/3x; raw Data has <=(4/3)^2 growth.
    public func reservation(_ request: ArchiveSubmission) throws -> Int {
        guard !request.deltas.isEmpty, request.deltas.count <= maximumDeltasPerCommit,
              request.fence.isSession || request.fence.isAttempt else { throw ArchiveFailure.invalidInput("delta/fence shape") }
        var raw = 0, fields = 0, observations = 0, metadataTags = 0
        func add(_ n: Int) throws {
            let sum = raw.addingReportingOverflow(n)
            guard !sum.overflow, sum.partialValue <= maximumPayloadBytes else { throw ArchiveFailure.invalidInput("payload bytes") }
            raw = sum.partialValue
        }
        func text(_ s: String, identifier: Bool = false) throws {
            let n = s.utf8.count
            guard n <= maximumStringUTF8Bytes, !identifier || (!s.isEmpty && n <= 256 && !s.contains("\0")) else { throw ArchiveFailure.invalidInput("string/identifier") }
            try add(n)
        }
        try text(request.fence.sessionID, identifier: true)
        if let attempt = request.fence.attemptID { try text(attempt, identifier: true) }
        for delta in request.deltas {
            switch delta {
            case .sessionBootstrap(let value):
                guard Double(bitPattern: value.createdAtReferenceBits).isFinite, value.tags.count <= maximumMetadataTags,
                      metadataTags <= maximumMetadataTags - value.tags.count else { throw ArchiveFailure.invalidInput("bootstrap date/tags") }
                metadataTags += value.tags.count
                try text(value.title); try text(value.initialNotes)
                for tag in value.tags { try text(tag) }; fields += value.tags.count + 3
            case .notesVersion(_, let value, let date):
                guard Double(bitPattern: date).isFinite else { throw ArchiveFailure.invalidInput("note date") }; try text(value); fields += 2
            case .segmentPresentation(let id, let language, _):
                try text(id, identifier: true); if let language { try text(language) }; fields += 2
            case .captureInitialized(let identity):
                for id in [identity.id, identity.channelID] { try text(id, identifier: true) }
                for value in [identity.streamID, identity.segmentID, identity.locale] { try text(value) }; fields += 5
                for value in [identity.engineVersion, identity.modelVersion, identity.sourceKind, identity.sourceURL].compactMap({ $0 }) { try text(value); fields += 1 }
            case .captureState(let id, _, let value):
                try text(id, identifier: true); try text(value.lifecycle); try text(value.streamID); try text(value.segmentID)
                for value in [value.failure, value.mode, value.generationID].compactMap({ $0 }) { try text(value) }
                guard value.appendedHistory.count <= maximumDeltasPerCommit else { throw ArchiveFailure.invalidInput("history batch") }
                for entry in value.appendedHistory { try text(entry) }; fields += value.appendedHistory.count + 10
            case .captureTask(let id, let stream, let segment, let observed, _):
                for id in [id, stream, segment] { try text(id, identifier: true) }; try text(observed); fields += 5
            case .captureSourceBlock(let id, let segment, let block):
                try text(id, identifier: true); try text(segment, identifier: true); try text(block.startNS); try text(block.endNS); fields += 12
            case .sessionOpened(let title): try text(title)
            case .sessionMetadataRevision(_, let title, let tags):
                guard tags.count <= maximumMetadataTags, metadataTags <= maximumMetadataTags - tags.count else { throw ArchiveFailure.invalidInput("metadata tag count") }
                metadataTags += tags.count
                try text(title)
                for tag in tags { try text(tag) }
                fields += tags.count // Reserve JSON array delimiters even for repeated empty tags.
            case .notesRevision(_, let value): try text(value)
            case .sessionTombstone(let record, let bits, let actor, let reason):
                guard Double(bitPattern: bits).isFinite, !record.isEmpty else { throw ArchiveFailure.invalidInput("tombstone identity/date") }
                try text(record, identifier: true); try text(actor, identifier: true); try text(reason); fields += 4
            case .materialChunk(let id, let fileName, let sha, let bits, _, let chunkCount, let value):
                // Identity is validated at admission; the ordering/continuity invariant is a semantic guard.
                guard !id.isEmpty, !fileName.isEmpty, sha.count == 64, chunkCount > 0,
                      Double(bitPattern: bits).isFinite else { throw ArchiveFailure.invalidInput("material identity/date") }
                try text(id, identifier: true); try text(fileName); try text(sha, identifier: true); try text(value); fields += 6
            case .speechEvent(_, let data): guard !data.isEmpty else { throw ArchiveFailure.invalidInput("empty wire") }; try add(data.count)
            case .sourceRevision(let segment, _, _, let data): try text(segment, identifier: true); guard !data.isEmpty else { throw ArchiveFailure.invalidInput("empty wire") }; try add(data.count)
            case .translationRevision(let id, _, let segment, _, _, let data): try text(id, identifier: true); try text(segment, identifier: true); guard !data.isEmpty else { throw ArchiveFailure.invalidInput("empty wire") }; try add(data.count)
            case .canonicalBatch(let batch):
                guard !batch.isEmpty, batch.count <= maximumCanonicalBatchCount else { throw ArchiveFailure.invalidInput("canonical batch count") }
                observations += batch.count
                guard observations <= maximumCanonicalBatchCount else { throw ArchiveFailure.invalidInput("total canonical batch count") }
                for observation in batch {
                    guard !observation.fields.isEmpty, observation.fields.count <= maximumFieldsPerObservation else { throw ArchiveFailure.invalidInput("canonical field count") }
                    fields += observation.fields.count
                    for (key, scalar) in observation.fields {
                        try text(key, identifier: true)
                        if case .string(let value) = scalar { try text(value) } else { try add(scalar.inputBytes) }
                    }
                }
            case .attemptEnded(let outcome, _): if case .incomplete(let reason) = outcome { try text(reason) }
            default: break
            }
        }
        let product = raw.multipliedReportingOverflow(by: 8)
        let overhead = request.deltas.count * 256 + fields * 128 + observations * 128 + 4096
        let bound = product.partialValue.addingReportingOverflow(overhead)
        guard !product.overflow, !bound.overflow, bound.partialValue <= maximumEncodedRecordBytes else {
            throw ArchiveFailure.recordTooLarge(actual: bound.partialValue, limit: maximumEncodedRecordBytes)
        }
        return bound.partialValue
    }
}
