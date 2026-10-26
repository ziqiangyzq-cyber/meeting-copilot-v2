import Foundation
import SpeechCore
import AppleOfflineSpeech

public struct TextModeConfig: Codable {
    public let maxBufferedEvents: Int, maxBufferedBytes: Int
    public let reorderTimeoutMs: UInt64, recoveryTimeoutMs: UInt64
    public func coreLimits() throws -> CoreLimits {
        try CoreLimits(maxBufferedEvents: maxBufferedEvents, maxBufferedBytes: maxBufferedBytes, reorderTimeoutMs: reorderTimeoutMs, recoveryTimeoutMs: recoveryTimeoutMs)
    }
    public static func load(_ url: URL) throws -> Self { try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)) }
}

// Producer for explicitly typed text. No audio capture and no assertion of full wire compliance.
public struct TextSessionCoordinator {
    public private(set) var core: SpeechReducer
    public private(set) var journal: [Data]
    private var languages: [String: String] = [:]
    public init(session: LocalSession, config: TextModeConfig) throws {
        core = try SpeechReducer(sessionId: session.id, limits: config.coreLimits())
        journal = session.speechJournal
        for segment in session.segments { languages[segment.id] = segment.current?.sourceLanguage }
        for data in journal {
            let e = try SpeechEvent.decode(data)
            guard core.receive(data, nowMs: 0) == .applied(e.eventSeq) else { throw CoreError.invalid("LOCAL_JOURNAL_INVALID") }
        }
        if journal.isEmpty {
            var e = nextEvent(type: "session.config"); e.glossaryRevision = 1; try publish(e)
        }
    }
    private func nextEvent(type: String) -> SpeechEvent {
        // Logical nanosecond markers for publication sequencing; source audio timestamps remain untouched.
        SpeechEvent(id: UUID().uuidString, session: core.sessionId, sequence: core.lastAppliedSequence + 1, type: type, timeNs: String((UInt64(core.lastEmittedAtNs) ?? 0) + 1))
    }
    private mutating func publish(_ event: SpeechEvent) throws {
        let data = try event.encoded()
        guard core.receive(data, nowMs: 0) == .applied(event.eventSeq) else { throw CoreError.invalid("LOCAL_PUBLICATION_REJECTED") }
        journal.append(data)
    }
    public mutating func submit(text: String, segmentID: String? = nil) throws -> SpeechEvent {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CoreError.invalid("EMPTY_TYPED_TEXT") }
        let id = segmentID ?? UUID().uuidString, old = core.currentSegment(id)
        if segmentID != nil, old == nil { throw CoreError.invalid("LEGACY_SEGMENT_NOT_IN_JOURNAL") }
        var e = nextEvent(type: "asr.segment")
        e.segmentId = id; e.text = text; e.revision = (old?.revision ?? 0) + 1; e.replacesRevision = old?.revision
        e.status = old == nil ? "final" : "corrected"
        e.startNs = old?.startNs ?? "0"; e.endNs = old?.endNs ?? "1"
        if old != nil { e.correctionReason = "authorized_review"; e.editorKind = "human" }
        try publish(e); return e
    }
    @discardableResult public mutating func ingestAudioFinal(segmentID: String, channelID: String, streamID: String,
                                                             channelKind: String, text: String, language: String,
                                                             source: PCMSourceRange) throws -> SpeechEvent {
        guard ["mic", "system", "audio_file"].contains(channelKind), source.endNs > source.startNs,
              core.currentSegment(segmentID) == nil else { throw CoreError.invalid("INVALID_AUDIO_FINAL") }
        try registerStream(channelID: channelID, streamID: streamID, channelKind: channelKind)
        var event = nextEvent(type: "asr.segment")
        event.segmentId = segmentID; event.channelId = channelID; event.streamId = streamID
        event.channelKind = channelKind; event.text = text; event.revision = 1; event.status = "final"
        event.startNs = String(source.startNs); event.endNs = String(source.endNs)
        event.sourceSpans = [SourceAudioSpan(channelId: channelID, streamId: streamID,
            frameStart: source.frameStart, frameEnd: source.frameEnd, mappingRevision: source.mappingRevision)]
        try publish(event); languages[segmentID] = language
        return event
    }

    public mutating func registerStream(channelID: String, streamID: String, channelKind: String = "mic") throws {
        if let stream = core.streams[streamID] {
            guard stream.channel == channelID, stream.kind == channelKind else { throw CoreError.invalid("STREAM_IDENTITY_MISMATCH") }
            return
        }
        var event = nextEvent(type: "audio.stream_opened")
        event.channelId = channelID; event.streamId = streamID; event.channelKind = channelKind
        try publish(event)
    }
    /// The only allocator of session event sequences, shared with typed text and translations.
    @discardableResult public mutating func ingest(_ update: OfflineTranscriptUpdate) throws -> SpeechEvent? {
        guard update.sessionId == core.sessionId else { throw CoreError.invalid("WRONG_CAPTURE_SESSION") }
        if let old = core.currentSegment(update.segmentId), update.revision <= (old.revision ?? 0) {
            // Old/duplicate callbacks cannot allocate another journal sequence.
            return nil
        }
        try registerStream(channelID: update.channelId, streamID: update.streamId)
        let envelope = nextEvent(type: "asr.segment")
        var event = update.event(id: envelope.eventId, sequence: envelope.eventSeq, emittedAtNs: UInt64(envelope.emittedAtNs)!)
        event.channelKind = "mic"
        try publish(event)
        languages[update.segmentId] = update.locale.rawValue
        return event
    }
    public mutating func captureLifecycle(channelID: String, state: String, failure: String? = nil) throws {
        var event = nextEvent(type: "pipeline.state")
        event.stage = "capture"; event.channelId = channelID; event.state = state
        try publish(event)
        if let failure {
            var error = nextEvent(type: "pipeline.error")
            error.stage = "capture"; error.channelId = channelID; error.code = failure
            try publish(error)
        }
    }
    public mutating func request(segmentID: String, targetLanguage: String) throws -> TranslationRequest {
        try core.requestTranslation(id: UUID().uuidString, translationId: "\(segmentID):\(targetLanguage)", segmentId: segmentID, targetLanguage: targetLanguage)
    }
    public mutating func accept(_ request: TranslationRequest, translatedText: String) throws -> SpeechEvent? {
        guard !translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CoreError.invalid("EMPTY_TRANSLATION") }
        let e = nextEvent(type: "translation.segment")
        switch core.acceptTranslation(request, text: translatedText, eventId: e.eventId, emittedAtNs: e.emittedAtNs, nowMs: 0) {
        case .discarded: return nil
        case .published(let event): journal.append(try event.encoded()); return event
        }
    }
    public func project(into session: inout LocalSession) {
        for (id, events) in core.segments {
            let sourceVersions = events.map { SourceRevision(revision: $0.revision!, text: $0.text!, status: $0.status!, startNS: $0.startNs!, endNS: $0.endNs!, channelID: $0.channelId, streamID: $0.streamId, sourceSpans: $0.sourceSpans, sourceLanguage: languages[id]) }
            let translations = core.translations.values.flatMap { $0 }.filter { $0.segmentId == id }.sorted {
                ($0.revision!, $0.eventSeq) < ($1.revision!, $1.eventSeq)
            }.map {
                LocalTranslation(id: $0.translationId!, revision: $0.revision!, sourceRevision: $0.sourceRevision!, sourceText: $0.sourceText!, targetLanguage: $0.targetLanguage!, text: $0.translatedText!)
            }
            let segment = LocalSegment(id: id, channelKind: events.last?.channelKind ?? "typed_text", revisions: sourceVersions, translations: translations)
            if let i = session.segments.firstIndex(where: { $0.id == id }) { session.segments[i] = segment }
            else { session.segments.append(segment) }
        }
        session.speechJournal = journal
    }
}
