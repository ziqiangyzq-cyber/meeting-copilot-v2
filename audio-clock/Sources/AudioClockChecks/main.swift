import AudioClock

var checks = 0
@MainActor
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    checks += 1
    guard condition() else { fatalError("FAIL: \(label)") }
}
@MainActor
func rejects(_ expected: AudioClockError, _ label: String, _ action: () throws -> Void) {
    checks += 1
    do {
        try action()
        fatalError("FAIL: \(label): accepted invalid input")
    } catch {
        guard let actual = error as? AudioClockError, actual == expected else {
            fatalError("FAIL: \(label): unexpected \(error)")
        }
    }
}
func anchor(_ ns: UInt64 = 0, native: Int64? = nil) -> SourceAnchor {
    SourceAnchor(startNs: ns, basis: .callerDeclaredPerSourceTimeline, nativeSamplePosition: native)
}
func mapper(_ rate: Int64, _ ns: UInt64 = 0) throws -> SampleClockMapper {
    try SampleClockMapper(sampleRate: rate, mappingRevision: 7, anchor: anchor(ns))
}

// Single-frame blocks expose rounding accumulation bugs at 48 kHz.
for rate: Int64 in [16_000, 48_000, 44_100] {
    var clock = try mapper(rate, 123)
    var previousEnd: UInt64 = 123
    for frame in 0..<Int(rate) {
        let range = try clock.map(sampleRate: rate, frameCount: 1)
        check(range.frameStart == UInt64(frame), "cumulative start at \(rate)")
        check(range.frameEnd == UInt64(frame + 1), "cumulative end at \(rate)")
        check(range.startNs == previousEnd, "contiguous ns at \(rate)")
        check(range.endNs == 123 + UInt64(frame + 1) * 1_000_000_000 / UInt64(rate), "rational boundary at \(rate)")
        check(range.mappingRevision == 7 && range.anchorBasis == .callerDeclaredPerSourceTimeline, "metadata")
        previousEnd = range.endNs
    }
    check(previousEnd == 1_000_000_123, "exact one-second boundary")
    print("PASS: \(rate) Hz single-frame cumulative boundaries")
}

// Partition independence, native continuity, and monotonic source observations.
var native = try SampleClockMapper(sampleRate: 48_000, mappingRevision: 42,
    anchor: SourceAnchor(startNs: 900, basis: .nativeSourceTimestamp, nativeSamplePosition: 1_000))
let first = try native.map(sampleRate: 48_000, frameCount: 17, nativeSamplePosition: 1_000, sourceTimestampNs: 900)
let second = try native.map(sampleRate: 48_000, frameCount: 31, nativeSamplePosition: 1_017, sourceTimestampNs: 355_066)
check(first.frameStart == 0 && second.frameStart == 17 && second.frameEnd == 48, "block frame continuity")
check(first.endNs == second.startNs && second.endNs == 1_000_900, "block time continuity")
check(second.mappingRevision == 42 && second.anchorBasis == .nativeSourceTimestamp, "native anchor metadata")
var combined = try mapper(48_000, 900)
let whole = try combined.map(sampleRate: 48_000, frameCount: 48)
check(whole.endNs == second.endNs, "partition independence")
rejects(.nativeSampleDiscontinuity(expected: 1_048, actual: 1_049), "native gap") {
    _ = try native.map(sampleRate: 48_000, frameCount: 1, nativeSamplePosition: 1_049)
}
rejects(.nativeSampleDiscontinuity(expected: 1_048, actual: 1_047), "native backwards") {
    _ = try native.map(sampleRate: 48_000, frameCount: 1, nativeSamplePosition: 1_047)
}
rejects(.sampleRateChanged(expected: 48_000, actual: 16_000), "rate change") {
    _ = try native.map(sampleRate: 16_000, frameCount: 1, nativeSamplePosition: 1_048)
}
rejects(.nativePositionAvailabilityChanged, "missing native position") {
    _ = try native.map(sampleRate: 48_000, frameCount: 1)
}
for timestamp: UInt64 in [355_066, 355_065, 899] {
    rejects(.nonmonotonicSourceTimestamp, "nonmonotonic timestamp") {
        _ = try native.map(sampleRate: 48_000, frameCount: 1, nativeSamplePosition: 1_048, sourceTimestampNs: timestamp)
    }
}
check(native.frameCount == 48, "errors do not mutate frames")
let recovered = try native.map(sampleRate: 48_000, frameCount: 1, nativeSamplePosition: 1_048, sourceTimestampNs: 1_000_900)
check(recovered.frameStart == 48 && recovered.startNs == second.endNs, "retry retains native/time state")
// Explicit new-stream reset can accept both a new rate and a new native origin.
var newStream = try SampleClockMapper(sampleRate: 16_000, mappingRevision: 43, anchor: anchor(5_000_000, native: 1_049))
let reset = try newStream.map(sampleRate: 16_000, frameCount: 160, nativeSamplePosition: 1_049)
check(reset.frameStart == 0 && reset.frameEnd == 160 && reset.startNs == 5_000_000 && reset.endNs == 15_000_000 && reset.mappingRevision == 43, "explicit new stream")
print("PASS: contiguous blocks, native gaps/backwards, rate change, atomic errors, explicit new stream")

