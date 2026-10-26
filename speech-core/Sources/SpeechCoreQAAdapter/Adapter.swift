import Foundation
import CoreFoundation
import SpeechCore

/// stdin only; never opens fixture/expected/store paths. Projection + actual core calls only.
@main
struct SpeechCoreQAAdapter {
    static func string(_ object: [String: Any], _ key: String) throws -> String {
        guard let value = object[key] as? String else { throw CoreError.invalid("MISSING_STRING:\(key)") }
        return value
    }
    static func integer(_ object: [String: Any], _ key: String) throws -> Int {
        guard let n = object[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              let value = Int(n.stringValue) else { throw CoreError.invalid("MISSING_INTEGER:\(key)") }
        return value
    }
    static func dictionary(_ object: [String: Any], _ key: String) throws -> [String: Any] {
        guard let value = object[key] as? [String: Any] else { throw CoreError.invalid("MISSING_OBJECT:\(key)") }
        return value
    }
    static func wire(_ event: SpeechEvent) throws -> [String: Any] {
        guard var value = try JSONSerialization.jsonObject(with: event.encoded()) as? [String: Any] else { throw CoreError.invalid("EVENT_ENCODING") }
        if event.type == "asr.segment" { value["speaker_id"] = event.speakerId as Any? ?? NSNull() }
        if event.type == "asr.segment" || event.type == "translation.segment" { value["replaces_revision"] = event.replacesRevision as Any? ?? NSNull() }
        return value
    }
    static func project(_ core: SpeechReducer, slices: [String: String], discards: [[String: Any]], stepResults: [[String: Any]]) throws -> [String: Any] {
        let segments = try core.segments.keys.sorted().compactMap { id -> [String: Any]? in
            guard let event = core.currentSegment(id) else { return nil }; return try wire(event)
        }
        let current = try core.translations.keys.sorted().compactMap { id -> [String: Any]? in
            guard let event = core.currentTranslation(id) else { return nil }; return try wire(event)
        }
        var stale: [[String: Any]] = []
        for id in core.translations.keys.sorted() {
            for event in core.translations[id] ?? [] where core.isTranslationStale(event) {
                var item = try wire(event); item["stale"] = true; stale.append(item)
            }
        }
        return ["last_applied_event_seq": core.lastAppliedSequence,
                "received_high_water_seq": core.receivedHighWaterSequence,
                "segments": segments, "current_translations": current, "stale_translations": stale,
                "buffered_event_seqs": core.bufferedSequences, "buffered_count": core.bufferedCount,
                "buffered_bytes": core.bufferedBytes, "transport_state": core.transport.rawValue,
                "slices": slices, "discarded_responses": discards,
                "pipeline_states": core.pipelineStates,
                "diagnostics": ["step_results": stepResults, "rejected_sequences": core.rejectedSequences.sorted(), "recovery_reason": core.recoveryReason as Any? ?? NSNull()]]
    }
    static func run(_ input: [String: Any]) throws -> [String: Any] {
        let caseId = try string(input, "id"), config = try dictionary(input, "config")
        guard let steps = input["steps"] as? [[String: Any]] else { throw CoreError.invalid("MISSING_STEPS") }
        // Session identity comes from input events, never a fixture name or expected state.
        guard let firstEvent = steps.first(where: { ($0["op"] as? String) == "event" })?["event"] as? [String: Any] else { throw CoreError.invalid("SESSION_EVENT_REQUIRED") }
        let reorderTimeout = try integer(config, "reorder_timeout_ms"), recoveryTimeout = try integer(config, "recovery_timeout_ms")
        guard reorderTimeout > 0, recoveryTimeout > 0 else { throw CoreError.invalid("CONFIG_REQUIRED") }
        let limits = try CoreLimits(maxBufferedEvents: integer(config, "reorder_max_events"), maxBufferedBytes: integer(config, "reorder_max_bytes"), reorderTimeoutMs: UInt64(reorderTimeout), recoveryTimeoutMs: UInt64(recoveryTimeout))
        var core = try SpeechReducer(sessionId: string(firstEvent, "session_id"), limits: limits)
        var requests: [String: TranslationRequest] = [:], slices: [String: String] = [:]
        var discards: [[String: Any]] = [], results: [[String: Any]] = [], checkpoints: [[String: Any]] = []
        var unsupported: [String] = []
        for (index, step) in steps.enumerated() {
            let op = try string(step, "op")
            let nowInt = step["now_ms"] == nil ? 0 : try integer(step, "now_ms")
            guard nowInt >= 0 else { throw CoreError.invalid("NEGATIVE_TIME") }; let now = UInt64(nowInt)
            switch op {
            case "event":
                let event = try dictionary(step, "event")
                // No adapter deduplication, reordering or type skipping.
                let outcome = core.receive(try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]), nowMs: now)
                results.append(["step": index, "op": op, "result": String(describing: outcome)])
            case "translation_request":
                let r = try dictionary(step, "request"), id = try string(r, "request_id")
                let request = try core.requestTranslation(id: id, translationId: string(r, "translation_id"), segmentId: string(r, "segment_id"), targetLanguage: string(r, "target_language"), sourceRevision: integer(r, "source_revision"), glossaryRevision: integer(r, "glossary_revision"), requestGeneration: integer(r, "request_generation"))
                requests[id] = request
                results.append(["step": index, "op": op, "request_id": request.id, "request_generation": request.generation])
            case "translation_response":
                let id = try string(step, "request_id")
                guard let request = requests[id] else { throw CoreError.invalid("UNKNOWN_REQUEST") }
                let emitted: String
                if let provided = step["emitted_at_ns"] as? String { emitted = provided }
                else { guard let time = UInt64(core.lastEmittedAtNs), time < UInt64.max else { throw CoreError.invalid("CLOCK_EXHAUSTED") }; emitted = String(time + 1) }
                let eventId = step["event_id"] as? String ?? "adapter-response-\(index)-\(id)"
                switch core.acceptTranslation(request, text: try string(step, "translated_text"), eventId: eventId, emittedAtNs: emitted, nowMs: now) {
                case .discarded(let reason):
                    discards.append(["request_id": id, "reason": reason])
                    results.append(["step": index, "op": op, "result": "discarded", "reason": reason])
                case .published(let event):
                    results.append(["step": index, "op": op, "result": "published", "event": try wire(event)])
                }
            case "slice_code_points":
                let id = try string(step, "result_id")
                slices[id] = try CodePointText.slice(string(step, "text"), start: integer(step, "start"), end: integer(step, "end"))
            case "tick": core.tick(nowMs: now)
            case "checkpoint":
                let state = try project(core, slices: slices, discards: discards, stepResults: results)
                checkpoints.append(["id": try string(step, "id"), "state": state])
            default:
                unsupported.append(op)
                results.append(["step": index, "op": op, "result": "unsupported"])
            }
        }
        return ["case_id": caseId, "checkpoints": checkpoints, "unsupported_operations": unsupported,
                "implementation": "SpeechCore Swift reducer/coordinator/CodePointText"]
    }
    static func main() {
        do {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard let input = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CoreError.invalid("INPUT_OBJECT_REQUIRED") }
            let output = try run(input)
            let encoded = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
            FileHandle.standardOutput.write(encoded); FileHandle.standardOutput.write(Data("\n".utf8))
            if let unsupported = output["unsupported_operations"] as? [String], !unsupported.isEmpty { exit(2) }
        } catch {
            FileHandle.standardError.write(Data("SpeechCoreQAAdapter: \(error)\n".utf8)); exit(2)
        }
    }
}
