import Foundation
import CanonicalAudioClock

struct CheckFailure: Error { let message: String }
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure(message: message) }
}
func accepted(_ result: BlockMappingResult) throws -> CanonicalAudioBlock {
    guard case .accepted(let block) = result else { throw CheckFailure(message: "unexpected discontinuity: \(result)") }
    return block
}
let policy = DiscontinuityPolicy(maximumTimestampStepNs: 20_000_000)
let fixedID = UUID(uuidString: "A0000000-0000-4000-8000-000000000001")!
func format(_ rate: Int64) -> AudioFormatIdentity {
    AudioFormatIdentity(sampleRate: rate, channelCount: 1, encoding: "float32-planar")
}
func anchor(_ rate: Int64, ns: UInt64 = 20_000_000_000, id: UUID = fixedID,
            native: Int64? = nil) -> EpochAnchor {
    EpochAnchor(epochID: id, channel: "synthetic-system", startNs: ns, provenance: .callerDeclared,
                format: format(rate), mappingRevision: 1, nativeSamplePosition: native)
}
func raw(_ rate: Int64, pts: Double? = nil, host: Double? = nil, native: Int64? = nil,
         receipt: Double = 123) -> RawAudioObservation {
    RawAudioObservation(source: "synthetic-system", hostSeconds: host, samplePosition: native,
                        sampleRate: Double(rate), presentationSeconds: pts, receivedUptime: receipt)
}
func integerOracle(_ frame: UInt64, _ rate: UInt64, _ base: UInt64) -> UInt64 {
    // Independent small-domain quotient/remainder decomposition; no mapper calls.
    base + (frame / rate) * 1_000_000_000 + ((frame % rate) * 1_000_000_000) / rate
}

func v1() throws -> [String: Any] {
    let inputs: [Double] = [20, 20.004, 20.0075]
    let expected: [[UInt64]] = [[20_000_000_000, 20_004_000_000], [20_004_000_000, 20_008_000_000], [20_008_000_000, 20_012_000_000]]
    var mapper = try CanonicalBlockMapper(anchor: anchor(1_000), policy: policy)
    var blocks: [CanonicalAudioBlock] = []
    var tasks: [TaskRange] = []
    for pts in inputs {
        let input = raw(1_000, pts: pts, host: pts + 30)
        let block = try accepted(mapper.map(frameCount: 4, format: format(1_000), raw: input))
        try require(block.rawObservation == input, "raw changed")
        blocks.append(block)
        try mapper.forEachTaskRange(in: block, taskBudget: 8) { tasks.append($0) }
    }
    let actual = blocks.map { [$0.startNs, $0.endNs] }
    try require(actual == expected, "V1 canonical ranges")
    try require(blocks[2].diagnostic.residualNs == -500_000, "V1 residual")
    try require(blocks[2].rawObservation.presentationSeconds == 20.0075, "V1 raw third PTS")
    try require(tasks.map { $0.identity.partitionIndex } == [0, 0, 1], "global partition")
    try require(tasks.map { $0.localFrameStart } == [0, 4, 0], "local offsets")
    try require(tasks[0].endNs == tasks[1].startNs && tasks[1].endNs == tasks[2].startNs, "task adjacency")
    var partitionFrames: [UInt64: UInt64] = [:]
    for range in tasks { partitionFrames[range.identity.partitionIndex, default: 0] += range.globalFrameEnd - range.globalFrameStart }
    let actualPartitionFrames = partitionFrames.keys.sorted().map { partitionFrames[$0]! }
    try require(actualPartitionFrames == [8, 4], "V1 task partition totals")
    return ["status": "passed", "input_raw_pts_seconds": inputs, "actual_canonical_ranges_ns": actual,
            "raw_third_pts_seconds": blocks[2].rawObservation.presentationSeconds!,
            "actual_third_residual_ns": blocks[2].diagnostic.residualNs!,
            "task_budget": 8, "actual_task_partition_frames": actualPartitionFrames,
            "actual_task_fragments": tasks.map { ["partition": $0.identity.partitionIndex,
                "global_start": $0.globalFrameStart, "global_end": $0.globalFrameEnd,
                "local_start": $0.localFrameStart, "local_end": $0.localFrameEnd] }]
}

