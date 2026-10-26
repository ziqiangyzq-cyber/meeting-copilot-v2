import Foundation

/// Flat wire subset. Unknown fields are ignored; unknown event types are rejected.
public struct SourceAudioSpan: Codable, Equatable, Sendable {
    public let channelId: String, streamId: String
    public let frameStart: Int, frameEnd: Int, mappingRevision: Int
    public init(channelId: String, streamId: String, frameStart: Int, frameEnd: Int, mappingRevision: Int) {
        self.channelId = channelId; self.streamId = streamId; self.frameStart = frameStart
        self.frameEnd = frameEnd; self.mappingRevision = mappingRevision
    }
}

public struct SpeechEvent: Codable, Equatable, Sendable {
    public var schemaVersion: Int = 1
    public var eventId: String
    public var sessionId: String
    public var eventSeq: Int
    public var type: String
    public var emittedAtNs: String
    public var segmentId: String?, revision: Int?, replacesRevision: Int?, status: String?, text: String?
    public var startNs: String?, endNs: String?, speakerId: String?
    public var sourceSpans: [SourceAudioSpan]?
    public var correctionReason: String?, editorKind: String?
    public var translationId: String?, sourceRevision: Int?, sourceText: String?, targetLanguage: String?, translatedText: String?
    public var glossaryRevision: Int?
    public var channelId: String?, channelKind: String?, streamId: String?, gapId: String?
    public var previousStreamId: String?, newStreamId: String?, gapEndNs: String?
    public var frameStart: Int?, frameCount: Int?, mappingRevision: Int?, availability: String?, audioRef: String?
    public var stage: String?, state: String?, code: String?
    public init(id: String, session: String, sequence: Int, type: String, timeNs: String) {
        eventId = id; sessionId = session; eventSeq = sequence; self.type = type; emittedAtNs = timeNs
    }
    public static func decode(_ data: Data) throws -> Self {
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(Self.self, from: data)
    }
    public func encoded() throws -> Data {
        let e = JSONEncoder(); e.keyEncodingStrategy = .convertToSnakeCase; e.outputFormatting = [.sortedKeys]
        return try e.encode(self)
    }
}

public struct CoreLimits: Sendable {
    public let maxBufferedEvents: Int, maxBufferedBytes: Int
    public let reorderTimeoutMs: UInt64, recoveryTimeoutMs: UInt64
    public init(maxBufferedEvents: Int, maxBufferedBytes: Int, reorderTimeoutMs: UInt64, recoveryTimeoutMs: UInt64) throws {
        guard maxBufferedEvents > 0, maxBufferedBytes > 0, reorderTimeoutMs > 0, recoveryTimeoutMs > 0 else { throw CoreError.invalid("CONFIG_REQUIRED") }
        self.maxBufferedEvents = maxBufferedEvents; self.maxBufferedBytes = maxBufferedBytes
        self.reorderTimeoutMs = reorderTimeoutMs; self.recoveryTimeoutMs = recoveryTimeoutMs
    }
}
public enum CoreError: Error, Equatable { case invalid(String) }
public enum TransportState: String, Sendable { case ready, recoveryRequired, recoveryUnavailable }
public enum IngestResult: Equatable, Sendable { case applied(Int), buffered, duplicate, blocked, recoveryRequired(String) }
public struct Gap: Equatable, Sendable { public let channel: String, stream: String, startNs: UInt64; public var endNs: UInt64? }
public struct Stream: Equatable, Sendable { public let channel: String, kind: String }
public struct TranslationRequest: Equatable, Sendable {
    public let id: String, translationId: String, segmentId: String, targetLanguage: String
    public let generation: Int, sourceRevision: Int, sourceText: String, glossaryRevision: Int
}
public enum TranslationResult: Equatable, Sendable { case published(SpeechEvent), discarded(String) }

/// Full replay checkpoint, deliberately not the full contract's trimmed-history snapshot.
public struct ReplayCheckpoint: Sendable {
    public let sessionId: String, events: [SpeechEvent], resolvedRejectedSequences: Set<Int>
    public init(sessionId: String, events: [SpeechEvent], resolvedRejectedSequences: Set<Int> = []) {
        self.sessionId = sessionId; self.events = events; self.resolvedRejectedSequences = resolvedRejectedSequences
    }
}

