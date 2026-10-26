import Foundation
import AppleOfflineSpeech
import CanonicalAudioClock
import RotatingSpeechSession
import MeetingCopilotAudioCapture
import MeetingCopilotPCMBridge

// Archive-only scalar projections of actual public output. No mapper or event sequence.
public struct LocalRawObservation: Codable, Equatable {
    public let source: String
    public let hostSeconds: Double?, samplePosition: Int64?, sampleRate: Double
    public let presentationSeconds: Double?, receivedUptime: Double
    public init(_ r: RawAudioObservation) {
        source = r.source; hostSeconds = r.hostSeconds; samplePosition = r.samplePosition
        sampleRate = r.sampleRate; presentationSeconds = r.presentationSeconds; receivedUptime = r.receivedUptime
    }
    public init(_ r: SourceTimestamp) {
        source = r.source.rawValue; hostSeconds = r.hostSeconds; samplePosition = r.samplePosition
        sampleRate = r.sampleRate; presentationSeconds = r.presentationSeconds; receivedUptime = r.receivedUptime
    }
    private enum CodingKeys: String, CodingKey {
        case source, hostSeconds, samplePosition, sampleRate, presentationSeconds, receivedUptime
    }
    // Finite values keep JSON numbers; nonfinite raw observations use lossless tagged bits.
    // Default ArchiveStore/finite-mode JSON strategies remain unchanged.
    private static let bitPrefix = "ieee754-binary64:"
    private static func encodeScalar(_ value: Double, key: CodingKeys, into c: inout KeyedEncodingContainer<CodingKeys>) throws {
        if value.isFinite { try c.encode(value, forKey: key) }
        else { try c.encode(bitPrefix + String(value.bitPattern, radix: 16), forKey: key) }
    }
    private static func decodeScalar(_ key: CodingKeys, from c: KeyedDecodingContainer<CodingKeys>) throws -> Double {
        if let number = try? c.decode(Double.self, forKey: key), number.isFinite { return number }
        let tag = try c.decode(String.self, forKey: key)
        guard tag.hasPrefix(bitPrefix), let bits = UInt64(tag.dropFirst(bitPrefix.count), radix: 16), !Double(bitPattern: bits).isFinite else {
            throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "Invalid nonfinite raw IEEE-754 payload")
        }
        return Double(bitPattern: bits)
    }
    private static func decodeOptionalScalar(_ key: CodingKeys, from c: KeyedDecodingContainer<CodingKeys>) throws -> Double? {
        guard c.contains(key), try !c.decodeNil(forKey: key) else { return nil }
        return try decodeScalar(key, from: c)
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(String.self, forKey: .source)
        hostSeconds = try Self.decodeOptionalScalar(.hostSeconds, from: c)
        samplePosition = try c.decodeIfPresent(Int64.self, forKey: .samplePosition)
        sampleRate = try Self.decodeScalar(.sampleRate, from: c)
        presentationSeconds = try Self.decodeOptionalScalar(.presentationSeconds, from: c)
        receivedUptime = try Self.decodeScalar(.receivedUptime, from: c)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(source, forKey: .source)
        if let hostSeconds { try Self.encodeScalar(hostSeconds, key: .hostSeconds, into: &c) }
        try c.encodeIfPresent(samplePosition, forKey: .samplePosition)
        try Self.encodeScalar(sampleRate, key: .sampleRate, into: &c)
        if let presentationSeconds { try Self.encodeScalar(presentationSeconds, key: .presentationSeconds, into: &c) }
        try Self.encodeScalar(receivedUptime, key: .receivedUptime, into: &c)
    }
    private static func equalScalar(_ lhs: Double, _ rhs: Double) -> Bool {
        if lhs.isFinite && rhs.isFinite { return lhs == rhs }
        return lhs.bitPattern == rhs.bitPattern
    }
    private static func equalOptionalScalar(_ lhs: Double?, _ rhs: Double?) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none): return true
        case (.some(let left), .some(let right)): return equalScalar(left, right)
        default: return false
        }
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.source == rhs.source && equalOptionalScalar(lhs.hostSeconds, rhs.hostSeconds) &&
        lhs.samplePosition == rhs.samplePosition && equalScalar(lhs.sampleRate, rhs.sampleRate) &&
        equalOptionalScalar(lhs.presentationSeconds, rhs.presentationSeconds) && equalScalar(lhs.receivedUptime, rhs.receivedUptime)
    }
}
public struct LocalEpochAnchor: Codable, Equatable {
    public let epochID: UUID, channel: String, startNs: UInt64, provenance: String, basis: String
    public let sampleRate: Int64, channelCount: UInt32, encoding: String, mappingRevision: UInt64, nativeSamplePosition: Int64?
    public init(_ a: EpochAnchor) {
        epochID = a.epochID; channel = a.channel; startNs = a.startNs; provenance = a.provenance.rawValue; basis = a.basis.rawValue
        sampleRate = a.format.sampleRate; channelCount = a.format.channelCount; encoding = a.format.encoding
        mappingRevision = a.mappingRevision; nativeSamplePosition = a.nativeSamplePosition
    }
}
public struct LocalCanonicalBlock: Codable, Equatable, Identifiable {
    public var id: UUID { blockID }
    public let blockID: UUID, anchor: LocalEpochAnchor
    public let globalFrameStart: UInt64, globalFrameEnd: UInt64, nominalStartNs: UInt64, nominalEndNs: UInt64
    public let rawObservation: LocalRawObservation
    public let timestampBasis: String?, observedStartNs: UInt64?, residualNs: Int64?, stepErrorNs: Int64?, estimatedPPM: Double?
    public init(id: UUID, block: CanonicalAudioBlock) {
        blockID = id; anchor = LocalEpochAnchor(block.anchor)
        globalFrameStart = block.globalFrameStart; globalFrameEnd = block.globalFrameEnd
        nominalStartNs = block.startNs; nominalEndNs = block.endNs; rawObservation = LocalRawObservation(block.rawObservation)
        timestampBasis = block.diagnostic.timestampBasis?.rawValue; observedStartNs = block.diagnostic.observedStartNs
        residualNs = block.diagnostic.residualNs; stepErrorNs = block.diagnostic.stepErrorNs; estimatedPPM = block.diagnostic.estimatedPPM
    }
    /// Copies the actual projection while retaining diagnostic IEEE-754 bits supplied by the log.
    public init(copying actual: Self, estimatedPPM: Double?) {
        blockID = actual.blockID; anchor = actual.anchor
        globalFrameStart = actual.globalFrameStart; globalFrameEnd = actual.globalFrameEnd
        nominalStartNs = actual.nominalStartNs; nominalEndNs = actual.nominalEndNs
        rawObservation = actual.rawObservation; timestampBasis = actual.timestampBasis
        observedStartNs = actual.observedStartNs; residualNs = actual.residualNs; stepErrorNs = actual.stepErrorNs
        self.estimatedPPM = estimatedPPM
    }
}
public struct LocalTaskCanonicalSpan: Codable, Equatable {
    public let blockID: UUID, epochID: UUID
    public let streamID: String, segmentID: String, taskStartGlobalFrame: UInt64
    public let globalFrameStart: UInt64, globalFrameEnd: UInt64, taskLocalFrameStart: Int, taskLocalFrameEnd: Int
    public let nominalStartNs: UInt64, nominalEndNs: UInt64, mappingRevision: UInt64, basis: String
    public init(_ s: RotatingTaskCanonicalSpan) {
        blockID = s.blockID; epochID = s.epochID; streamID = s.task.streamId; segmentID = s.task.segmentId
        taskStartGlobalFrame = s.taskStartGlobalFrame; globalFrameStart = s.globalFrameStart; globalFrameEnd = s.globalFrameEnd
        taskLocalFrameStart = s.taskLocalFrameStart; taskLocalFrameEnd = s.taskLocalFrameEnd
        nominalStartNs = s.nominalStartNs; nominalEndNs = s.nominalEndNs; mappingRevision = s.mappingRevision; basis = s.basis.rawValue
    }
}
public struct LocalCanonicalSettlement: Codable, Equatable, Identifiable {
    public var id: UUID { blockID }
    public let blockID: UUID, disposition: String, rawObservation: LocalRawObservation
    public let taskLocalRange: LocalCaptureBlock?, backendAccepted: Bool, ownerReturned: Bool, failure: String?
    public init(id: UUID, disposition: RotatingCanonicalDisposition, timestamp: SourceTimestamp, range: PCMSourceRange?, backendAccepted: Bool, ownerReturned: Bool, failure: RotatingSpeechFailure?) {
        blockID = id; self.disposition = String(describing: disposition); rawObservation = LocalRawObservation(timestamp)
        taskLocalRange = range.map { r in LocalCaptureBlock(frameStart: r.frameStart, frameEnd: r.frameEnd, mappingRevision: r.mappingRevision,
            startNS: String(r.startNs), endNS: String(r.endNs), hostSeconds: timestamp.hostSeconds,
            samplePosition: timestamp.samplePosition, sampleRate: timestamp.sampleRate, presentationSeconds: timestamp.presentationSeconds, receivedUptime: timestamp.receivedUptime) }
        self.backendAccepted = backendAccepted; self.ownerReturned = ownerReturned; self.failure = failure.map { String(describing: $0) }
    }
    public init(blockID: UUID, disposition: String, rawObservation: LocalRawObservation,
                taskLocalRange: LocalCaptureBlock?, backendAccepted: Bool, ownerReturned: Bool, failure: String?) {
        self.blockID = blockID; self.disposition = disposition; self.rawObservation = rawObservation
        self.taskLocalRange = taskLocalRange; self.backendAccepted = backendAccepted
        self.ownerReturned = ownerReturned; self.failure = failure
    }
}
public struct LocalCanonicalQueue: Codable, Equatable {
    public let state: String, generationID: UUID?, failure: String?
    public let queuedBlocks: Int, queuedFrames: UInt64, queuedBytes: Int
    public let acceptedBlocks: UInt64, consumedBlocks: UInt64, releasedBlocks: UInt64
    public let staleRejections: UInt64, inactiveRejections: UInt64, overflowFailures: UInt64, invalidBlockFailures: UInt64, highWaterBlocks: Int
    public init(_ q: PCMQueueSnapshot) {
        state = String(describing: q.state); generationID = q.generation?.id; failure = q.failure.map { String(describing: $0) }
        queuedBlocks = q.queuedBlocks; queuedFrames = q.queuedFrames; queuedBytes = q.queuedBytes
        acceptedBlocks = q.statistics.acceptedBlocks; consumedBlocks = q.statistics.consumedBlocks; releasedBlocks = q.statistics.releasedBlocks
        staleRejections = q.statistics.staleRejections; inactiveRejections = q.statistics.inactiveRejections
        overflowFailures = q.statistics.overflowFailures; invalidBlockFailures = q.statistics.invalidBlockFailures; highWaterBlocks = q.statistics.highWaterBlocks
    }
}
public struct LocalCanonicalCoverage: Codable, Equatable {
    public let epochID: UUID?
    public let transferredBlocks: UInt64, transferredFrames: UInt64, mappedBlocks: UInt64, mappedFrames: UInt64
    public let recognitionConsumedBlocks: UInt64, recognitionConsumedFrames: UInt64
    public let rejectedBeforeMappingBlocks: UInt64, rejectedBeforeMappingFrames: UInt64, rejectedAfterMappingBlocks: UInt64, rejectedAfterMappingFrames: UInt64
    public let uncertainAfterMappingBlocks: UInt64, uncertainAfterMappingFrames: UInt64, backendAcceptedBlocks: UInt64, backendAcceptedFrames: UInt64, ownerReturnedBlocks: UInt64
    public let startedTasks: UInt64, validatedFinalTasks: UInt64, validatedFinalFrames: UInt64
    public let queue: LocalCanonicalQueue?, releasedWithoutTransferBlocks: UInt64?
    public let canonicalAccountingValid: Bool, queueAccountingValid: Bool, ownerQueueAccountingValid: Bool, completionCoverageValid: Bool
    public init(_ c: RotatingCanonicalCoverage) {
        epochID = c.epochID; transferredBlocks = c.transferredBlocks; transferredFrames = c.transferredFrames
        mappedBlocks = c.mappedBlocks; mappedFrames = c.mappedFrames
        recognitionConsumedBlocks = c.recognitionConsumedBlocks; recognitionConsumedFrames = c.recognitionConsumedFrames
        rejectedBeforeMappingBlocks = c.rejectedBeforeMappingBlocks; rejectedBeforeMappingFrames = c.rejectedBeforeMappingFrames
        rejectedAfterMappingBlocks = c.rejectedAfterMappingBlocks; rejectedAfterMappingFrames = c.rejectedAfterMappingFrames
        uncertainAfterMappingBlocks = c.uncertainAfterMappingBlocks; uncertainAfterMappingFrames = c.uncertainAfterMappingFrames
        backendAcceptedBlocks = c.backendAcceptedBlocks; backendAcceptedFrames = c.backendAcceptedFrames; ownerReturnedBlocks = c.ownerReturnedBlocks
        startedTasks = c.startedTasks; validatedFinalTasks = c.validatedFinalTasks; validatedFinalFrames = c.validatedFinalFrames
        queue = c.queue.map(LocalCanonicalQueue.init); releasedWithoutTransferBlocks = c.releasedWithoutTransferBlocks
        canonicalAccountingValid = c.canonicalAccountingValid; queueAccountingValid = c.queueAccountingValid; ownerQueueAccountingValid = c.ownerQueueAccountingValid; completionCoverageValid = c.completionCoverageValid
    }
}
public struct LocalCanonicalMetadata: Codable, Equatable {
    public var blocks: [LocalCanonicalBlock] = []
    public var associations: [LocalTaskCanonicalSpan] = []
    public var settlements: [LocalCanonicalSettlement] = []
    public var terminalCoverage: LocalCanonicalCoverage?
    public init() {}
}