func v2() throws -> [String: Any] {
    var outputs: [[String: Any]] = []
    for sign in [Int64(-1), Int64(1)] {
        var mapper = try CanonicalBlockMapper(anchor: anchor(48_000), policy: policy)
        var retained: [CanonicalAudioBlock] = []
        var maximumRetained = 0
        var previousEnd: UInt64 = 20_000_000_000
        var final: CanonicalAudioBlock?
        for second in 0..<7_200 {
            // Inputs fixed independently: raw increments 999900000/1000100000 ns.
            // 48000 PCM frames/block are always present, no wall time or sleeps.
            let observedNs = Int64(20_000_000_000) + Int64(second) * (1_000_000_000 + sign * 100_000)
            let input = raw(48_000, pts: Double(observedNs) / 1_000_000_000)
            let block = try accepted(mapper.map(frameCount: 48_000, format: format(48_000), raw: input))
            try require(block.startNs == previousEnd, "V2 ns adjacency")
            try require(block.globalFrameStart == UInt64(second) * 48_000, "V2 global frames")
            try require(block.endNs == 20_000_000_000 + UInt64(second + 1) * 1_000_000_000, "V2 rational ns")
            try require(block.rawObservation == input, "V2 raw preservation")
            previousEnd = block.endNs
            if retained.count == 32 { retained.removeFirst() }
            retained.append(block); maximumRetained = max(maximumRetained, retained.count)
            final = block
        }
        let last = final!
        let expectedResidual = sign * 719_900_000
        try require(last.diagnostic.residualNs == expectedResidual, "V2 final residual")
        try require(abs(last.diagnostic.estimatedPPM! - Double(sign) * 100) < 0.000_01, "V2 ppm statistics")
        try require(mapper.globalFrameCount == 345_600_000 && maximumRetained == 32, "V2 bounded caller metadata")
        outputs.append(["input_drift_ppm": sign * 100, "blocks": 7_200, "frames": mapper.globalFrameCount,
            "canonical_final_end_ns": previousEnd, "last_raw_pts_seconds": last.rawObservation.presentationSeconds!,
            "last_residual_ns": last.diagnostic.residualNs!, "estimated_ppm": last.diagnostic.estimatedPPM!,
            "caller_metadata_capacity": 32, "maximum_retained_blocks": maximumRetained])
    }
    return ["status": "passed", "synthetic_duration_seconds_per_sign": 7_200, "sample_rate": 48_000,
            "block_frames": 48_000, "sleep_used": false, "actual": outputs]
}