/// Pure synchronous value state. Use on one actor/serial executor. No I/O, capture or inference.
public struct SpeechReducer: Sendable {
    public let sessionId: String, limits: CoreLimits
    public private(set) var lastAppliedSequence = 0, receivedHighWaterSequence = 0
    public private(set) var transport: TransportState = .ready
    public private(set) var recoveryReason: String?
    public private(set) var segments: [String: [SpeechEvent]] = [:]
    public private(set) var translations: [String: [SpeechEvent]] = [:]
    public private(set) var streams: [String: Stream] = [:]
    public private(set) var gaps: [String: Gap] = [:]
    public private(set) var pipelineStates: [String: String] = [:]
    public private(set) var chunks: [SpeechEvent] = []
    public var bufferedSequences: [Int] { pending.keys.sorted() }
    public private(set) var errors: [SpeechEvent] = []
    public private(set) var glossaryRevision = 0
    public private(set) var rejectedSequences: Set<Int> = []
    private var journal: [SpeechEvent] = []
    private var pending: [Int: SpeechEvent] = [:]
    private var pendingSizes: [Int: Int] = [:]
    private var byId: [String: SpeechEvent] = [:]
    private var gapSinceMs: UInt64?, recoverySinceMs: UInt64?, lastNowMs: UInt64 = 0
    private var lastEmission: UInt64 = 0
    private var generations: [String: Int] = [:]
    private var requests: [String: TranslationRequest] = [:]
    private var requestIds: Set<String> = []

