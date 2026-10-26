import Foundation
import AudioClock

public enum CanonicalClockError: Error, Equatable, Sendable {
    case invalidRate, invalidFormat, invalidRevision, invalidFrameCount, invalidNativePosition
    case invalidTimestamp, overflow, unrepresentableNanosecondRange, invalidBudget, invalidTaskRange, epochIdentityReused
}

/// Float seconds -> integer ns uses nearest, ties away from zero. No clamping.
/// The upper comparison is strict because Double(UInt64.max) rounds to 2^64.
public enum TimestampConversion {
    public static func nanoseconds(seconds: Double) throws -> UInt64 {
        guard seconds.isFinite, seconds >= 0 else { throw CanonicalClockError.invalidTimestamp }
        let scaled = seconds * 1_000_000_000
        let rounded = scaled.rounded(.toNearestOrAwayFromZero)
        guard rounded.isFinite, rounded >= 0, rounded < 18_446_744_073_709_551_616.0 else {
            throw CanonicalClockError.invalidTimestamp
        }
        return UInt64(rounded)
    }
    public static func integralRate(_ value: Double) throws -> Int64 {
        guard value.isFinite, value > 0, value.rounded(.towardZero) == value,
              value < 9_223_372_036_854_775_808.0 else { throw CanonicalClockError.invalidRate }
        return Int64(value)
    }
}

public struct AudioFormatIdentity: Equatable, Sendable {
    public let sampleRate: Int64
    public let channelCount: UInt32
    /// Caller supplies stable PCM encoding/interleaving identity; never inferred.
    public let encoding: String
    public init(sampleRate: Int64, channelCount: UInt32, encoding: String) {
        self.sampleRate = sampleRate; self.channelCount = channelCount; self.encoding = encoding
    }
}

/// Mirrors SourceTimestamp's scalar types without importing the capture/device module.
/// Adapters must copy the original fields. Receipt uptime never anchors or detects steps.
public struct RawAudioObservation: Equatable, Sendable {
    public let source: String
    public let hostSeconds: Double?
    public let samplePosition: Int64?
    public let sampleRate: Double
    public let presentationSeconds: Double?
    public let receivedUptime: Double
    public init(source: String, hostSeconds: Double?, samplePosition: Int64?, sampleRate: Double,
                presentationSeconds: Double?, receivedUptime: Double) {
        self.source = source; self.hostSeconds = hostSeconds; self.samplePosition = samplePosition
        self.sampleRate = sampleRate; self.presentationSeconds = presentationSeconds
        self.receivedUptime = receivedUptime
    }
}

public struct EpochAnchor: Equatable, Sendable {
    public enum Provenance: String, Sendable { case sourcePTS, sourceHost, callerDeclared }
    public enum Basis: String, Sendable { case nominalFromEpochAnchor }
    public let epochID: UUID
    public let channel: String
    public let startNs: UInt64
    public let provenance: Provenance
    public let basis: Basis = .nominalFromEpochAnchor
    public let format: AudioFormatIdentity
    public let mappingRevision: UInt64
    public let nativeSamplePosition: Int64?
    public init(epochID: UUID, channel: String, startNs: UInt64, provenance: Provenance,
                format: AudioFormatIdentity, mappingRevision: UInt64, nativeSamplePosition: Int64? = nil) {
        self.epochID = epochID; self.channel = channel; self.startNs = startNs; self.provenance = provenance
        self.format = format; self.mappingRevision = mappingRevision; self.nativeSamplePosition = nativeSamplePosition
    }
}

public struct DiscontinuityPolicy: Equatable, Sendable {
    /// Independent caller configuration, never a measured hardware accuracy claim.
    public let maximumTimestampStepNs: UInt64
    public init(maximumTimestampStepNs: UInt64) { self.maximumTimestampStepNs = maximumTimestampStepNs }
}