func v3() throws -> [String: Any] {
    var outputs: [[String: Any]] = []
    for sign in [Int64(-1), Int64(1)] {
        var mapper = try CanonicalBlockMapper(anchor: anchor(48_000), policy: policy)
        _ = try accepted(mapper.map(frameCount: 480, format: format(48_000), raw: raw(48_000, pts: 20)))
        var control = mapper
        let pts = sign > 0 ? 20.06 : 19.96 // +/-50ms around the independently fixed next 20.01.
        let result = try mapper.map(frameCount: 480, format: format(48_000), raw: raw(48_000, pts: pts))
        let expected: Discontinuity = sign > 0 ? .explicitStepGap(stepNs: 50_000_000) : .explicitStepOverlap(stepNs: 50_000_000)
        try require(result == .requiresNewEpoch(expected), "V3 explicit step")
        try require(mapper.globalFrameCount == 480 && mapper.anchor.epochID == fixedID, "V3 rejected state")
        // Compare a successful continuation against a cloned pre-rejection state.
        let valid = raw(48_000, pts: 20.01)
        var tested = mapper
        let recovery = try tested.map(frameCount: 480, format: format(48_000), raw: valid)
        let controlRecovery = try control.map(frameCount: 480, format: format(48_000), raw: valid)
        try require(recovery == controlRecovery, "V3 hidden diagnostic state changed")
        let nextID = UUID(uuidString: sign > 0 ? "A0000000-0000-4000-8000-000000000002" : "A0000000-0000-4000-8000-000000000003")!
        let newAnchorNs = try TimestampConversion.nanoseconds(seconds: pts)
        let marker = try mapper.beginEpoch(anchor(48_000, ns: newAnchorNs, id: nextID), reason: expected)
        try require(mapper.globalFrameCount == 0 && marker.previousEpoch == fixedID && marker.nextEpoch == nextID, "V3 explicit reset")
        try require(marker.nominalBoundaryDifferenceNs == sign * 50_000_000, "V3 explicit gap marker")
        let first = try accepted(mapper.map(frameCount: 480, format: format(48_000), raw: raw(48_000, pts: pts)))
        try require(first.startNs == newAnchorNs && first.globalFrameStart == 0, "V3 new epoch mapping")
        outputs.append(["input_step_ns": sign * 50_000_000, "raw_step_pts_seconds": pts,
            "rejection": String(describing: expected), "rejected_global_frame_count": 480,
            "state_unchanged_verified_with_control": true,
            "gap_marker_previous_end_ns": marker.previousEndNs, "gap_marker_next_start_ns": marker.nextStartNs,
            "gap_marker_boundary_difference_ns": marker.nominalBoundaryDifferenceNs,
            "new_epoch_first_global_frame": first.globalFrameStart])
    }
    return ["status": "passed", "configured_threshold_ns": 20_000_000, "actual": outputs]
}

