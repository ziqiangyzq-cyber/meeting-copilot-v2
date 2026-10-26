/// Failures leave a mapper unchanged. Start a new mapper after a source discontinuity.
public enum AudioClockError: Error, Equatable, Sendable {
    case missingAnchor
    case invalidSampleRate
    case invalidMappingRevision
    case unrepresentableNanosecondRange
    case invalidFrameCount
    case invalidNativeSamplePosition
    case sampleRateChanged(expected: Int64, actual: Int64)
    case nativePositionAvailabilityChanged
    case nativeSampleDiscontinuity(expected: Int64, actual: Int64)
    case nonmonotonicSourceTimestamp
    case overflow
}

/// The timestamp of frame zero in ONE source's declared clock domain.
/// The caller must establish that this timestamp corresponds to the first frame.
/// Receipt/arrival uptime is not a source timestamp and must not be used here.
public struct SourceAnchor: Equatable, Sendable {
    public enum Basis: Equatable, Sendable {
        /// A timestamp supplied by the capture source for its first sample.
        case nativeSourceTimestamp
        /// A caller-defined timeline for this source only. Does not establish
        /// synchronization with another source, wall time, or receipt uptime.
        case callerDeclaredPerSourceTimeline
    }

    public let startNs: UInt64
    public let basis: Basis
    /// If set, the first block must start at this native sample position.
    public let nativeSamplePosition: Int64?

    public init(startNs: UInt64, basis: Basis, nativeSamplePosition: Int64? = nil) {
        self.startNs = startNs
        self.basis = basis
        self.nativeSamplePosition = nativeSamplePosition
    }
}

/// Half-open cumulative frame and nanosecond boundaries for one PCM block.
/// Pass these values to the client's PCMSourceRange constructor. The caller
/// owns source/channel identity; this library deliberately has no speech dependency.
public struct SampleTimeRange: Equatable, Sendable {
    public let frameStart: UInt64
    public let frameEnd: UInt64
    public let startNs: UInt64
    public let endNs: UInt64
    public let mappingRevision: UInt64
    public let anchorBasis: SourceAnchor.Basis
}

/// A value-type mapper for exactly one channel/stream at one integral sample rate.
/// Do not share one instance between microphone and system capture, or channels.
/// Boundaries are anchor + floor(cumulativeFrames * 1_000_000_000 / sampleRate).
/// This is exact integer rational arithmetic, rounded downward only at output.
/// There is no clock synchronization, drift correction, or receipt-time inference.
public struct SampleClockMapper: Sendable {
    public let sampleRate: Int64
    public let mappingRevision: UInt64
    public let anchor: SourceAnchor
    public private(set) var frameCount: UInt64 = 0

    private var nativeMode: Bool?
    private var nextNativePosition: Int64?
    private var lastSourceTimestampNs: UInt64?

    /// A nil anchor is an explicit error, even when blocks have timestamps.
    /// After a gap/rate change, construct a new mapper with a new anchor and
    /// caller-chosen revision; cumulative frames then restart at zero.
    public init(sampleRate: Int64, mappingRevision: UInt64, anchor: SourceAnchor?) throws {
        guard sampleRate > 0 else { throw AudioClockError.invalidSampleRate }
        guard let anchor else { throw AudioClockError.missingAnchor }
        guard mappingRevision > 0 else { throw AudioClockError.invalidMappingRevision }
        if let native = anchor.nativeSamplePosition, native < 0 {
            throw AudioClockError.invalidNativeSamplePosition
        }
        self.sampleRate = sampleRate
        self.mappingRevision = mappingRevision
        self.anchor = anchor
        if let native = anchor.nativeSamplePosition {
            nativeMode = true
            nextNativePosition = native
        }
    }

    /// `frameCount` counts PCM frames (samples per channel), not interleaved scalars.
    /// Supply the current rate each time so a rate change cannot pass unnoticed.
    /// Native positions are optional, but their presence must remain consistent
    /// after the first successful block. Native positions must advance by frames.
    /// `sourceTimestampNs`, when present, is the source's timestamp at block start
    /// in the anchor's domain, NOT receivedUptime. Observations must be strictly
    /// increasing and at/after the anchor; they validate ordering only and do not
    /// re-anchor or correct drift. Omitted observations do not clear that check.
    /// The caller is responsible for the anchor's provenance and clock-domain match.
    public mutating func map(
        sampleRate: Int64,
        frameCount blockFrames: Int64,
        nativeSamplePosition: Int64? = nil,
        sourceTimestampNs: UInt64? = nil
    ) throws -> SampleTimeRange {
        guard sampleRate > 0 else { throw AudioClockError.invalidSampleRate }
        guard sampleRate == self.sampleRate else {
            throw AudioClockError.sampleRateChanged(expected: self.sampleRate, actual: sampleRate)
        }
        guard blockFrames > 0 else { throw AudioClockError.invalidFrameCount }
        if let nativeSamplePosition, nativeSamplePosition < 0 {
            throw AudioClockError.invalidNativeSamplePosition
        }
        let hasNative = nativeSamplePosition != nil
        if let nativeMode, nativeMode != hasNative {
            throw AudioClockError.nativePositionAvailabilityChanged
        }
        var followingNative: Int64?
        if let position = nativeSamplePosition {
            if let expected = nextNativePosition, position != expected {
                throw AudioClockError.nativeSampleDiscontinuity(expected: expected, actual: position)
            }
            let sum = position.addingReportingOverflow(blockFrames)
            guard !sum.overflow else { throw AudioClockError.overflow }
            followingNative = sum.partialValue
        }
        if let timestamp = sourceTimestampNs {
            guard timestamp >= anchor.startNs,
                  lastSourceTimestampNs.map({ timestamp > $0 }) ?? true else {
                throw AudioClockError.nonmonotonicSourceTimestamp
            }
        }
        let end = frameCount.addingReportingOverflow(UInt64(blockFrames))
        guard !end.overflow else { throw AudioClockError.overflow }
        let startNs = try boundary(frame: frameCount)
        let endNs = try boundary(frame: end.partialValue)
        guard startNs < endNs else { throw AudioClockError.unrepresentableNanosecondRange }
        let result = SampleTimeRange(
            frameStart: frameCount, frameEnd: end.partialValue,
            startNs: startNs, endNs: endNs,
            mappingRevision: mappingRevision, anchorBasis: anchor.basis
        )
        // Commit only after every validation and calculation succeeds.
        frameCount = end.partialValue
        nativeMode = hasNative
        nextNativePosition = followingNative
        if let timestamp = sourceTimestampNs { lastSourceTimestampNs = timestamp }
        return result
    }

    private func boundary(frame: UInt64) throws -> UInt64 {
        // 128-bit product prevents false overflow for long, representable streams.
        // dividingFullWidth requires quotient <= UInt64.max (high < divisor).
        let product = frame.multipliedFullWidth(by: 1_000_000_000)
        let divisor = UInt64(sampleRate)
        guard product.high < divisor else { throw AudioClockError.overflow }
        let elapsed = divisor.dividingFullWidth(product).quotient
        let sum = anchor.startNs.addingReportingOverflow(elapsed)
        guard !sum.overflow else { throw AudioClockError.overflow }
        return sum.partialValue
    }
}
