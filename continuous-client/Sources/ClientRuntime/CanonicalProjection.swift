import Foundation
import MeetingCopilotCore
import IncrementalArchive

/// Replays actual scalar observations into the archive's existing Codable projection.
/// Call from a background context: this operation performs encoding and decoding.
public enum CanonicalProjection {
    public static func metadata(_ observations: [CanonicalObservation]) throws -> LocalCanonicalMetadata {
        var result = LocalCanonicalMetadata()
        for observation in observations {
            let fields = Fields(observation.fields)
            switch observation.kind {
            case .mapped:
                let base: LocalCanonicalBlock = try decode(mapped(fields))
                let value = LocalCanonicalBlock(copying: base, estimatedPPM: try fields.optionalDouble("estimatedPPMBits"))
                if !result.blocks.contains(value) { result.blocks.append(value) }
            case .associated:
                let value: LocalTaskCanonicalSpan = try decode(associated(fields))
                if !result.associations.contains(value) { result.associations.append(value) }
            case .settled:
                let value = try settlement(fields)
                if !result.settlements.contains(value) { result.settlements.append(value) }
            case .terminalCoverage:
                result.terminalCoverage = try decode(coverage(fields))
            }
        }
        return result
    }

    private struct InvalidField: Error, CustomStringConvertible {
        let description: String
    }
    // JSONEncoder writes finite Doubles directly, including negative zero; no NSNumber conversion.
    private indirect enum Value: Encodable {
        case string(String), signed(Int64), unsigned(UInt64), boolean(Bool), double(Double)
        case object([String: Value])
        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let v): try container.encode(v)
            case .signed(let v): try container.encode(v)
            case .unsigned(let v): try container.encode(v)
            case .boolean(let v): try container.encode(v)
            case .double(let v): try container.encode(v)
            case .object(let v): try container.encode(v)
            }
        }
    }
    private enum ScalarType { case string, signed, unsigned, boolean, uuid, double }
    private struct Fields {
        let values: [String: CanonicalScalar]
        init(_ values: [String: CanonicalScalar]) { self.values = values }
        func has(_ key: String) -> Bool {
            guard let value = values[key] else { return false }
            if case .null = value { return false }
            return true
        }
        func required(_ key: String, _ type: ScalarType, raw: Bool = false) throws -> Value {
            guard let value = values[key] else { throw InvalidField(description: "Missing canonical field: \(key)") }
            switch (type, value) {
            case (.string, .string(let v)): return .string(v)
            case (.signed, .signed(let v)): return .signed(v)
            case (.unsigned, .unsigned(let v)): return .unsigned(v)
            case (.boolean, .boolean(let v)): return .boolean(v)
            case (.uuid, .uuid(let v)): return .string(v.uuidString)
            case (.double, .float64Bits(let bits)):
                let v = Double(bitPattern: bits)
                if v.isFinite { return .double(v) }
                if raw { return .string("ieee754-binary64:" + String(bits, radix: 16)) }
                throw InvalidField(description: "Nonfinite canonical field not supported by local Codable: \(key)")
            default: throw InvalidField(description: "Invalid canonical scalar type: \(key)")
            }
        }
        func optional(_ key: String, _ type: ScalarType, into object: inout [String: Value], as name: String? = nil, raw: Bool = false) throws {
            if has(key) { object[name ?? key] = try required(key, type, raw: raw) }
        }
        func double(_ key: String) throws -> Double {
            guard case .float64Bits(let bits)? = values[key] else {
                throw InvalidField(description: "Missing/invalid canonical float64Bits: \(key)")
            }
            return Double(bitPattern: bits)
        }
        func optionalDouble(_ key: String) throws -> Double? {
            has(key) ? try double(key) : nil
        }
        func signedInt(_ key: String) throws -> Int {
            guard case .signed(let value)? = values[key], let result = Int(exactly: value) else {
                throw InvalidField(description: "Missing/invalid canonical signed Int: \(key)")
            }
            return result
        }
        func unsigned(_ key: String) throws -> UInt64 {
            guard case .unsigned(let value)? = values[key] else {
                throw InvalidField(description: "Missing/invalid canonical unsigned field: \(key)")
            }
            return value
        }
        func unsignedInt(_ key: String) throws -> Int {
            guard let result = Int(exactly: try unsigned(key)) else {
                throw InvalidField(description: "Canonical unsigned Int overflow: \(key)")
            }
            return result
        }
        func required(_ keys: [String], _ type: ScalarType, into object: inout [String: Value]) throws {
            for key in keys { object[key] = try required(key, type) }
        }
    }
    private static func decode<T: Decodable>(_ value: [String: Value]) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }
    private static func raw(_ f: Fields, taggedNonfinite: Bool = true) throws -> [String: Value] {
        var object: [String: Value] = [
            "source": try f.required("rawSource", .string),
            "sampleRate": try f.required("rawSampleRate", .double, raw: taggedNonfinite),
            "receivedUptime": try f.required("rawReceivedUptime", .double, raw: taggedNonfinite)
        ]
        try f.optional("rawHostSeconds", .double, into: &object, as: "hostSeconds", raw: taggedNonfinite)
        try f.optional("rawSamplePosition", .signed, into: &object, as: "samplePosition")
        try f.optional("rawPresentationSeconds", .double, into: &object, as: "presentationSeconds", raw: taggedNonfinite)
        return object
    }
    private static func mapped(_ f: Fields) throws -> [String: Value] {
        var anchor: [String: Value] = [:]
        try f.required(["epochID"], .uuid, into: &anchor)
        try f.required(["channel", "provenance", "basis", "encoding"], .string, into: &anchor)
        try f.required(["startNs", "channelCount", "mappingRevision"], .unsigned, into: &anchor)
        try f.required(["sampleRate"], .signed, into: &anchor)
        try f.optional("nativeSamplePosition", .signed, into: &anchor)
        var object: [String: Value] = ["blockID": try f.required("blockID", .uuid),
                                        "anchor": .object(anchor), "rawObservation": .object(try raw(f))]
        try f.required(["globalFrameStart", "globalFrameEnd", "nominalStartNs", "nominalEndNs"], .unsigned, into: &object)
        try f.optional("observedBasis", .string, into: &object, as: "timestampBasis")
        try f.optional("observedStartNs", .unsigned, into: &object)
        try f.optional("residualNs", .signed, into: &object)
        try f.optional("stepErrorNs", .signed, into: &object)
        return object
    }
    private static func associated(_ f: Fields) throws -> [String: Value] {
        var object: [String: Value] = [:]
        try f.required(["blockID", "epochID"], .uuid, into: &object)
        try f.required(["streamID", "segmentID", "basis"], .string, into: &object)
        try f.required(["taskStartGlobalFrame", "globalFrameStart", "globalFrameEnd", "nominalStartNs", "nominalEndNs", "mappingRevision"], .unsigned, into: &object)
        try f.required(["taskLocalFrameStart", "taskLocalFrameEnd"], .signed, into: &object)
        return object
    }
    private static func settlement(_ f: Fields) throws -> LocalCanonicalSettlement {
        var object: [String: Value] = ["blockID": try f.required("blockID", .uuid),
            "disposition": try f.required("disposition", .string), "rawObservation": .object(try raw(f)),
            "backendAccepted": try f.required("backendAccepted", .boolean), "ownerReturned": try f.required("ownerReturned", .boolean)]
        try f.optional("failure", .string, into: &object)
        // Decode the raw observation using its existing lossless nonfinite tag; range bypasses JSON.
        let base: LocalCanonicalSettlement = try decode(object)
        let rangeFields = ["taskLocalFrameStart", "taskLocalFrameEnd", "mappingRevision", "rangeStartNs", "rangeEndNs"]
        let range: LocalCaptureBlock?
        if rangeFields.contains(where: { f.has($0) }) {
            // Every supplied range must be complete; integer conversions are checked exactly.
            range = try LocalCaptureBlock(frameStart: f.signedInt("taskLocalFrameStart"),
                frameEnd: f.signedInt("taskLocalFrameEnd"), mappingRevision: f.unsignedInt("mappingRevision"),
                startNS: String(f.unsigned("rangeStartNs")), endNS: String(f.unsigned("rangeEndNs")),
                hostSeconds: f.optionalDouble("rawHostSeconds"), samplePosition: base.rawObservation.samplePosition,
                sampleRate: f.double("rawSampleRate"), presentationSeconds: f.optionalDouble("rawPresentationSeconds"),
                receivedUptime: f.double("rawReceivedUptime"))
        } else { range = nil }
        return LocalCanonicalSettlement(blockID: base.blockID, disposition: base.disposition,
            rawObservation: base.rawObservation, taskLocalRange: range, backendAccepted: base.backendAccepted,
            ownerReturned: base.ownerReturned, failure: base.failure)
    }
    private static func coverage(_ f: Fields) throws -> [String: Value] {
        var object: [String: Value] = [:]
        try f.required(["transferredBlocks", "transferredFrames", "mappedBlocks", "mappedFrames",
            "recognitionConsumedBlocks", "recognitionConsumedFrames", "rejectedBeforeMappingBlocks", "rejectedBeforeMappingFrames",
            "rejectedAfterMappingBlocks", "rejectedAfterMappingFrames", "uncertainAfterMappingBlocks", "uncertainAfterMappingFrames",
            "backendAcceptedBlocks", "backendAcceptedFrames", "ownerReturnedBlocks", "startedTasks", "validatedFinalTasks", "validatedFinalFrames"], .unsigned, into: &object)
        try f.required(["canonicalAccountingValid", "queueAccountingValid", "ownerQueueAccountingValid", "completionCoverageValid"], .boolean, into: &object)
        try f.optional("epochID", .uuid, into: &object)
        try f.optional("releasedWithoutTransferBlocks", .unsigned, into: &object)
        if f.values.keys.contains(where: { $0.hasPrefix("queue") && $0 != "queueAccountingValid" }) {
            var queue: [String: Value] = ["state": try f.required("queueState", .string)]
            for (source, target) in [("queueQueuedBlocks", "queuedBlocks"), ("queueQueuedBytes", "queuedBytes"), ("queueHighWaterBlocks", "highWaterBlocks")] {
                queue[target] = try f.required(source, .signed)
            }
            for (source, target) in [("queueQueuedFrames", "queuedFrames"), ("queueAcceptedBlocks", "acceptedBlocks"),
                ("queueConsumedBlocks", "consumedBlocks"), ("queueReleasedBlocks", "releasedBlocks"),
                ("queueStaleRejections", "staleRejections"), ("queueInactiveRejections", "inactiveRejections"),
                ("queueOverflowFailures", "overflowFailures"), ("queueInvalidBlockFailures", "invalidBlockFailures")] {
                queue[target] = try f.required(source, .unsigned)
            }
            try f.optional("queueGenerationID", .uuid, into: &queue, as: "generationID")
            try f.optional("queueFailure", .string, into: &queue, as: "failure")
            object["queue"] = .object(queue)
        }
        return object
    }
}