    public init(sessionId: String, limits: CoreLimits) throws {
        guard !sessionId.isEmpty else { throw CoreError.invalid("EMPTY_SESSION") }
        self.sessionId = sessionId; self.limits = limits
    }
    public var bufferedCount: Int { pending.count }
    public var bufferedBytes: Int { pendingSizes.values.reduce(0, +) }
    public func currentSegment(_ id: String) -> SpeechEvent? { segments[id]?.last }
    public func currentTranslation(_ id: String) -> SpeechEvent? {
        guard let t = translations[id]?.last, let s = t.segmentId.flatMap({ currentSegment($0) }),
              s.revision == t.sourceRevision, t.glossaryRevision == glossaryRevision else { return nil }
        return t
    }
    public func isTranslationStale(_ event: SpeechEvent) -> Bool {
        guard let source = event.segmentId.flatMap({ currentSegment($0) }) else { return true }
        return source.revision != event.sourceRevision || event.glossaryRevision != glossaryRevision
    }
    public var lastEmittedAtNs: String { String(lastEmission) }
    public func resumeSequence() -> Int { lastAppliedSequence }
    public func checkpoint(resolvedRejectedSequences: Set<Int> = []) -> ReplayCheckpoint {
        ReplayCheckpoint(sessionId: sessionId, events: journal, resolvedRejectedSequences: resolvedRejectedSequences)
    }
    private mutating func fail(_ reason: String, sequence: Int? = nil, nowMs: UInt64) -> IngestResult {
        if let sequence { rejectedSequences.insert(sequence) }
        if transport == .ready { recoverySinceMs = nowMs }
        transport = .recoveryRequired; recoveryReason = reason
        // Freeze and bound memory immediately. Recovery must use a checkpoint.
        pending.removeAll(); pendingSizes.removeAll(); gapSinceMs = nil
        return .recoveryRequired(reason)
    }
    public mutating func tick(nowMs: UInt64) {
        guard nowMs >= lastNowMs else { _ = fail("NON_MONOTONIC_CONSUMER_CLOCK", nowMs: lastNowMs); return }
        lastNowMs = nowMs
        if transport == .recoveryRequired, let since = recoverySinceMs, nowMs - since >= limits.recoveryTimeoutMs {
            transport = .recoveryUnavailable; recoveryReason = "RESUME_UNAVAILABLE"
        } else if transport == .ready, let since = gapSinceMs, nowMs - since >= limits.reorderTimeoutMs {
            _ = fail("REORDER_TIMEOUT", nowMs: nowMs)
        }
    }
    public mutating func receive(_ data: Data, nowMs: UInt64) -> IngestResult {
        tick(nowMs: nowMs)
        guard transport == .ready else { return .blocked }
        let event: SpeechEvent
        do { event = try SpeechEvent.decode(data) }
        catch { return fail("INVALID_ENVELOPE", nowMs: nowMs) }
        guard event.schemaVersion == 1, event.sessionId == sessionId, event.eventSeq > 0,
              !event.eventId.isEmpty, Self.ns(event.emittedAtNs) != nil else {
            return fail("INVALID_ENVELOPE", nowMs: nowMs)
        }
        receivedHighWaterSequence = max(receivedHighWaterSequence, event.eventSeq)
        if let prior = byId[event.eventId] {
            return prior == event ? .duplicate : fail("EVENT_ID_CONFLICT", sequence: event.eventSeq, nowMs: nowMs)
        }
        if event.eventSeq <= lastAppliedSequence {
            guard journal.indices.contains(event.eventSeq - 1), journal[event.eventSeq - 1] == event else {
                return fail("SEQUENCE_CONFLICT", sequence: event.eventSeq, nowMs: nowMs)
            }
            return .duplicate
        }
        if let prior = pending[event.eventSeq] {
            return prior == event ? .duplicate : fail("SEQUENCE_CONFLICT", sequence: event.eventSeq, nowMs: nowMs)
        }
        if event.eventSeq != lastAppliedSequence + 1 {
            guard pending.count < limits.maxBufferedEvents, data.count <= limits.maxBufferedBytes - bufferedBytes else {
                return fail("REORDER_OVERFLOW", nowMs: nowMs)
            }
            pending[event.eventSeq] = event; pendingSizes[event.eventSeq] = data.count
            byId[event.eventId] = event
            if gapSinceMs == nil { gapSinceMs = nowMs }
            return .buffered
        }
        var next: SpeechEvent? = event
        while let candidate = next {
            do { try apply(candidate) }
            catch { return fail(String(describing: error), sequence: candidate.eventSeq, nowMs: nowMs) }
            lastAppliedSequence = candidate.eventSeq; lastEmission = Self.ns(candidate.emittedAtNs)!
            journal.append(candidate); byId[candidate.eventId] = candidate
            pending.removeValue(forKey: candidate.eventSeq); pendingSizes.removeValue(forKey: candidate.eventSeq)
            next = pending[lastAppliedSequence + 1]
        }
        // A still-open gap keeps its original timer; later arrivals never reset it.
        if pending.isEmpty { gapSinceMs = nil }
        return .applied(lastAppliedSequence)
    }
    private static func ns(_ value: String?) -> UInt64? {
        guard let value, !value.isEmpty, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        return UInt64(value)
    }
    private func require(_ ok: Bool, _ reason: String) throws { if !ok { throw CoreError.invalid(reason) } }
    private mutating func apply(_ e: SpeechEvent) throws {
        try require(Self.ns(e.emittedAtNs)! >= lastEmission, "NON_MONOTONIC_EMISSION")
        switch e.type {
        case "session.config":
            guard let r = e.glossaryRevision else { throw CoreError.invalid("GLOSSARY_REQUIRED") }
            try require(r > glossaryRevision, "GLOSSARY_REVISION"); glossaryRevision = r
        case "asr.segment":
            guard let id = e.segmentId, !id.isEmpty, let rev = e.revision, let text = e.text,
                  let status = e.status, let start = Self.ns(e.startNs), let end = Self.ns(e.endNs) else { throw CoreError.invalid("INVALID_ASR") }
            let old = currentSegment(id)
            try require(start < end && rev == (old?.revision ?? 0) + 1 && e.replacesRevision == old?.revision, "ASR_REVISION_OR_RANGE")
            let allowed = old == nil ? ["partial", "final"] : (old?.status == "partial" ? ["partial", "final"] : ["corrected"])
            try require(allowed.contains(status), "ASR_STATE")
            if status == "corrected" {
                try require(["engine_revision", "authorized_review"].contains(e.correctionReason ?? "") && ["engine", "human"].contains(e.editorKind ?? ""), "CORRECTION_METADATA")
            }
            _ = text // Empty text is legal; no words or speaker identity are inferred.
            segments[id, default: []].append(e)
        case "translation.segment":
            guard let id = e.translationId, !id.isEmpty, let sourceId = e.segmentId,
                  let source = currentSegment(sourceId), let rev = e.revision,
                  let target = e.targetLanguage, !target.isEmpty, e.translatedText != nil else { throw CoreError.invalid("INVALID_TRANSLATION") }
            let old = translations[id]?.last
            try require(source.status != "partial" && source.revision == e.sourceRevision && source.text == e.sourceText && e.glossaryRevision == glossaryRevision, "TRANSLATION_BINDING")
            try require(rev == (old?.revision ?? 0) + 1 && e.replacesRevision == old?.revision, "TRANSLATION_REVISION")
            try require(e.status == (old == nil ? "final" : "corrected"), "TRANSLATION_STATE")
            if let old { try require(old.segmentId == sourceId && old.targetLanguage == target, "TRANSLATION_ID_REUSED") }
            translations[id, default: []].append(e)
        case "audio.stream_opened":
            guard let id = e.streamId, !id.isEmpty, let channel = e.channelId, !channel.isEmpty,
                  let kind = e.channelKind, ["mic", "system", "synthetic", "audio_file"].contains(kind) else { throw CoreError.invalid("INVALID_STREAM") }
            try require(streams[id] == nil, "STREAM_ID_REUSED")
            streams[id] = Stream(channel: channel, kind: kind)
            pipelineStates["capture:\(channel)"] = "recovering"
        case "audio.chunk":
            guard let stream = e.streamId, let channel = e.channelId, streams[stream]?.channel == channel,
                  let start = e.frameStart, start >= 0, let count = e.frameCount, count > 0, start <= Int.max - count,
                  let mapping = e.mappingRevision, mapping > 0, let begin = Self.ns(e.startNs), let end = Self.ns(e.endNs), begin < end,
                  ["available", "unavailable"].contains(e.availability ?? "") else { throw CoreError.invalid("INVALID_CHUNK") }
            try require(e.availability != "unavailable" || e.audioRef == nil, "UNAVAILABLE_AUDIO_REFERENCE")
            try require(e.availability != "available" || !(e.audioRef ?? "").isEmpty, "AVAILABLE_AUDIO_REFERENCE_REQUIRED")
            if let previous = chunks.last(where: { $0.streamId == stream }) {
                try require(start >= previous.frameStart! + previous.frameCount!, "OVERLAPPING_AUDIO_FRAMES")
            }
            chunks.append(e) // Metadata only: no audio reads, no clock precision/liveness claims.
        case "audio.gap":
            guard let id = e.gapId, !id.isEmpty, let channel = e.channelId, let stream = e.streamId,
                  streams[stream]?.channel == channel, let start = Self.ns(e.startNs) else { throw CoreError.invalid("INVALID_GAP") }
            try require(gaps[id] == nil, "GAP_ID_REUSED")
            let end = Self.ns(e.endNs)
            try require((e.endNs == nil || end != nil) && (end == nil || end! >= start), "GAP_RANGE")
            gaps[id] = Gap(channel: channel, stream: stream, startNs: start, endNs: end)
            pipelineStates["capture:\(channel)"] = "interrupted"; pipelineStates["asr:\(channel)"] = "interrupted"
        case "audio.resumed":
            guard let id = e.gapId, var gap = gaps[id], let channel = e.channelId,
                  gap.channel == channel, gap.endNs == nil, e.previousStreamId == gap.stream,
                  let new = e.newStreamId, new != gap.stream, streams[new]?.channel == channel,
                  let end = Self.ns(e.gapEndNs), end >= gap.startNs else { throw CoreError.invalid("INVALID_RESUME") }
            gap.endNs = end; gaps[id] = gap
            pipelineStates["capture:\(channel)"] = "recovering"; pipelineStates["asr:\(channel)"] = "recovering"
        case "pipeline.state":
            guard let stage = e.stage, ["capture", "clock", "asr", "translation", "transport"].contains(stage),
                  let state = e.state, ["interrupted", "recovering", "stopped"].contains(state) else { throw CoreError.invalid("UNSUPPORTED_STATE_OR_RUNNING_EVIDENCE") }
            pipelineStates["\(stage):\(e.channelId ?? "session")"] = state
        case "pipeline.error":
            guard let stage = e.stage, ["capture", "clock", "asr", "translation", "transport"].contains(stage), let code = e.code, !code.isEmpty else { throw CoreError.invalid("INVALID_ERROR") }
            errors.append(e)
        default: throw CoreError.invalid("UNSUPPORTED_EVENT")
        }
    }
    /// Authority-controlled, full contiguous replay. Never use a self-made checkpoint to skip poison events.
    public mutating func restore(_ snapshot: ReplayCheckpoint, nowMs: UInt64) throws {
        guard transport != .recoveryUnavailable, nowMs >= lastNowMs, snapshot.sessionId == sessionId,
              snapshot.events.count >= lastAppliedSequence,
              rejectedSequences.isSubset(of: snapshot.resolvedRejectedSequences),
              rejectedSequences.allSatisfy({ $0 <= snapshot.events.count }) else { throw CoreError.invalid("INVALID_CHECKPOINT") }
        var rebuilt = try SpeechReducer(sessionId: sessionId, limits: limits)
        for (i, event) in snapshot.events.enumerated() {
            guard event.eventSeq == i + 1 else { throw CoreError.invalid("INCOMPLETE_CHECKPOINT") }
            guard rebuilt.receive(try event.encoded(), nowMs: nowMs) == .applied(i + 1) else { throw CoreError.invalid("INVALID_CHECKPOINT_EVENT") }
        }
        // A checkpoint is state recovery, never device liveness evidence.
        for key in rebuilt.pipelineStates.keys where key.hasPrefix("capture:") || key.hasPrefix("asr:") {
            rebuilt.pipelineStates[key] = "recovering"
        }
        rebuilt.receivedHighWaterSequence = max(receivedHighWaterSequence, rebuilt.lastAppliedSequence)
        // In-flight request generations from before restoration are deliberately invalidated.
        rebuilt.generations = generations; rebuilt.requestIds = requestIds
        self = rebuilt
    }
    /// Producer-only request preparation. Supersedes previous request without waiting/cancellation I/O.
    public mutating func requestTranslation(id: String, translationId: String, segmentId: String, targetLanguage: String, sourceRevision: Int? = nil, glossaryRevision expectedGlossary: Int? = nil, requestGeneration: Int? = nil) throws -> TranslationRequest {
        guard transport == .ready, pending.isEmpty, !id.isEmpty, !requestIds.contains(id), !translationId.isEmpty,
              !targetLanguage.isEmpty, let source = currentSegment(segmentId), source.status != "partial", glossaryRevision > 0 else { throw CoreError.invalid("REQUEST_NOT_READY") }
        if let t = translations[translationId]?.last {
            try require(t.segmentId == segmentId && t.targetLanguage == targetLanguage, "TRANSLATION_ID_REUSED")
        }
        if let r = requests[translationId] {
            try require(r.segmentId == segmentId && r.targetLanguage == targetLanguage, "TRANSLATION_ID_REUSED")
        }
        let generation = (generations[translationId] ?? 0) + 1
        try require(sourceRevision == nil || sourceRevision == source.revision, "REQUEST_SOURCE_REVISION")
        try require(expectedGlossary == nil || expectedGlossary == glossaryRevision, "REQUEST_GLOSSARY_REVISION")
        try require(requestGeneration == nil || requestGeneration == generation, "REQUEST_GENERATION")
        let request = TranslationRequest(id: id, translationId: translationId, segmentId: segmentId, targetLanguage: targetLanguage, generation: generation, sourceRevision: source.revision!, sourceText: source.text!, glossaryRevision: glossaryRevision)
        generations[translationId] = generation; requests[translationId] = request; requestIds.insert(id)
        return request
    }
    /// Producer-only atomic acceptance + local publication; return the event for client transport.
    public mutating func acceptTranslation(_ request: TranslationRequest, text: String, eventId: String, emittedAtNs: String, nowMs: UInt64) -> TranslationResult {
        guard transport == .ready, pending.isEmpty else { return .discarded("not_ready") }
        guard let source = currentSegment(request.segmentId), source.revision == request.sourceRevision else { return .discarded("stale_source") }
        guard glossaryRevision == request.glossaryRevision else { return .discarded("stale_glossary") }
        guard requests[request.translationId] == request else { return .discarded("superseded_request") }
        guard !eventId.isEmpty, byId[eventId] == nil, let time = Self.ns(emittedAtNs), time >= lastEmission else { return .discarded("invalid_publication") }
        let old = translations[request.translationId]?.last
        var e = SpeechEvent(id: eventId, session: sessionId, sequence: lastAppliedSequence + 1, type: "translation.segment", timeNs: emittedAtNs)
        e.translationId = request.translationId; e.segmentId = request.segmentId; e.sourceRevision = request.sourceRevision
        e.sourceText = request.sourceText; e.targetLanguage = request.targetLanguage; e.translatedText = text
        e.glossaryRevision = request.glossaryRevision; e.revision = (old?.revision ?? 0) + 1
        e.replacesRevision = old?.revision; e.status = old == nil ? "final" : "corrected"
        guard let data = try? e.encoded(), receive(data, nowMs: nowMs) == .applied(e.eventSeq) else { return .discarded("publication_rejected") }
        requests.removeValue(forKey: request.translationId)
        return .published(e)
    }
}
