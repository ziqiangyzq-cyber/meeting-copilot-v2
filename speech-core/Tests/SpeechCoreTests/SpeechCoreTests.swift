import Foundation
import SpeechCore

final class SpeechCoreTests {
    var failures = 0
    func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #fileID, line: UInt = #line) { if a != b { failures += 1; print("FAIL \(file):\(line): \(a) != \(b)") } }
    func XCTAssertNil<T>(_ value: T?, file: StaticString = #fileID, line: UInt = #line) { if value != nil { failures += 1; print("FAIL \(file):\(line): expected nil") } }
    func XCTAssertTrue(_ value: Bool, file: StaticString = #fileID, line: UInt = #line) { if !value { failures += 1; print("FAIL \(file):\(line): expected true") } }
    func XCTAssertThrowsError<T>(_ body: @autoclosure () throws -> T, file: StaticString = #fileID, line: UInt = #line) {
        do { _ = try body(); failures += 1; print("FAIL \(file):\(line): expected error") } catch { }
    }
    func XCTFail(_ message: String = "unexpected result", file: StaticString = #fileID, line: UInt = #line) { failures += 1; print("FAIL \(file):\(line): \(message)") }
    func core(events: Int = 4, bytes: Int = 10000) throws -> SpeechReducer {
        try SpeechReducer(sessionId: "synthetic", limits: CoreLimits(maxBufferedEvents: events, maxBufferedBytes: bytes, reorderTimeoutMs: 10, recoveryTimeoutMs: 20))
    }
    func event(_ seq: Int, _ type: String) -> SpeechEvent {
        SpeechEvent(id: "e\(seq)", session: "synthetic", sequence: seq, type: type, timeNs: String(seq * 100))
    }
    func config(_ seq: Int = 1, revision: Int = 1) -> SpeechEvent {
        var e = event(seq, "session.config"); e.glossaryRevision = revision; return e
    }
    func asr(_ seq: Int, revision: Int, status: String, text: String = "示例合成😀") -> SpeechEvent {
        var e = event(seq, "asr.segment"); e.segmentId = "s1"; e.revision = revision
        e.replacesRevision = revision == 1 ? nil : revision - 1; e.status = status; e.text = text
        e.startNs = "0"; e.endNs = "100"; e.speakerId = nil
        if status == "corrected" { e.correctionReason = "engine_revision"; e.editorKind = "engine" }
        return e
    }
    @discardableResult func feed(_ e: SpeechEvent, _ c: inout SpeechReducer, now: UInt64 = 0) throws -> IngestResult {
        c.receive(try e.encoded(), nowMs: now)
    }
    func stable() throws -> SpeechReducer {
        var c = try core(); try feed(config(), &c); try feed(asr(2, revision: 1, status: "final"), &c); return c
    }
    func stream(_ seq: Int, id: String, channel: String = "mic") -> SpeechEvent {
        var e = event(seq, "audio.stream_opened"); e.streamId = id; e.channelId = channel; e.channelKind = "synthetic"; return e
    }
    func gap(_ seq: Int, channel: String = "mic") -> SpeechEvent {
        var e = event(seq, "audio.gap"); e.gapId = "g1"; e.channelId = channel; e.streamId = "st1"; e.startNs = "50"; return e
    }
    func resumed(_ seq: Int) -> SpeechEvent {
        var e = event(seq, "audio.resumed"); e.gapId = "g1"; e.channelId = "mic"; e.previousStreamId = "st1"; e.newStreamId = "st2"; e.gapEndNs = "200"; return e
    }

    func testCodePointSliceAndBounds() throws {
        XCTAssertEqual(try CodePointText.slice("A😀中💰12元", start: 3, end: 6), "💰12")
        XCTAssertEqual(try CodePointText.slice("e\u{301}😀", start: 1, end: 2), "\u{301}")
        XCTAssertEqual(try CodePointText.slice("😀", start: 1, end: 1), "")
        XCTAssertThrowsError(try CodePointText.slice("😀", start: 0, end: 2))
        XCTAssertThrowsError(try CodePointText.slice("😀", start: -1, end: 1))
    }
    func testDeclaredRequestMetadataValidatedInCore() throws {
        var c = try stable()
        XCTAssertThrowsError(try c.requestTranslation(id: "bad", translationId: "t", segmentId: "s1", targetLanguage: "en", sourceRevision: 99, glossaryRevision: 1, requestGeneration: 1))
        XCTAssertThrowsError(try c.requestTranslation(id: "bad", translationId: "t", segmentId: "s1", targetLanguage: "en", sourceRevision: 1, glossaryRevision: 99, requestGeneration: 1))
        XCTAssertThrowsError(try c.requestTranslation(id: "bad", translationId: "t", segmentId: "s1", targetLanguage: "en", sourceRevision: 1, glossaryRevision: 1, requestGeneration: 99))
        let r = try c.requestTranslation(id: "good", translationId: "t", segmentId: "s1", targetLanguage: "en", sourceRevision: 1, glossaryRevision: 1, requestGeneration: 1)
        XCTAssertEqual(r.generation, 1)
    }
    func testAudioFileStreamFinalAndOverlapGuard() throws {
        for kind in ["mic", "system", "synthetic", "audio_file"] {
            var reducer = try core()
            var opened = stream(1, id: "file-stream", channel: "import")
            opened.channelKind = kind
            XCTAssertEqual(try feed(opened, &reducer), .applied(1))
            XCTAssertEqual(reducer.streams["file-stream"]?.kind, kind)
        }
        var c = try core()
        var opened = stream(1, id: "file-stream", channel: "import"); opened.channelKind = "audio_file"
        XCTAssertEqual(try feed(opened, &c), .applied(1))
        var chunk = event(2, "audio.chunk"); chunk.channelId = "import"; chunk.streamId = "file-stream"
        chunk.frameStart = 0; chunk.frameCount = 16; chunk.mappingRevision = 1
        chunk.startNs = "0"; chunk.endNs = "1000"; chunk.availability = "unavailable"
        XCTAssertEqual(try feed(chunk, &c), .applied(2))
        var final = asr(3, revision: 1, status: "final", text: "文件合成转录")
        final.channelId = "import"; final.streamId = "file-stream"
        final.sourceSpans = [SourceAudioSpan(channelId: "import", streamId: "file-stream", frameStart: 0, frameEnd: 16, mappingRevision: 1)]
        XCTAssertEqual(try feed(final, &c), .applied(3))
        XCTAssertEqual(try feed(final, &c), .duplicate)
        XCTAssertEqual(c.currentSegment("s1")?.text, "文件合成转录")
        XCTAssertEqual(c.currentSegment("s1")?.sourceSpans, final.sourceSpans)
        chunk.eventId = "file-overlap"; chunk.eventSeq = 4; chunk.emittedAtNs = "400"; chunk.frameStart = 1
        _ = try feed(chunk, &c)
        XCTAssertEqual(c.transport, .recoveryRequired); XCTAssertEqual(c.lastAppliedSequence, 3)
        XCTAssertEqual(c.chunks.count, 1); XCTAssertEqual(c.currentSegment("s1")?.revision, 1)
    }
    func testUnknownStreamKindsRejectedAtomically() throws {
        for kind in ["audio", "file", "Audio_File", "audio_file ", "", "unrecognized"] {
            var c = try core()
            var opened = stream(1, id: "invalid-stream", channel: "import"); opened.channelKind = kind
            _ = try feed(opened, &c)
            XCTAssertEqual(c.transport, .recoveryRequired); XCTAssertEqual(c.lastAppliedSequence, 0)
            XCTAssertTrue(c.streams.isEmpty); XCTAssertTrue(c.checkpoint().events.isEmpty)
            XCTAssertTrue(c.recoveryReason?.contains("INVALID_STREAM") == true)
        }
    }
    func testChunkMetadataDuplicatesAndOverlappingFrames() throws {
        var c = try core(); try feed(stream(1, id: "st1"), &c)
        var chunk = event(2, "audio.chunk"); chunk.channelId = "mic"; chunk.streamId = "st1"
        chunk.frameStart = 0; chunk.frameCount = 16; chunk.mappingRevision = 1; chunk.startNs = "0"; chunk.endNs = "1000"; chunk.availability = "unavailable"
        XCTAssertEqual(try feed(chunk, &c), .applied(2)); XCTAssertEqual(try feed(chunk, &c), .duplicate)
        XCTAssertEqual(c.chunks.count, 1); XCTAssertEqual(c.pipelineStates["capture:mic"], "recovering")
        chunk.eventId = "overlap"; chunk.eventSeq = 3; chunk.emittedAtNs = "300"; chunk.frameStart = 1
        _ = try feed(chunk, &c); XCTAssertEqual(c.transport, .recoveryRequired); XCTAssertEqual(c.chunks.count, 1)
    }
    func testJSONRoundTripUnknownSpeakerAndUnicodeText() throws {
        let e = asr(1, revision: 1, status: "final")
        XCTAssertEqual(try SpeechEvent.decode(e.encoded()), e)
        var c = try core(); try feed(e, &c)
        XCTAssertNil(c.currentSegment("s1")?.speakerId)
        XCTAssertEqual(c.currentSegment("s1")?.text, "示例合成😀")
    }
    func testOutOfOrderAndDuplicateMatchOrderedBaseline() throws {
        let events = [config(), asr(2, revision: 1, status: "partial"), asr(3, revision: 2, status: "final")]
        var ordered = try core(), shuffled = try core()
        for e in events { try feed(e, &ordered) }
        XCTAssertEqual(try feed(events[2], &shuffled), .buffered)
        XCTAssertEqual(shuffled.receivedHighWaterSequence, 3); XCTAssertEqual(shuffled.resumeSequence(), 0)
        try feed(events[0], &shuffled)
        XCTAssertEqual(try feed(events[1], &shuffled), .applied(3))
        XCTAssertEqual(try feed(events[2], &shuffled), .duplicate)
        XCTAssertEqual(shuffled.segments, ordered.segments); XCTAssertEqual(shuffled.bufferedCount, 0)
    }
    func testPartialCannotTranslateThenCorrectionInvalidatesTranslation() throws {
        var c = try core(); try feed(config(), &c); try feed(asr(2, revision: 1, status: "partial"), &c)
        XCTAssertThrowsError(try c.requestTranslation(id: "r0", translationId: "t1", segmentId: "s1", targetLanguage: "en"))
        try feed(asr(3, revision: 2, status: "final"), &c)
        let request = try c.requestTranslation(id: "r1", translationId: "t1", segmentId: "s1", targetLanguage: "en")
        guard case .published(let e) = c.acceptTranslation(request, text: "Synthetic test.", eventId: "t-event", emittedAtNs: "400", nowMs: 0) else { return XCTFail("not published") }
        XCTAssertEqual(e.revision, 1); XCTAssertEqual(e.sourceRevision, 2)
        try feed(asr(5, revision: 3, status: "corrected", text: "合成校订"), &c)
        XCTAssertNil(c.currentTranslation("t1")); XCTAssertEqual(c.translations["t1"]?.count, 1)
        XCTAssertEqual(c.currentSegment("s1")?.text, "合成校订")
    }
    func testOldSourceResponseCannotBlockNewRequestOrConsumeRevision() throws {
        var c = try stable()
        let old = try c.requestTranslation(id: "old", translationId: "t1", segmentId: "s1", targetLanguage: "en")
        try feed(asr(3, revision: 2, status: "corrected", text: "new synthetic"), &c)
        let new = try c.requestTranslation(id: "new", translationId: "t1", segmentId: "s1", targetLanguage: "en")
        XCTAssertEqual(c.acceptTranslation(old, text: "old", eventId: "old-event", emittedAtNs: "400", nowMs: 0), .discarded("stale_source"))
        XCTAssertEqual(c.lastAppliedSequence, 3)
        guard case .published(let e) = c.acceptTranslation(new, text: "new", eventId: "new-event", emittedAtNs: "400", nowMs: 0) else { return XCTFail() }
        XCTAssertEqual(e.revision, 1); XCTAssertEqual(e.eventSeq, 4)
        XCTAssertEqual(c.acceptTranslation(old, text: "old again", eventId: "old-again", emittedAtNs: "500", nowMs: 0), .discarded("stale_source"))
        XCTAssertEqual(c.currentTranslation("t1")?.translatedText, "new")
    }
    func testSameSourceSupersededRequestAndRepeatedResponseDiscarded() throws {
        var c = try stable()
        let r1 = try c.requestTranslation(id: "r1", translationId: "t", segmentId: "s1", targetLanguage: "en")
        let r2 = try c.requestTranslation(id: "r2", translationId: "t", segmentId: "s1", targetLanguage: "en")
        XCTAssertEqual(c.acceptTranslation(r1, text: "old", eventId: "o", emittedAtNs: "300", nowMs: 0), .discarded("superseded_request"))
        _ = c.acceptTranslation(r2, text: "new", eventId: "n", emittedAtNs: "300", nowMs: 0)
        XCTAssertEqual(c.acceptTranslation(r2, text: "duplicate", eventId: "n2", emittedAtNs: "400", nowMs: 0), .discarded("superseded_request"))
        XCTAssertEqual(c.translations["t"]?.count, 1)
    }
    func testGlossaryRevisionInvalidatesPendingResponse() throws {
        var c = try stable(); let r = try c.requestTranslation(id: "r", translationId: "t", segmentId: "s1", targetLanguage: "en")
        try feed(config(3, revision: 2), &c)
        XCTAssertEqual(c.acceptTranslation(r, text: "old glossary", eventId: "t", emittedAtNs: "400", nowMs: 0), .discarded("stale_glossary"))
    }
    func testSecondPublicationRevisionIsContiguousAndBound() throws {
        var c = try stable()
        let r1 = try c.requestTranslation(id: "r1", translationId: "t", segmentId: "s1", targetLanguage: "en")
        _ = c.acceptTranslation(r1, text: "first", eventId: "t1", emittedAtNs: "300", nowMs: 0)
        try feed(asr(4, revision: 2, status: "corrected"), &c)
        let r2 = try c.requestTranslation(id: "r2", translationId: "t", segmentId: "s1", targetLanguage: "en")
        guard case .published(let e) = c.acceptTranslation(r2, text: "second", eventId: "t2", emittedAtNs: "500", nowMs: 0) else { return XCTFail() }
        XCTAssertEqual(e.revision, 2); XCTAssertEqual(e.replacesRevision, 1); XCTAssertEqual(e.status, "corrected")
        XCTAssertThrowsError(try c.requestTranslation(id: "r3", translationId: "t", segmentId: "s1", targetLanguage: "fr"))
    }
    func testGapResumeDoesNotProveRunningAndOtherChannelIndependent() throws {
        var c = try core(); try feed(stream(1, id: "st1"), &c); try feed(stream(2, id: "sys", channel: "system"), &c)
        try feed(gap(3), &c); try feed(stream(4, id: "st2"), &c); try feed(resumed(5), &c)
        XCTAssertEqual(c.gaps["g1"]?.endNs, 200)
        XCTAssertEqual(c.pipelineStates["capture:mic"], "recovering"); XCTAssertEqual(c.pipelineStates["asr:mic"], "recovering")
        XCTAssertEqual(c.pipelineStates["capture:system"], "recovering")
        var running = event(6, "pipeline.state"); running.stage = "capture"; running.channelId = "mic"; running.state = "running"
        _ = try feed(running, &c); XCTAssertEqual(c.transport, .recoveryRequired)
        XCTAssertEqual(c.lastAppliedSequence, 5)
    }
    func testUnknownGapAndRepeatedCloseRejectedAtomically() throws {
        var unknown = try core(); _ = try feed(resumed(1), &unknown)
        XCTAssertEqual(unknown.lastAppliedSequence, 0); XCTAssertTrue(unknown.gaps.isEmpty)
        var c = try core(); try feed(stream(1, id: "st1"), &c); try feed(gap(2), &c); try feed(stream(3, id: "st2"), &c); try feed(resumed(4), &c)
        _ = try feed(resumed(5), &c); XCTAssertEqual(c.lastAppliedSequence, 4); XCTAssertEqual(c.gaps["g1"]?.endNs, 200)
    }
    func testIllegalRevisionFreezesWithoutReplayingPoisonForever() throws {
        var c = try stable(); let bad = asr(3, revision: 8, status: "corrected")
        _ = try feed(bad, &c); XCTAssertEqual(c.lastAppliedSequence, 2); XCTAssertEqual(c.receivedHighWaterSequence, 3)
        XCTAssertEqual(c.currentSegment("s1")?.revision, 1)
        XCTAssertEqual(try feed(bad, &c), .blocked)
        c.tick(nowMs: 20); XCTAssertEqual(c.transport, .recoveryUnavailable)
    }
    func testAuthoritativeReplayRecoveryMatchesBaselineAndInvalidatesRequests() throws {
        var c = try stable(), authority = try stable()
        let old = try c.requestTranslation(id: "r", translationId: "t", segmentId: "s1", targetLanguage: "en")
        let bad = asr(3, revision: 8, status: "corrected"); _ = try feed(bad, &c)
        let good = asr(3, revision: 2, status: "corrected"); try feed(good, &authority)
        XCTAssertThrowsError(try c.restore(authority.checkpoint(), nowMs: 1))
        try c.restore(authority.checkpoint(resolvedRejectedSequences: [3]), nowMs: 1)
        XCTAssertEqual(c.transport, .ready); XCTAssertEqual(c.segments, authority.segments); XCTAssertEqual(c.resumeSequence(), 3)
        XCTAssertEqual(c.acceptTranslation(old, text: "old", eventId: "old", emittedAtNs: "400", nowMs: 1), .discarded("stale_source"))
        XCTAssertEqual(try feed(good, &c, now: 1), .duplicate)
        try feed(asr(4, revision: 3, status: "corrected"), &c, now: 1); XCTAssertEqual(c.lastAppliedSequence, 4)
    }
    func testInvalidCheckpointAtomicAndPostRestoreRequestGenerationIncreases() throws {
        var c = try stable(); let r = try c.requestTranslation(id: "r1", translationId: "t", segmentId: "s1", targetLanguage: "en")
        let checkpoint = c.checkpoint()
        let incomplete = ReplayCheckpoint(sessionId: "synthetic", events: [asr(2, revision: 1, status: "final")])
        XCTAssertThrowsError(try c.restore(incomplete, nowMs: 0)); XCTAssertEqual(c.lastAppliedSequence, 2)
        try c.restore(checkpoint, nowMs: 0)
        XCTAssertEqual(c.acceptTranslation(r, text: "old", eventId: "old", emittedAtNs: "300", nowMs: 0), .discarded("superseded_request"))
        let fresh = try c.requestTranslation(id: "r2", translationId: "t", segmentId: "s1", targetLanguage: "en")
        XCTAssertEqual(fresh.generation, r.generation + 1)
    }
    func testBufferCountBytesAndTimeoutBounds() throws {
        var count = try core(events: 1); XCTAssertEqual(try feed(asr(3, revision: 2, status: "final"), &count), .buffered)
        _ = try feed(asr(4, revision: 3, status: "corrected"), &count)
        XCTAssertEqual(count.transport, .recoveryRequired); XCTAssertEqual(count.bufferedCount, 0); XCTAssertEqual(count.lastAppliedSequence, 0)
        var bytes = try core(bytes: 1); _ = try feed(config(2), &bytes); XCTAssertEqual(bytes.transport, .recoveryRequired)
        var timeout = try core(); try feed(config(3), &timeout, now: 0); try feed(config(4), &timeout, now: 9)
        timeout.tick(nowMs: 10); XCTAssertEqual(timeout.transport, .recoveryRequired)
        timeout.tick(nowMs: 30); XCTAssertEqual(timeout.transport, .recoveryUnavailable)
    }
    func testMalformedEnvelopeSequenceConflictAndNonMonotonicClock() throws {
        var c = try core(); _ = c.receive(Data("{}".utf8), nowMs: 0); XCTAssertEqual(c.lastAppliedSequence, 0)
        var conflict = try stable(); var duplicate = config(); duplicate.glossaryRevision = 9
        _ = try feed(duplicate, &conflict); XCTAssertEqual(conflict.transport, .recoveryRequired)
        var clock = try core(); try feed(config(), &clock, now: 5); clock.tick(nowMs: 4)
        XCTAssertEqual(clock.transport, .recoveryRequired)
        XCTAssertThrowsError(try CoreLimits(maxBufferedEvents: 0, maxBufferedBytes: 1, reorderTimeoutMs: 1, recoveryTimeoutMs: 1))
    }
}