public enum Discontinuity: Equatable, Sendable {
    case nativeGap(expected: Int64, actual: Int64)
    case nativePositionAvailabilityChanged
    case formatChanged(expected: AudioFormatIdentity, actual: AudioFormatIdentity)
    case timestampBasisChanged
    case explicitStepGap(stepNs: UInt64)
    case explicitStepOverlap(stepNs: UInt64)
    case callerDeclaredReset
}

public struct ObservationDiagnostic: Equatable, Sendable {
    public enum TimestampBasis: String, Sendable { case presentation, host }
    public let timestampBasis: TimestampBasis?
    public let observedStartNs: UInt64?
    public let residualNs: Int64?
    public let stepErrorNs: Int64?
    /// Endpoint slope since first accepted same-basis observation. Statistics only;
    /// nil until >= 1 s nominal separation. Not calibration or drift correction.
    public let estimatedPPM: Double?
}

public struct CanonicalAudioBlock: Equatable, Sendable {
    public let anchor: EpochAnchor
    public let globalFrameStart: UInt64
    public let globalFrameEnd: UInt64
    public let startNs: UInt64
    public let endNs: UInt64
    public let rawObservation: RawAudioObservation
    public let diagnostic: ObservationDiagnostic
}

public enum BlockMappingResult: Equatable, Sendable {
    case accepted(CanonicalAudioBlock)
    /// No state was committed. Caller may explicitly begin a new epoch and retry.
    case requiresNewEpoch(Discontinuity)
}

public struct EpochGapMarker: Equatable, Sendable {
    public let previousEpoch: UUID
    public let nextEpoch: UUID
    public let previousEndNs: UInt64
    public let nextStartNs: UInt64
    public let reason: Discontinuity
    /// Can be negative (overlap). It is a declared nominal boundary difference.
    public let nominalBoundaryDifferenceNs: Int64
}

/// Task identity describes the epoch-global partition, never stream-local index.
public struct TaskIdentity: Equatable, Sendable {
    public let epochID: UUID
    public let channel: String
    public let partitionIndex: UInt64
    public let partitionStartGlobalFrame: UInt64
    public let taskBudget: UInt64
}
public struct TaskRange: Equatable, Sendable {
    public let identity: TaskIdentity
    public let globalFrameStart: UInt64
    public let globalFrameEnd: UInt64
    public let localFrameStart: UInt64
    public let localFrameEnd: UInt64
    public let startNs: UInt64
    public let endNs: UInt64
    public let mappingRevision: UInt64
    public let basis: EpochAnchor.Basis
}

/// No history, PCM, timer, reconnect or capture. A caller owns returned metadata
/// and its bounded storage policy. State is O(1): first/previous observations only.
public struct CanonicalBlockMapper: Sendable {
    public private(set) var anchor: EpochAnchor
    public let policy: DiscontinuityPolicy
    public var globalFrameCount: UInt64 { integerMapper.frameCount }
    private var integerMapper: SampleClockMapper
    private var nativeMode: Bool?
    private var expectedNative: Int64?
    private struct Point: Sendable {
        let frame: UInt64
        let nominalNs: UInt64
        let observedNs: UInt64
        let basis: ObservationDiagnostic.TimestampBasis
    }
    private var previous: Point?
    private var first: Point?

    public init(anchor: EpochAnchor, policy: DiscontinuityPolicy) throws {
        self.anchor = anchor; self.policy = policy
        integerMapper = try Self.makeIntegerMapper(anchor)
        nativeMode = anchor.nativeSamplePosition == nil ? nil : true
        expectedNative = anchor.nativeSamplePosition
    }

    private static func makeIntegerMapper(_ anchor: EpochAnchor) throws -> SampleClockMapper {
        guard anchor.format.sampleRate > 0 else { throw CanonicalClockError.invalidRate }
        guard anchor.format.channelCount > 0, !anchor.format.encoding.isEmpty, !anchor.channel.isEmpty else {
            throw CanonicalClockError.invalidFormat
        }
        guard anchor.mappingRevision > 0 else { throw CanonicalClockError.invalidRevision }
        if let native = anchor.nativeSamplePosition, native < 0 { throw CanonicalClockError.invalidNativePosition }
        return try SampleClockMapper(sampleRate: anchor.format.sampleRate, mappingRevision: anchor.mappingRevision,
            anchor: SourceAnchor(startNs: anchor.startNs, basis: .callerDeclaredPerSourceTimeline))
    }