rejects(.invalidMappingRevision, "zero mapping revision") {
    _ = try SampleClockMapper(sampleRate: 16_000, mappingRevision: 0, anchor: anchor())
}
rejects(.missingAnchor, "missing anchor") {
    _ = try SampleClockMapper(sampleRate: 16_000, mappingRevision: 1, anchor: nil)
}
for rate: Int64 in [0, -1, Int64.min] {
    rejects(.invalidSampleRate, "invalid initial rate") { _ = try mapper(rate) }
    rejects(.invalidSampleRate, "invalid block rate") { _ = try native.map(sampleRate: rate, frameCount: 1) }
}
rejects(.invalidNativeSamplePosition, "negative anchor native position") {
    _ = try SampleClockMapper(sampleRate: 16_000, mappingRevision: 1, anchor: anchor(native: -1))
}
var invalid = try mapper(16_000, 10)
for count: Int64 in [0, -1, Int64.min] {
    rejects(.invalidFrameCount, "invalid frames") { _ = try invalid.map(sampleRate: 16_000, frameCount: count) }
}
rejects(.invalidNativeSamplePosition, "negative native position") {
    _ = try invalid.map(sampleRate: 16_000, frameCount: 1, nativeSamplePosition: -1)
}
rejects(.nonmonotonicSourceTimestamp, "timestamp before anchor") {
    _ = try invalid.map(sampleRate: 16_000, frameCount: 1, sourceTimestampNs: 9)
}
_ = try invalid.map(sampleRate: 16_000, frameCount: 1, sourceTimestampNs: 10)
rejects(.nativePositionAvailabilityChanged, "late native positions") {
    _ = try invalid.map(sampleRate: 16_000, frameCount: 1, nativeSamplePosition: 1)
}
_ = try invalid.map(sampleRate: 16_000, frameCount: 1)
rejects(.nonmonotonicSourceTimestamp, "timestamp check survives omission") {
    _ = try invalid.map(sampleRate: 16_000, frameCount: 1, sourceTimestampNs: 10)
}
// No native anchor is needed when the first block supplies a native origin.
var inferredOrigin = try mapper(16_000)
_ = try inferredOrigin.map(sampleRate: 16_000, frameCount: 10, nativeSamplePosition: 500)
rejects(.nativeSampleDiscontinuity(expected: 510, actual: 511), "first block establishes native origin") {
    _ = try inferredOrigin.map(sampleRate: 16_000, frameCount: 10, nativeSamplePosition: 511)
}
print("PASS: missing anchors, invalid values, native presence consistency, timestamp ordering")

// Known exact long boundary: 16 kHz * 10^9 seconds, product exceeds UInt64.
var longClock = try mapper(16_000, 77)
let long = try longClock.map(sampleRate: 16_000, frameCount: 16_000_000_000_001)
check(long.endNs == 1_000_000_000_000_062_577, "long rational boundary without intermediate overflow")
// Product is 128-bit but quotient is representable: Int64.max frames at 1 GHz.
var large = try mapper(1_000_000_000)
let huge = try large.map(sampleRate: 1_000_000_000, frameCount: Int64.max)
check(huge.endNs == UInt64(Int64.max), "large representable rational product")
_ = try large.map(sampleRate: 1_000_000_000, frameCount: Int64.max)
check(large.frameCount == UInt64.max - 1, "large cumulative frames")
rejects(.overflow, "cumulative frame overflow") {
    _ = try large.map(sampleRate: 1_000_000_000, frameCount: 2)
}
let final = try large.map(sampleRate: 1_000_000_000, frameCount: 1)
check(final.frameEnd == UInt64.max && final.endNs == UInt64.max, "UInt64 maximum boundary")
var elapsedOverflow = try mapper(16_000)
rejects(.overflow, "rational quotient overflow") {
    _ = try elapsedOverflow.map(sampleRate: 16_000, frameCount: Int64.max)
}
check(elapsedOverflow.frameCount == 0, "quotient overflow atomicity")
var anchorOverflow = try mapper(16_000, UInt64.max - 1)
rejects(.overflow, "anchor addition overflow") { _ = try anchorOverflow.map(sampleRate: 16_000, frameCount: 1) }
var nativeOverflow = try mapper(16_000)
rejects(.overflow, "native position addition overflow") {
    _ = try nativeOverflow.map(sampleRate: 16_000, frameCount: 1, nativeSamplePosition: Int64.max)
}
// Very high positive integral rates use the same arithmetic, without traps.
var highRate = try mapper(Int64.max)
rejects(.unrepresentableNanosecondRange, "zero-nanosecond interval") {
    _ = try highRate.map(sampleRate: Int64.max, frameCount: 1)
}
check(highRate.frameCount == 0, "zero-nanosecond rejection atomicity")
let high = try highRate.map(sampleRate: Int64.max, frameCount: Int64.max)
check(high.endNs == 1_000_000_000, "high integral sample rate")
print("PASS: long frames, full-width arithmetic, frame/time/native overflow")
print("PASS: all \(checks) checks")