struct LCG {
    var state: UInt64 = 0xD1CE_C10C_0123_4567
    mutating func next() -> UInt64 { state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407; return state }
}
func v4() throws -> [String: Any] {
    var rng = LCG()
    let rates: [Int64] = [1_000, 8_000, 16_000, 44_100, 48_000, 96_000]
    var checkedBlocks = 0
    var fragments = 0
    for rate in rates {
        var mapper = try CanonicalBlockMapper(anchor: anchor(rate, ns: 777), policy: policy)
        var total: UInt64 = 0
        var endNs: UInt64 = 777
        for _ in 0..<400 {
            let count = rng.next() % 10_000 + 1
            let budget = rng.next() % 2_047 + 1
            let input = raw(rate)
            let block = try accepted(mapper.map(frameCount: count, format: format(rate), raw: input))
            try require(block.globalFrameStart == total && block.startNs == endNs, "V4 block adjacent")
            total += count
            let oracle = integerOracle(total, UInt64(rate), 777)
            try require(block.endNs == oracle, "V4 independent rational floor")
            var fragmentFrames: UInt64 = 0
            var cursor = block.globalFrameStart
            var cursorNs = block.startNs
            try mapper.forEachTaskRange(in: block, taskBudget: budget) { range in
                try require(range.globalFrameStart == cursor && range.startNs == cursorNs, "V4 split adjacency")
                try require(range.identity.partitionIndex == cursor / budget, "V4 partition index")
                try require(range.identity.partitionStartGlobalFrame == cursor / budget * budget, "V4 global partition origin")
                try require(range.localFrameStart == cursor % budget && range.localFrameEnd <= budget, "V4 task local offsets")
                try require(range.endNs == integerOracle(range.globalFrameEnd, UInt64(rate), 777), "V4 split floor")
                fragmentFrames += range.globalFrameEnd - range.globalFrameStart
                cursor = range.globalFrameEnd; cursorNs = range.endNs; fragments += 1
            }
            try require(fragmentFrames == count && cursor == total && cursorNs == oracle, "V4 partition conservation")
            endNs = block.endNs; checkedBlocks += 1
        }
    }
    var invalidChecks = 0
    func rejectsUnchanged(_ attempt: (inout CanonicalBlockMapper) throws -> Void) throws {
        var mapper = try CanonicalBlockMapper(anchor: anchor(48_000), policy: policy)
        _ = try accepted(mapper.map(frameCount: 480, format: format(48_000), raw: raw(48_000, pts: 20)))
        var control = mapper
        var threw = false
        do { try attempt(&mapper) } catch { threw = true }
        try require(threw, "V4 missing rejection")
        try require(mapper.globalFrameCount == control.globalFrameCount && mapper.anchor == control.anchor, "V4 visible state changed")
        let continuation = raw(48_000, pts: 20.01)
        let lhs = try mapper.map(frameCount: 480, format: format(48_000), raw: continuation)
        let rhs = try control.map(frameCount: 480, format: format(48_000), raw: continuation)
        try require(lhs == rhs, "V4 hidden state changed")
        invalidChecks += 1
    }
    try rejectsUnchanged { _ = try $0.map(frameCount: 0, format: format(48_000), raw: raw(48_000)) }
    try rejectsUnchanged { _ = try $0.map(frameCount: UInt64.max, format: format(48_000), raw: raw(48_000)) }
    try rejectsUnchanged { _ = try $0.map(frameCount: 480, format: format(0), raw: raw(0)) }
    try rejectsUnchanged { _ = try $0.map(frameCount: 480, format: format(48_000), raw: raw(48_000, pts: .nan)) }
    try rejectsUnchanged { _ = try $0.map(frameCount: 480, format: format(48_000), raw: raw(48_000, host: .infinity)) }
    try rejectsUnchanged { _ = try $0.map(frameCount: 480, format: format(48_000), raw: raw(48_000, pts: -1)) }
    try rejectsUnchanged { _ = try $0.map(frameCount: 480, format: format(48_000), raw: raw(48_000, pts: 18_446_744_073.709_553)) }
    try rejectsUnchanged { _ = try $0.map(frameCount: 480, format: format(48_000), raw: raw(48_000, native: -1)) }
    try rejectsUnchanged {
        let invalid = RawAudioObservation(source: "synthetic", hostSeconds: nil, samplePosition: nil,
            sampleRate: 48_000.5, presentationSeconds: nil, receivedUptime: 123)
        _ = try $0.map(frameCount: 480, format: format(48_000), raw: invalid)
    }
    try rejectsUnchanged { _ = try $0.map(frameCount: 480, format: format(48_000), raw: raw(48_000, receipt: .nan)) }
    try rejectsUnchanged {
        let invalid = EpochAnchor(epochID: UUID(), channel: "x", startNs: 0, provenance: .callerDeclared,
            format: format(48_000), mappingRevision: 0)
        _ = try $0.beginEpoch(invalid, reason: .callerDeclaredReset)
    }
    try rejectsUnchanged { _ = try $0.beginEpoch(anchor(48_000), reason: .callerDeclaredReset) }
    try rejectsUnchanged {
        let bad = EpochAnchor(epochID: UUID(), channel: "x", startNs: 0, provenance: .callerDeclared,
                              format: format(-1), mappingRevision: 1)
        _ = try $0.beginEpoch(bad, reason: .callerDeclaredReset)
    }
    // Cumulative UInt64 overflow: representable rate=1e9 => exactly one ns/frame.
    var huge = try CanonicalBlockMapper(anchor: anchor(1_000_000_000, ns: 0), policy: policy)
    for _ in 0..<2 { _ = try accepted(huge.map(frameCount: UInt64(Int64.max), format: format(1_000_000_000), raw: raw(1_000_000_000))) }
    _ = try accepted(huge.map(frameCount: 1, format: format(1_000_000_000), raw: raw(1_000_000_000)))
    try require(huge.globalFrameCount == UInt64.max, "V4 UInt64 extent")
    var overflowRejected = false
    do { _ = try huge.map(frameCount: 1, format: format(1_000_000_000), raw: raw(1_000_000_000)) }
    catch { overflowRejected = true }
    try require(overflowRejected && huge.globalFrameCount == UInt64.max, "V4 cumulative overflow unchanged")
    // Nanosecond anchor addition overflow and native addition overflow.
    var nearEnd = try CanonicalBlockMapper(anchor: anchor(1_000, ns: UInt64.max - 1), policy: policy)
    do {
        _ = try nearEnd.map(frameCount: 1, format: format(1_000), raw: raw(1_000))
        throw CheckFailure(message: "V4 missing ns overflow")
    } catch is CheckFailure { throw CheckFailure(message: "V4 missing ns overflow") } catch {}
    try require(nearEnd.globalFrameCount == 0, "V4 ns overflow state")
    var native = try CanonicalBlockMapper(anchor: anchor(48_000, native: 100), policy: policy)
    _ = try accepted(native.map(frameCount: 480, format: format(48_000), raw: raw(48_000, pts: 20, native: 100)))
    let nativeGap = try native.map(frameCount: 480, format: format(48_000), raw: raw(48_000, pts: 20.01, native: 581))
    try require(nativeGap == .requiresNewEpoch(.nativeGap(expected: 580, actual: 581)) && native.globalFrameCount == 480, "V4 native gap")
    let nativePriority = try accepted(native.map(frameCount: 480, format: format(48_000), raw: raw(48_000, pts: 20.06, native: 580)))
    try require(nativePriority.diagnostic.stepErrorNs == 50_000_000, "V4 native priority preserves step diagnostic")
    let changed = try native.map(frameCount: 480, format: format(44_100), raw: raw(44_100, native: 1_060))
    try require(changed == .requiresNewEpoch(.formatChanged(expected: format(48_000), actual: format(44_100))) && native.globalFrameCount == 960, "V4 format change")
    var nativeOverflow = try CanonicalBlockMapper(anchor: anchor(48_000, native: Int64.max), policy: policy)
    do {
        _ = try nativeOverflow.map(frameCount: 1, format: format(48_000), raw: raw(48_000, native: Int64.max))
        throw CheckFailure(message: "V4 missing native overflow")
    } catch is CheckFailure { throw CheckFailure(message: "V4 missing native overflow") } catch {}
    try require(nativeOverflow.globalFrameCount == 0, "V4 native overflow state")
    let roundedTie = try TimestampConversion.nanoseconds(seconds: 0.000_000_000_5)
    try require(roundedTie == 1, "V4 rounding tie")
    return ["status": "passed", "seed_hex": "D1CEC10C01234567", "rates": rates,
            "random_blocks": checkedBlocks, "actual_task_fragments": fragments,
            "invalid_continuation_control_checks": invalidChecks,
            "cumulative_uint64_overflow_rejected": overflowRejected,
            "native_continuity_priority_verified": true, "format_change_explicit": true,
            "independent_oracle": "quotient/remainder floor", "rounding": "nearest ties away from zero"]
}

var report: [String: Any] = [
    "schema": "canonical-audio-clock-synthetic-v1", "scope": "synthetic integer nominal timeline and scalar raw metadata only",
    "real_capture": 0, "hardware_accuracy_claimed": false, "calibration_claimed": false,
    "command": "swift run canonical-audio-clock-checks",
    "arguments": CommandLine.arguments, "limits": ["integral sample rates only", "nonnegative representable timestamps",
        "caller must establish same clock domain and epoch anchor", "caller owns bounded metadata storage",
        "endpoint ppm is a diagnostic statistic, not calibration", "no PCM/device/ASR/archive/timer integration"]
]
do {
    report["V1"] = try v1(); report["V2"] = try v2(); report["V3"] = try v3(); report["V4"] = try v4()
    report["status"] = "passed"; report["exit_code"] = 0
} catch {
    report["status"] = "failed"; report["exit_code"] = 1; report["failure"] = String(describing: error)
}
let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: data, as: UTF8.self))
if report["exit_code"] as? Int != 0 { exit(1) }