    public func boundary(globalFrame: UInt64) throws -> UInt64 {
        try Self.boundary(anchor: anchor, frame: globalFrame)
    }
    private static func boundary(anchor: EpochAnchor, frame: UInt64) throws -> UInt64 {
        // Same full-width rational integer arithmetic as AudioClock. Needed also
        // for arbitrary task split boundaries (the old mapper exposes only blocks).
        let product = frame.multipliedFullWidth(by: 1_000_000_000)
        let divisor = UInt64(anchor.format.sampleRate)
        guard product.high < divisor else { throw CanonicalClockError.overflow }
        let elapsed = divisor.dividingFullWidth(product).quotient
        let sum = anchor.startNs.addingReportingOverflow(elapsed)
        guard !sum.overflow else { throw CanonicalClockError.overflow }
        return sum.partialValue
    }
    private static func signedDifference(_ lhs: UInt64, _ rhs: UInt64) throws -> Int64 {
        let magnitude = lhs >= rhs ? lhs - rhs : rhs - lhs
        guard magnitude <= UInt64(Int64.max) else { throw CanonicalClockError.overflow }
        return lhs >= rhs ? Int64(magnitude) : -Int64(magnitude)
    }

    public mutating func map(frameCount: UInt64, format: AudioFormatIdentity,
                             raw: RawAudioObservation) throws -> BlockMappingResult {
        guard frameCount > 0, frameCount <= UInt64(Int64.max) else { throw CanonicalClockError.invalidFrameCount }
        guard format.sampleRate > 0, try TimestampConversion.integralRate(raw.sampleRate) == format.sampleRate else {
            throw CanonicalClockError.invalidRate
        }
        guard format.channelCount > 0, !format.encoding.isEmpty else { throw CanonicalClockError.invalidFormat }
        if let native = raw.samplePosition, native < 0 { throw CanonicalClockError.invalidNativePosition }
        // Validate even unused timestamps; never mutate or replace raw fields.
        let pts = try raw.presentationSeconds.map { try TimestampConversion.nanoseconds(seconds: $0) }
        let host = try raw.hostSeconds.map { try TimestampConversion.nanoseconds(seconds: $0) }
        _ = try TimestampConversion.nanoseconds(seconds: raw.receivedUptime)
        guard format == anchor.format else { return .requiresNewEpoch(.formatChanged(expected: anchor.format, actual: format)) }
        let hasNative = raw.samplePosition != nil
        if let nativeMode, nativeMode != hasNative { return .requiresNewEpoch(.nativePositionAvailabilityChanged) }
        var nextNative: Int64?
        if let native = raw.samplePosition {
            if let expectedNative, native != expectedNative { return .requiresNewEpoch(.nativeGap(expected: expectedNative, actual: native)) }
            let sum = native.addingReportingOverflow(Int64(frameCount))
            guard !sum.overflow else { throw CanonicalClockError.overflow }
            nextNative = sum.partialValue
        }
        var candidate = integerMapper
        let range: SampleTimeRange
        do {
            range = try candidate.map(sampleRate: format.sampleRate, frameCount: Int64(frameCount))
        } catch AudioClockError.overflow {
            throw CanonicalClockError.overflow
        } catch AudioClockError.unrepresentableNanosecondRange {
            throw CanonicalClockError.unrepresentableNanosecondRange
        }
        let observed = pts ?? host
        let basis: ObservationDiagnostic.TimestampBasis? = pts != nil ? .presentation : (host != nil ? .host : nil)
        var residual: Int64?
        var step: Int64?
        var ppm: Double?
        var point: Point?
        if let observed, let basis {
            residual = try Self.signedDifference(observed, range.startNs)
            point = Point(frame: range.frameStart, nominalNs: range.startNs, observedNs: observed, basis: basis)
            if let previous {
                if previous.basis != basis { return .requiresNewEpoch(.timestampBasisChanged) }
                let delta = try Self.signedDifference(observed, previous.observedNs)
                let expected = try Self.signedDifference(range.startNs, previous.nominalNs)
                let error = delta.subtractingReportingOverflow(expected)
                guard !error.overflow else { throw CanonicalClockError.overflow }
                step = error.partialValue
                // Native sample continuity takes precedence over raw clock steps.
                if !hasNative, error.partialValue.magnitude > policy.maximumTimestampStepNs {
                    return .requiresNewEpoch(error.partialValue >= 0
                        ? .explicitStepGap(stepNs: error.partialValue.magnitude)
                        : .explicitStepOverlap(stepNs: error.partialValue.magnitude))
                }
            }
            if let first, first.basis == basis {
                let nominalDelta = range.startNs - first.nominalNs
                if nominalDelta >= 1_000_000_000 {
                    let observedDelta = try Self.signedDifference(observed, first.observedNs)
                    ppm = (Double(observedDelta) / Double(nominalDelta) - 1) * 1_000_000
                }
            }
        }
        let block = CanonicalAudioBlock(anchor: anchor, globalFrameStart: range.frameStart, globalFrameEnd: range.frameEnd,
            startNs: range.startNs, endNs: range.endNs, rawObservation: raw,
            diagnostic: ObservationDiagnostic(timestampBasis: basis, observedStartNs: observed,
                residualNs: residual, stepErrorNs: step, estimatedPPM: ppm))
        // Single commit after all potentially failing operations.
        integerMapper = candidate; nativeMode = hasNative; expectedNative = nextNative
        previous = point
        if first == nil { first = point }
        return .accepted(block)
    }

    /// Caller explicitly authorizes every epoch switch by calling this method.
    /// Validates the replacement and marker before committing; no auto reconnect.
    public mutating func beginEpoch(_ next: EpochAnchor, reason: Discontinuity) throws -> EpochGapMarker {
        guard next.epochID != anchor.epochID else { throw CanonicalClockError.epochIdentityReused }
        let replacement = try CanonicalBlockMapper(anchor: next, policy: policy)
        let end = try boundary(globalFrame: globalFrameCount)
        let difference = try Self.signedDifference(next.startNs, end)
        let marker = EpochGapMarker(previousEpoch: anchor.epochID, nextEpoch: next.epochID,
            previousEndNs: end, nextStartNs: next.startNs, reason: reason, nominalBoundaryDifferenceNs: difference)
        self = replacement
        return marker
    }

    /// Streams task fragments to caller storage; library never builds a history array.
    /// Callback failures have no mapper state effects (this method is nonmutating).
    public func forEachTaskRange(in block: CanonicalAudioBlock, taskBudget: UInt64,
                                 _ body: (TaskRange) throws -> Void) throws {
        guard taskBudget > 0 else { throw CanonicalClockError.invalidBudget }
        guard block.anchor == anchor, block.globalFrameStart < block.globalFrameEnd,
              block.globalFrameEnd <= globalFrameCount else { throw CanonicalClockError.invalidTaskRange }
        var cursor = block.globalFrameStart
        while cursor < block.globalFrameEnd {
            let index = cursor / taskBudget
            let partitionStart = cursor - cursor % taskBudget
            let available = taskBudget - (cursor - partitionStart)
            let length = min(available, block.globalFrameEnd - cursor)
            let end = cursor + length // bounded by checked accepted block end
            let range = TaskRange(identity: TaskIdentity(epochID: anchor.epochID, channel: anchor.channel,
                    partitionIndex: index, partitionStartGlobalFrame: partitionStart, taskBudget: taskBudget),
                globalFrameStart: cursor, globalFrameEnd: end, localFrameStart: cursor - partitionStart,
                localFrameEnd: end - partitionStart, startNs: try boundary(globalFrame: cursor),
                endNs: try boundary(globalFrame: end), mappingRevision: anchor.mappingRevision, basis: anchor.basis)
            try body(range)
            cursor = end
        }
    }
}
