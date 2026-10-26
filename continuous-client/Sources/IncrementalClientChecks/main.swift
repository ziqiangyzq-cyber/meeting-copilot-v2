import Foundation
import Darwin
import AVFoundation
import ClientRuntime
import MeetingCopilotCore
import LocalTranslationEngine
import IncrementalArchive
import ClientIncrementalBridge
import SpeechCore
import RotatingSpeechSession
import DesktopSessionController
import MeetingCopilotAudioCapture
import AppleOfflineSpeech

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckFailure.failed(message) }
}
enum CheckFailure: Error { case failed(String) }
func freshDirectory(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
/// Fails selected fault points behind a gate so tests can hold the writer mid-write.
final class FaultGate: @unchecked Sendable {
    let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var armed: Bool
    private var triggered = false
    let point: ArchiveFaultPoint
    init(_ point: ArchiveFaultPoint, armed: Bool = true) { self.point = point; self.armed = armed }
    func arm() { lock.lock(); armed = true; lock.unlock() }
    func inject(_ candidate: ArchiveFaultPoint) throws {
        lock.lock()
        let fail = armed && !triggered && candidate == point
        if fail { triggered = true }
        lock.unlock()
        guard fail else { return }
        _ = gate.wait(timeout: .now() + 10)
        throw ArchiveFailure.injected(point)
    }
    func release() { gate.signal() }
}
func limits() throws -> CoreLimits {
    try CoreLimits(maxBufferedEvents: 64, maxBufferedBytes: 1 << 20, reorderTimeoutMs: 100, recoveryTimeoutMs: 2000)
}
func wire(_ session: String, _ sequence: Int, _ segment: String, _ revision: Int, _ text: String, status: String = "final") throws -> Data {
    var event = SpeechEvent(id: "actual-\(sequence)", session: session, sequence: sequence, type: "asr.segment", timeNs: String(sequence))
    event.segmentId = segment; event.revision = revision; event.status = status; event.text = text
    event.startNs = "0"; event.endNs = "1"
    return try event.encoded()
}
@main struct IncrementalClientChecks {
    static func main() async throws {
        setvbuf(stdout, nil, _IONBF, 0)
        if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--projection-child" {
            let directory = URL(fileURLWithPath: CommandLine.arguments[2])
            let expected = try JSONDecoder().decode(LocalArchive.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3])))
            let model = await ClientModel(directory: directory, configURL: probeConfigURL)
            let enabled = await model.enableIncrementalPersistence(limits: try limits())
            let actual = await model.archive
            try require(enabled && actual == expected, "independent process full archive exact projection")
            print("PASS independent-process full LocalArchive projection")
            return
        }
        if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--crash-child" {
            let directory = URL(fileURLWithPath: CommandLine.arguments[2])
            let bridge = try await ClientArchiveBridge.open(directory: directory, limits: try limits())
            let fence = ArchiveFence(sessionID: "kill-session", attemptID: "kill-attempt", generationID: UUID())
            _ = try await bridge.submit(fence: ArchiveFence(sessionID: "kill-session"), deltas: [.sessionOpened(title: "kill fixture")])
            _ = try await bridge.flush()
            _ = try await bridge.submit(fence: fence, deltas: [.attemptBegan(requiresTerminalCoverage: true)])
            _ = try await bridge.flush()
            _ = try await bridge.submit(fence: fence, deltas: [.canonicalBatch([CanonicalObservation(kind: .terminalCoverage,
                fields: ["completionCoverageValid": .boolean(true)])])])
            _ = try await bridge.flush(durability: .fsync)
            try Data("coverage-fsynced".utf8).write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
            while true { try await Task.sleep(nanoseconds: 100_000_000) }
        }
        try await dirtyLedgerAndOldWriteDoesNotClearNew()
        try await saveFailureRetainsAllRevisions()
        try await terminalBarrierAndCrashRestart()
        try await closeGateAndFastReopen()
        try await idempotentConflictRetry()
        try await realClientModelCaptureBarrier()
        try await interruptionBetweenCoverageAndCompleted()
        try await terminalGatesAndBoundedLedger()
        try await reducerInvalidWireRejectedBeforeWrite()
        try await exactBootstrapNotesTextAndTranslations()
        try await bootstrapInvalidInputsAndNoInventedProjection()
        try exactCanonicalScalarBits()
        try await exactCancelledIncompleteAndNullableTasks()
        try await realClientModelCancelledAndFailedRestart()
        try await closeGateCallerPendingAndReportedFailure()
        print("IncrementalClientChecks: all synthetic groups passed. No real capture, no legacy migration.")
    }

    @MainActor static func exactBootstrapNotesTextAndTranslations() async throws {
        let directory = try freshDirectory("incl-full-bootstrap")
        let model = ClientModel(directory: directory, configURL: probeConfigURL, translationOperation: { job in
            .init(job: job, translatedText: "合成译文: \(job.sourceText)", engine: "synthetic-check-only")
        })
        var initial = LocalSession(id: "exact-empty", title: "原标题", isDemo: true, notes: "initial notes without invented revision", tags: ["", "重复", "重复", "Sample"])
        initial.createdAt = Date(timeIntervalSinceReferenceDate: Double(bitPattern: 0x41b25a94d7abcdef))
        model.archive.sessions = [initial]; model.selection = initial.id
        let enabled = await model.enableIncrementalPersistence(limits: try limits())
        try require(enabled, "complete bootstrap enabled for empty content with actual initial notes/tags")
        _ = try await model.incremental!.awaitQuiescence()
        let seed = try LocalArchiveProjection.archive(model.incremental!.projection!)
        try require(seed == model.archive && seed.sessions[0].noteHistory.isEmpty, "initial notes must not invent note history")
        model.notes("一版", id: initial.id); model.notes("二版", id: initial.id)
        model.title("新标题", id: initial.id); model.tags("甲,乙,甲", id: initial.id)
        model.inputText = "First exact source"; model.submitText(translate: true)
        try await waitUntil(timeout: 4) { model.archive.sessions[0].segments.first?.translations.count == 1 }
        let firstSegment = model.archive.sessions[0].segments[0].id
        model.targetLanguage = "en"; model.translateSegment(sessionID: initial.id, segmentID: firstSegment)
        try await waitUntil(timeout: 4) { model.archive.sessions[0].segments.first?.translations.count == 2 }
        model.editingSegmentID = nil; model.inputText = "Second source"; model.submitText(translate: false)
        _ = try await model.incremental!.awaitQuiescence()
        let expected = model.archive
        let close = await model.closeIncrementalPersistence()
        try require(close.closed, "full typed store close")
        let reopened = ClientModel(directory: directory, configURL: probeConfigURL)
        let restored = await reopened.enableIncrementalPersistence(limits: try limits())
        try require(restored && reopened.archive == expected, "all title/tags/date/demo/notes/history/segments/translations/order/wire exact")
        try require(reopened.archive.sessions[0].createdAt.timeIntervalSinceReferenceDate.bitPattern == initial.createdAt.timeIntervalSinceReferenceDate.bitPattern, "bootstrap date original bits")
        for (a,b) in zip(expected.sessions[0].noteHistory, reopened.archive.sessions[0].noteHistory) {
            try require(a.savedAt.timeIntervalSinceReferenceDate.bitPattern == b.savedAt.timeIntervalSinceReferenceDate.bitPattern, "notes actual savedAt bits")
        }
        let before = try await IncrementalArchiveWriter.inspect(directory: reopened.incrementalDataDirectory)
        try require(before.records.first?.submission.deltas.first == .sessionBootstrap(ArchiveSessionBootstrap(title: initial.title, createdAtReferenceBits: initial.createdAt.timeIntervalSinceReferenceDate.bitPattern, isDemo: initial.isDemo, initialNotes: initial.notes, tags: initial.tags)), "bootstrap has exact fields")
        // Per-field absolute assertions on the durable wire, not only whole-archive equality: a same-on-both-sides
        // mistake in writing and projecting would still pass an equality check.
        let presentations = before.records.flatMap { record in record.submission.deltas.compactMap { delta -> (segmentID: String, language: String?, index: UInt64)? in
            guard case .segmentPresentation(let segmentID, let language, let index) = delta else { return nil }
            return (segmentID, language, index) } }
        let reopenedSegmentIDs = reopened.archive.sessions[0].segments.map(\.id)
        // Absolute locale assertions, one case each: this store is explicitly typed text with no recognizer, so
        // the only correct durable value is nil. A store that silently invented "zh-CN" must fail here.
        try require(reopenedSegmentIDs.count == 2 && presentations.count == 2,
                    "typed bootstrap must project exactly 2 segments and 2 presentations, got \(reopenedSegmentIDs.count) and \(presentations.count)")
        try require(reopened.archive.sessions[0].segments.allSatisfy { $0.current?.sourceLanguage == nil },
                    "typed text segments must reopen with nil source language, got \(reopened.archive.sessions[0].segments.map { $0.current?.sourceLanguage })")
        try require(presentations.map(\.segmentID) == reopenedSegmentIDs,
                    "every reopened segment needs its durable presentation in order, got \(presentations.map(\.segmentID)) vs \(reopenedSegmentIDs)")
        try require(presentations.map(\.index) == Array(0..<UInt64(presentations.count)),
                    "presentation insertion index must be the exact 0..n-1 first-insertion order, got \(presentations.map(\.index))")
        try require(presentations.allSatisfy { $0.language == nil },
                    "typed text must carry no invented source language, got \(presentations.map(\.language))")
        // Absolute translation assertions: restored text/revision/source binding/target language must be the real
        // values, not merely equal to a copy that could be wrong the same way on both sides. This store holds two
        // translations of the same source revision under two different target languages (zh-Hans then en), each
        // at revision 1 — that is the actual product semantics, not a single re-translated revision 2.
        let translations = reopened.archive.sessions[0].segments.flatMap(\.translations)
        try require(translations.count == 2,
                    "reopened store must hold exactly the two real translations, got \(translations.count)")
        try require(translations.map(\.targetLanguage).sorted() == ["en", "zh-Hans"],
                    "the two translations must be the real target languages en and zh-Hans, got \(translations.map(\.targetLanguage))")
        try require(translations.allSatisfy { $0.revision == 1 && $0.sourceRevision == 1 },
                    "each translation must keep its real revision 1 and source revision 1, got \(translations.map { ($0.revision, $0.sourceRevision) })")
        try require(translations.allSatisfy { $0.sourceText == "First exact source" && $0.text == "合成译文: First exact source" },
                    "translation text must match the real source and synthetic output, got \(translations.map { ($0.sourceText, $0.text) })")
        try require(Set(translations.map(\.id)).count == 2,
                    "the two translations must keep distinct real ids, got \(translations.map(\.id))")
        try require(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("sessions.json").path), "no whole archive fallback")
        let expectedURL = directory.appendingPathComponent("synthetic-equality-expected.json")
        try JSONEncoder().encode(expected).write(to: expectedURL)
        let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--projection-child", directory.path, expectedURL.path]
        let stdout = Pipe(), stderr = Pipe(); child.standardOutput = stdout; child.standardError = stderr
        try child.run(); child.waitUntilExit()
        let childOutput = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let childError = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        try require(child.terminationReason == .exit && child.terminationStatus == 0, "independent full projection child: \(childError)")
        try require(childOutput.contains("PASS independent-process full LocalArchive projection"), "child independently verified exact projection")
        print("PASS complete typed bootstrap + exact notes dates/text translations/order + LocalArchive reopen + independent process")
    }

    static func bootstrapInvalidInputsAndNoInventedProjection() async throws {
        let directory = try freshDirectory("incl-bootstrap-invalid")
        let bridge = try await ClientArchiveBridge.open(directory: directory, limits: try limits())
        let fence = ArchiveFence(sessionID: "s")
        let bootstrap = ArchiveSessionBootstrap(title: "s", createdAtReferenceBits: 0x41b25a94d7abcdef, isDemo: false, initialNotes: "unchanged", tags: ["", "dup", "dup"])
        _ = try await bridge.submit(fence: fence, deltas: [.sessionBootstrap(bootstrap)]); _ = try await bridge.flush()
        let state = ArchiveCaptureState(lifecycle: "completed", failure: nil, deviceStarted: false, audioObserved: false, asrObserved: false, mode: nil, generationID: nil, appendedHistory: [])
        let invalid: [[ArchiveDelta]] = [
            [.sessionBootstrap(bootstrap)],
            [.notesVersion(revision: 2, text: "gap", savedAtReferenceBits: bootstrap.createdAtReferenceBits)],
            [.notesVersion(revision: 1, text: "nonfinite", savedAtReferenceBits: Double.nan.bitPattern)],
            [.captureState(attemptID: "missing", revision: 1, state: state)],
            [.segmentPresentation(segmentID: "missing", sourceLanguage: nil, insertionIndex: 0)],
            [.sessionMetadataRevision(revision: 1, title: "s", tags: Array(repeating: "", count: 129))]
        ]
        for deltas in invalid {
            var rejected = false
            do { _ = try await bridge.submit(fence: fence, deltas: deltas) } catch { rejected = true }
            try require(rejected, "invalid bootstrap/date/revision/owner/budget must reject")
        }
        var budgetRejected = false
        do {
            _ = try ArchiveLimits().reservation(ArchiveSubmission(expectedHead: 0, fence: fence, deltas: [
                .sessionBootstrap(ArchiveSessionBootstrap(title: "s", createdAtReferenceBits: bootstrap.createdAtReferenceBits, isDemo: false, initialNotes: "", tags: Array(repeating: "", count: 80))),
                .sessionMetadataRevision(revision: 1, title: "s", tags: Array(repeating: "", count: 80))]))
        } catch { budgetRejected = true }
        try require(budgetRejected, "bootstrap + metadata total tag count bounded")
        let after = try await bridge.flush()
        try require(after.confirmedHead == 1, "negative submissions cannot advance head")
        let legacyDirectory = try freshDirectory("incl-subset-not-full")
        let subset = try await ClientArchiveBridge.open(directory: legacyDirectory.appendingPathComponent("incremental"), limits: try limits())
        _ = try await subset.submit(fence: fence, deltas: [.sessionOpened(title: "old subset")]); _ = try await subset.flush()
        var rejected = false
        do { _ = try LocalArchiveProjection.archive(subset.state.acknowledgedProjection) } catch { rejected = true }
        try require(rejected, "subset without exact Date/bootstrap must refuse complete projection")
        let model = await ClientModel(directory: legacyDirectory, configURL: probeConfigURL)
        let firstEnable = await model.enableIncrementalPersistence(limits: try limits())
        let secondEnable = await model.enableIncrementalPersistence(limits: try limits())
        try require(!firstEnable && !secondEnable, "repeated enable cannot pretend subset is complete")
        let oversizedDirectory = try freshDirectory("incl-bootstrap-overbudget")
        let oversized = await ClientModel(directory: oversizedDirectory, configURL: probeConfigURL)
        await MainActor.run { oversized.archive.sessions = [LocalSession(id: "large", title: "large", notes: String(repeating: "x", count: 16 * 1024 + 1))] }
        let oversizedEnabled = await oversized.enableIncrementalPersistence(limits: try limits())
        let retained = await oversized.archive.sessions[0].notes
        try require(!oversizedEnabled && retained.utf8.count == 16 * 1024 + 1, "oversized bootstrap rejected and exact caller content retained")
        print("PASS bootstrap date/revision/owner/budget negative checks + no invented subset projection")
    }

    static func exactCanonicalScalarBits() throws {
        let nan: UInt64 = 0x7ff8000000000123, negativeZero: UInt64 = 0x8000000000000000
        let id = UUID(), epoch = UUID()
        var fields: [String: CanonicalScalar] = [
            "blockID": .uuid(id), "epochID": .uuid(epoch), "channel": .string("mic"), "startNs": .unsigned(0),
            "provenance": .string("fixture"), "basis": .string("fixture"), "mappingRevision": .unsigned(1),
            "sampleRate": .signed(16000), "channelCount": .unsigned(1), "encoding": .string("f32"),
            "globalFrameStart": .unsigned(0), "globalFrameEnd": .unsigned(4), "nominalStartNs": .unsigned(0), "nominalEndNs": .unsigned(250000),
            "rawSource": .string("mic"), "rawSampleRate": .float64Bits(Double.infinity.bitPattern), "rawHostSeconds": .float64Bits(negativeZero),
            "rawPresentationSeconds": .float64Bits(nan), "rawReceivedUptime": .float64Bits(0x3ff0000000000001), "estimatedPPMBits": .float64Bits(nan)
        ]
        let mapped = try CanonicalProjection.metadata([CanonicalObservation(kind: .mapped, fields: fields)]).blocks[0]
        try require(mapped.rawObservation.hostSeconds?.bitPattern == negativeZero && mapped.rawObservation.presentationSeconds?.bitPattern == nan,
            "raw negative zero/NaN payload exact")
        try require(mapped.estimatedPPM?.bitPattern == nan && mapped.rawObservation.sampleRate.bitPattern == Double.infinity.bitPattern, "diagnostic/raw nonfinite exact")
        fields["disposition"] = .string("fixture"); fields["backendAccepted"] = .boolean(false); fields["ownerReturned"] = .boolean(false)
        fields["taskLocalFrameStart"] = .signed(0); fields["taskLocalFrameEnd"] = .signed(4)
        fields["rangeStartNs"] = .unsigned(0); fields["rangeEndNs"] = .unsigned(250000)
        let settlement = try CanonicalProjection.metadata([CanonicalObservation(kind: .settled, fields: fields)]).settlements[0]
        try require(settlement.taskLocalRange?.presentationSeconds?.bitPattern == nan && settlement.taskLocalRange?.hostSeconds?.bitPattern == negativeZero, "raw range original bits")
        fields.removeValue(forKey: "rangeEndNs")
        var rejected = false
        do { _ = try CanonicalProjection.metadata([CanonicalObservation(kind: .settled, fields: fields)]) } catch { rejected = true }
        try require(rejected, "missing range endpoint must not invent zero")
        print("PASS canonical inverse IEEE754 NaN payload/inf/negative-zero bits + missing field rejection")
    }

    static func exactCancelledIncompleteAndNullableTasks() async throws {
        let directory = try freshDirectory("incl-terminal-nullable")
        let bridge = try await ClientArchiveBridge.open(directory: directory, limits: try limits())
        let sessionFence = ArchiveFence(sessionID: "s")
        let bootstrap = ArchiveSessionBootstrap(title: "terminals", createdAtReferenceBits: 0x41b25a94d7abcdef, isDemo: false, initialNotes: "", tags: [])
        _ = try await bridge.submit(fence: sessionFence, deltas: [.sessionBootstrap(bootstrap)]); _ = try await bridge.flush()
        var expected: [LocalCaptureAttempt] = []
        for index in 0..<3 {
            let id = "attempt-\(index)", generation = UUID()
            let fence = ArchiveFence(sessionID: "s", attemptID: id, generationID: generation)
            let outcome: ArchiveAttemptOutcome = index == 0 ? .cancelled : .incomplete("actual-failure-\(index)")
            let lifecycle = index == 0 ? "cancelled" : "incomplete"
            let reason: String? = index == 0 ? nil : "actual-failure-\(index)"
            var deltas: [ArchiveDelta] = [.captureInitialized(ArchiveCaptureIdentity(id: id, channelID: "mic", streamID: "", segmentID: "", locale: "zh-CN", tasksPresent: index != 0)),
                .captureState(attemptID: id, revision: 1, state: ArchiveCaptureState(lifecycle: lifecycle, failure: reason, deviceStarted: true, audioObserved: false, asrObserved: false, mode: "rotating", generationID: generation.uuidString, appendedHistory: ["actual-\(lifecycle)"]))]
            var local = LocalCaptureAttempt(id: id, channelID: "mic", streamID: "", segmentID: "", locale: "zh-CN")
            local.lifecycle = lifecycle; local.failure = reason; local.deviceStarted = true
            local.mode = "rotating"; local.generationID = generation.uuidString; local.history = ["actual-\(lifecycle)"]
            local.tasks = index == 0 ? nil : []
            if index == 2 {
                deltas.append(.captureTask(attemptID: id, streamID: "stream", segmentID: "segment", firstObservedBy: "actual-dispatched", finalObserved: false))
                local.tasks = [LocalCaptureTask(streamID: "stream", segmentID: "segment", firstObservedBy: "actual-dispatched")]
            }
            _ = try await bridge.submit(fence: sessionFence, deltas: deltas); _ = try await bridge.flush()
            _ = try await bridge.submit(fence: fence, deltas: [.attemptBegan(requiresTerminalCoverage: true)]); _ = try await bridge.flush()
            _ = try await bridge.submit(fence: fence, durability: .fsync) { head in [.attemptEnded(outcome: outcome, requiredCommitSequence: head)] }
            _ = try await bridge.flush(); expected.append(local)
        }
        _ = try await bridge.close()
        let reopened = try await ClientArchiveBridge.open(directory: directory, limits: try limits())
        _ = try await reopened.flush()
        let actual = try LocalArchiveProjection.archive(reopened.state.acknowledgedProjection)
        try require(actual.sessions[0].captureAttempts == expected, "cancelled/incomplete entire captures must reopen unchanged")
        try require(actual.sessions[0].captureAttempts[0].tasks == nil && actual.sessions[0].captureAttempts[1].tasks?.isEmpty == true && actual.sessions[0].captureAttempts[2].tasks?[0].sourceBlocks == nil, "nullable tasks/sourceBlocks are not normalized")
        try require(reopened.state.acknowledgedProjection.sessions["s"]!.attempts.values.filter { $0.outcome == .completed }.isEmpty, "cancelled/incomplete never become completed")
        print("PASS cancelled/incomplete exact reasons/history + nullable tasks/sourceBlocks + durable reopen")
    }

    @MainActor static func realClientModelCancelledAndFailedRestart() async throws {
        for failing in [false, true] {
            let directory = try freshDirectory(failing ? "incl-model-failed" : "incl-model-cancelled")
            let ports = FakePorts(); ports.throwAppend = failing
            let model = ClientModel(directory: directory, configURL: probeConfigURL,
                controller: DesktopSessionController(permissions: ports, capture: ports, backendFactory: { ports.backend(for: $0) }))
            model.archive.sessions = [LocalSession(id: "s", title: "noncompleted")]; model.selection = "s"; model.microphoneEnabled = true
            let enabled = await model.enableIncrementalPersistence(limits: try limits()); try require(enabled, "noncompleted enable")
            _ = try await model.incremental!.awaitQuiescence()
            await model.startCapture(configuration: RotatingSpeechConfiguration(sessionId: "s", channelId: "mic", source: .microphone,
                locale: .simplifiedChinese, maximumInputFrames: 8, maximumFramesPerBlock: 4, maximumBytesPerBlock: 1024,
                queueCapacityBlocks: 8, maximumBlocksPerPoll: 1, maximumFramesPerPoll: 4, maxRetiringTasks: 2, finishDeadlineSeconds: 1))
            ports.emit(position: 0)
            if failing { try await waitUntil(timeout: 4) { !model.captureActive } }
            else { model.cancelCapture() }
            _ = try await model.incremental!.awaitQuiescence()
            let expected = model.archive
            try require(expected.sessions[0].captureAttempts.last?.lifecycle == (failing ? "incomplete" : "cancelled"), "actual noncompleted lifecycle")
            if failing {
                try require(expected.sessions[0].captureAttempts.last?.failure != "publication_failure" && expected.sessions[0].captureAttempts.last?.failure != nil, "capture failure must retain controller reason, not invent IO failure")
            }
            let close = await model.closeIncrementalPersistence(); try require(close.closed, "noncompleted terminal must retire writer attempt")
            let ports2 = FakePorts()
            let reopened = ClientModel(directory: directory, configURL: probeConfigURL,
                controller: DesktopSessionController(permissions: ports2, capture: ports2, backendFactory: { ports2.backend(for: $0) }))
            let restored = await reopened.enableIncrementalPersistence(limits: try limits())
            try require(restored && reopened.archive == expected, "actual noncompleted rawcanonical/flags/history exactly reopened")
            try require(ports.state == .stopped && ports2.reads == 0 && ports2.starts == 0, "synthetic hardware stopped, no reopen start")
            try require(reopened.incremental!.projection!.sessions["s"]!.attempts.values.allSatisfy { $0.outcome != nil && $0.outcome != .completed }, "actual noncompleted outcome durable")
        }
        print("PASS real ClientModel cancelled + backend-failed terminal exact LocalArchive restart")
    }

    /// 1. Dirty ledger semantics: an older write completing must not clear a newer revision of the same key.
    static func dirtyLedgerAndOldWriteDoesNotClearNew() async throws {
        let directory = try freshDirectory("incl-dirty")
        let persistence = await IncrementalPersistence(directory: directory, limits: try limits())
        await persistence.start()
        try require(await persistence.isAvailable, "persistence must open on a fresh directory")
        await MainActor.run {
            persistence.openSession(id: "s", title: "脏账本")
            persistence.submitNotes(session: "s", revision: 1, text: "第一版")
            persistence.submitNotes(session: "s", revision: 2, text: "第二版")
        }
        // Both revisions are distinct dirty entries and both must be retained.
        try require(await persistence.unconfirmedRevisionCount == 3, "session + both note revisions stay dirty")
        let watermark = try await persistence.awaitQuiescence()
        print("DEBUG head=\(watermark.confirmedHead) dirty=\(await persistence.allDirtyRevisions.map { $0.key }) status=\(await persistence.status)")
        try require(watermark.confirmedHead == 3, "each accepted revision needs its own record")
        try require(await persistence.hasUnconfirmedWork == false, "acknowledged revisions clear only after their own ack")
        let projection = await persistence.projection
        try require(projection?.sessions["s"]?.notes.map(\.revision) == [1, 2], "every note revision retained in order")
        print("PASS dirty ledger + old-write isolation (head \(watermark.confirmedHead))")
    }

    /// 2. Write failure: capture stops and EVERY unconfirmed revision is retained, not just the last text.
    static func saveFailureRetainsAllRevisions() async throws {
        let directory = try freshDirectory("incl-failure")
        let gate = FaultGate(.beforeWrite, armed: false)
        let persistence = await IncrementalPersistence(directory: directory, limits: try limits(), fault: { try gate.inject($0) })
        await persistence.start()
        try require(await persistence.isAvailable, "open before fault")
        await MainActor.run {
            persistence.openSession(id: "s", title: "失败保留")
        }
        try await persistence.awaitQuiescence()
        gate.arm()
        await MainActor.run {
            persistence.submitNotes(session: "s", revision: 1, text: "不可丢的随记")
        }
        gate.release()
        try await Task.sleep(nanoseconds: 400_000_000)
        let unconfirmed = await persistence.allDirtyRevisions.map(\.key)
        try require(await persistence.lastFailure != nil, "real write failure must be visible")
        try require(await persistence.lastConfirmedHead == 1, "no false saved watermark past the confirmed prefix")
        try require(unconfirmed.contains("notes:s:1"), "all unconfirmed revisions retained: \(unconfirmed)")
        // Retry uses the same stable IDs; nothing may be silently skipped.
        await MainActor.run { persistence.retryUnconfirmed() }
        let watermark = try await persistence.awaitQuiescence()
        try require(watermark.confirmedHead == 2, "retry confirms both original records (session + note)")
        try require(await persistence.hasUnconfirmedWork == false, "retry clears only after real acks")
        print("PASS failure retains all revisions + same-ID retry")
    }

    /// 3. Terminal barrier: raw terminal only enters "saving"; completed needs coverage first.
    ///    A hard restart mid-barrier must leave the attempt explicitly unfinished, never completed.
    static func terminalBarrierAndCrashRestart() async throws {
        let directory = try freshDirectory("incl-terminal")
        let persistence = await IncrementalPersistence(directory: directory, limits: try limits())
        await persistence.start()
        let attempt = "attempt-1", generation = UUID()
        let fence = ArchiveFence(sessionID: "s", attemptID: attempt, generationID: generation)
        await MainActor.run {
            persistence.openSession(id: "s", title: "终态屏障")
            persistence.beginAttempt(fence: fence, requiresTerminalCoverage: true)
        }
        try await persistence.awaitQuiescence()
        await MainActor.run { persistence.markRawTerminal(attempt: attempt) }
        // Coverage is required, so completed must NOT be submitted yet.
        try await persistence.awaitQuiescence()
        try require(await persistence.hasUnconfirmedWork == false, "no pending work before coverage")
        // Raw terminal alone must not have written a completed record: restart shows an unfinished attempt.
        let before = try await IncrementalArchiveWriter.inspect(directory: directory)
        try require(before.unfinishedAttempts.contains(fence), "raw terminal must not complete the attempt")
        // Now supply the real caller-declared terminal coverage, then re-mark the terminal.
        await MainActor.run {
            persistence.submitCanonical(fence: fence, observations: [CanonicalObservation(kind: .terminalCoverage,
                fields: ["completionCoverageValid": .boolean(true), "fixtureCallerDeclared": .boolean(true)])])
        }
        try await persistence.awaitQuiescence()
        await MainActor.run { persistence.markRawTerminal(attempt: attempt) }
        try await persistence.awaitQuiescence()
        let after = try await IncrementalArchiveWriter.inspect(directory: directory)
        try require(!after.unfinishedAttempts.contains(fence), "coverage + completed retires the attempt")
        let projection = await persistence.projection
        try require(projection?.sessions["s"]?.attempts[fence]?.outcome == .completed, "completed outcome recorded")
        // Real restart on a new writer must read the same state and not invent durability.
        let reopened = await IncrementalPersistence(directory: directory, limits: try limits())
        await reopened.start()
        try require(await reopened.isAvailable, "restart opens the same store")
        try require(await reopened.lastConfirmedHead == after.head, "restart preserves actual head")
        try require(await reopened.projection?.sessions["s"]?.attempts[fence]?.outcome == .completed, "restart keeps real completed")
        print("PASS terminal barrier + restart (\(before.head) -> \(after.head))")
    }

    /// 4. Closing gate: closing refuses new writes and reports failure with unconfirmed revisions retained;
    ///    a fast reopen reads the exact durable prefix, never a half-written record.
    static func closeGateAndFastReopen() async throws {
        let directory = try freshDirectory("incl-close")
        let gate = FaultGate(.beforeWrite, armed: false)
        let persistence = await IncrementalPersistence(directory: directory, limits: try limits(), fault: { try gate.inject($0) })
        await persistence.start()
        // First write succeeds and is confirmed; then arm the fault so only the next revision fails.
        await MainActor.run { persistence.openSession(id: "s", title: "关闭门") }
        try await persistence.awaitQuiescence()
        gate.arm()
        await MainActor.run { persistence.submitNotes(session: "s", revision: 1, text: "关闭前最后一条") }
        gate.release()
        try await Task.sleep(nanoseconds: 400_000_000)
        try require(await persistence.hasUnconfirmedWork, "faulted revision must stay unconfirmed")
        try require(await persistence.lastConfirmedHead == 1, "confirmed prefix stays at the real watermark")
        // Retry the same stable IDs, then close normally.
        await MainActor.run { persistence.retryUnconfirmed() }
        let result = await persistence.close()
        if result.closed {
            // If the barrier could confirm it, the store must really be closed and clean.
            try require(await persistence.hasUnconfirmedWork == false, "closed only with zero unconfirmed")
        } else {
            try require(result.unconfirmed >= 1, "closing failure must retain unconfirmed revisions")
        }
        let recovery = try await IncrementalArchiveWriter.inspect(directory: directory)
        try require(recovery.incompleteTail == nil, "fast reopen must never see a half-written record")
        let reopened = await IncrementalPersistence(directory: directory, limits: try limits())
        await reopened.start()
        try require(await reopened.isAvailable, "fast reopen succeeds on the durable prefix")
        let head = await reopened.lastConfirmedHead
        try require(head >= 1, "fast reopen reads the confirmed prefix, head \(head)")
        print("PASS closing gate + fast reopen (closed=\(result.closed), head=\(head))")
    }

    /// 5. Idempotent recovery: a record written successfully but whose acknowledgement failed must be retried
    ///    by stable ID/sequence and recognised as already present; same ID with different content is a conflict.
    static func idempotentConflictRetry() async throws {
        let directory = try freshDirectory("incl-conflict")
        // Fault only at the acknowledgement point: the record reaches disk, but no ack is delivered.
        let fault = AckFault(.beforeAcknowledgement)
        let bridge = try await ClientArchiveBridge.open(directory: directory, limits: try limits(), fault: { try fault.inject($0) })
        let fence = ArchiveFence(sessionID: "conflict-session")
        let id = UUID()
        _ = try await bridge.submit(id: id, fence: fence, deltas: [.sessionOpened(title: "就绪")])
        try await Task.sleep(nanoseconds: 300_000_000)
        try require(bridge.writer.unconfirmedSubmissions.contains { $0.id == id } || bridge.writer.status.confirmedHead == 0,
                    "written-but-unacknowledged record retained")
        try require(bridge.writer.status.confirmedHead == 0, "no ack means no confirmed advance")
        // The record is already complete on disk; replay must resolve it as alreadyPresent, not conflict.
        try bridge.retryUnconfirmed()
        let watermark = try await bridge.flush()
        try require(watermark.confirmedHead == 1, "same-ID retry confirms the already-written record")
        // Same ID with different content must be an explicit identity conflict and must not advance the head.
        let headBefore = bridge.writer.status.confirmedHead
        do {
            _ = try await bridge.submit(id: id, fence: fence, deltas: [.sessionOpened(title: "被篡改")])
            _ = try await bridge.flush()
            throw CheckFailure.failed("identity conflict was silently accepted")
        } catch {
            let text = String(describing: error)
            try require(text.contains("identityConflict") || text.contains("conflict"), "conflict must be reported: \(text)")
        }
        try require(bridge.writer.status.confirmedHead == headBefore, "conflict must not advance the head")
        // A permanent conflict blocks the writer; closing must not pretend everything was saved.
        do {
            _ = try await bridge.close()
            throw CheckFailure.failed("blocked writer must not close cleanly after an identity conflict")
        } catch {
            let text = String(describing: error).lowercased()
            try require(text.contains("conflict"), "close failure must surface the conflict: \(text)")
        }
        try require(bridge.writer.status.blocked != nil, "blocked writer keeps the conflict explicit")
        print("PASS already-written retry via stable ID + explicit same-ID conflict")
    }

    /// 6. Real wiring: ClientRuntime.ClientModel + DesktopSessionController + fake permission/capture/backend only.
    ///    Proves the incremental capture barrier: a controller terminal is NOT completion, coverage+completed must
    ///    be durable first, and an interruption between coverage and completed leaves a real unfinished attempt
    ///    that a genuine restart observes (never an invented completion).
    @MainActor static func realClientModelCaptureBarrier() async throws {
        let directory = try freshDirectory("incl-clientmodel")
        let ports = FakePorts()
        let controller = DesktopSessionController(permissions: ports, capture: ports, backendFactory: { ports.backend(for: $0) })
        let model = ClientModel(directory: directory, configURL: probeConfigURL, controller: controller)
        let limits = try CoreLimits(maxBufferedEvents: 64, maxBufferedBytes: 1 << 20, reorderTimeoutMs: 100, recoveryTimeoutMs: 2000)
        model.archive.sessions = [LocalSession(id: "synth-rotating", title: "增量接线")]
        model.selection = "synth-rotating"
        model.microphoneEnabled = true
        let enabled = await model.enableIncrementalPersistence(limits: limits)
        try require(enabled, "incremental persistence must open")
        _ = try await model.incremental?.awaitQuiescence()
        let config = RotatingSpeechConfiguration(sessionId: "synth-rotating", channelId: "mic", source: .microphone,
            locale: .simplifiedChinese, maximumInputFrames: 8, maximumFramesPerBlock: 4, maximumBytesPerBlock: 1024,
            queueCapacityBlocks: 8, maximumBlocksPerPoll: 1, maximumFramesPerPoll: 4, maxRetiringTasks: 2,
            finishDeadlineSeconds: 1)
        await model.startCapture(configuration: config)
        for position in stride(from: 0, to: 8, by: 4) { ports.emit(position: position) }
        model.stopCapture()
        try await waitUntil(timeout: 8) { ports.endedTasks >= 1 }
        try await waitUntil(timeout: 8) { !model.captureActive }
        let watermark = try await model.incremental?.awaitQuiescence()
        try require(watermark?.confirmedHead ?? 0 >= 4, "sessionOpened + attempt + speech + canonical/coverage + completed")
        let durable = try await IncrementalArchiveWriter.inspect(directory: model.incrementalDataDirectory)
        try require(durable.unfinishedAttempts.isEmpty, "completed attempt must retire after real coverage")
        try require(durable.records.contains { record in
            record.submission.deltas.contains { if case .attemptEnded(let outcome, _) = $0 { return outcome == .completed }; return false }
        }, "a real completed record must exist")
        // Real restart: a fresh model on the same durable prefix sees the same completed outcome.
        let ports2 = FakePorts()
        let reopened = ClientModel(directory: directory, configURL: probeConfigURL,
            controller: DesktopSessionController(permissions: ports2, capture: ports2, backendFactory: { ports2.backend(for: $0) }))
        let reopenedEnabled = await reopened.enableIncrementalPersistence(limits: limits)
        try require(reopenedEnabled, "restart opens the same durable prefix")
        try require(reopened.archive == model.archive, "full LocalArchive capture/rawcanonical must reopen exactly")
        try require(reopened.archive.sessions[0].createdAt.timeIntervalSinceReferenceDate.bitPattern == model.archive.sessions[0].createdAt.timeIntervalSinceReferenceDate.bitPattern, "createdAt original binary64 bits")
        try require(reopened.incremental?.lastConfirmedHead ?? 0 == (watermark?.confirmedHead ?? 0), "restart preserves the confirmed head")
        try require(reopened.incremental?.projection?.sessions["synth-rotating"]?.attempts.values.contains { $0.outcome == .completed } == true,
                    "restart keeps the real completed outcome")
        // Per-field absolute checks against independent sources (the live queue and the live segment), so a
        // matching mistake on both the writing and the projecting side cannot pass by equality alone.
        let liveHighWater = controller.queueSnapshot?.statistics.highWaterBlocks
        let liveAccepted = controller.queueSnapshot?.statistics.acceptedBlocks
        let durableCoverage = reopened.archive.sessions[0].captureAttempts.last?.canonicalMetadata?.terminalCoverage
        let durableHighWater = durableCoverage?.queue?.highWaterBlocks
        // Scenario expectation, stated absolutely: this capture delivers two 4-frame blocks and polls at most one
        // block per poll, so the queue really held 2 blocks at its high water. Asserting the number itself (not
        // only accepted/consumed/released) is what closes the "same mistake on both sides" gap.
        try require(liveHighWater == 2 && liveAccepted == 2,
                    "synthetic scenario must really reach high water 2 blocks, got high \(String(describing: liveHighWater)) accepted \(String(describing: liveAccepted))")
        try require(durableHighWater == 2,
                    "durable queue.highWaterBlocks must be the scenario value 2, got \(String(describing: durableHighWater))")
        try require(durableHighWater == liveHighWater,
                    "durable queue.highWaterBlocks must equal the live queue high water \(String(describing: liveHighWater)), got \(String(describing: durableHighWater))")
        try require(durableCoverage?.queue?.acceptedBlocks == 2 && durableCoverage?.queue?.consumedBlocks == 2
                    && durableCoverage?.queue?.releasedBlocks == 0 && durableCoverage?.queue?.queuedBlocks == 0
                    && durableCoverage?.queue?.state == "stopped",
                    "durable queue accounting must stay self-consistent around the high water: \(String(describing: durableCoverage?.queue))")
        let durableLanguages = reopened.archive.sessions[0].segments.map { $0.current?.sourceLanguage }
        try require(!durableLanguages.isEmpty && durableLanguages.allSatisfy { $0 == "zh-CN" },
                    "reopened mic segments must carry the real recognizer locale zh-CN, got \(durableLanguages)")
        // The durable presentation wire must agree with the live segment order and locale, field by field.
        let durablePresentations = durable.records.flatMap { record in record.submission.deltas.compactMap { delta -> (segmentID: String, language: String?, index: UInt64)? in
            guard case .segmentPresentation(let segmentID, let language, let index) = delta else { return nil }
            return (segmentID, language, index) } }
        try require(durablePresentations.map(\.index) == Array(0..<UInt64(durablePresentations.count)),
                    "durable presentation insertion indices must be exact 0..n-1, got \(durablePresentations.map(\.index))")
        try require(durablePresentations.allSatisfy { $0.language == "zh-CN" },
                    "durable presentation must store the real source language, got \(durablePresentations.map(\.language))")
        try require(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("sessions.json").path),
                    "incremental mode must not leave a legacy whole-archive snapshot")
        // Only the synthetic ports served the real lifecycle; the restart itself must launch no permission/device.
        try require(ports.reads == 2 && ports.starts == 1, "the real lifecycle used exactly the injected synthetic ports (reads \(ports.reads), starts \(ports.starts))")
        try require(ports2.reads == 0 && ports2.starts == 0, "restart must not request permissions or start a device")
        print("PASS real ClientModel capture barrier + restart (coverage -> completed, head \(watermark?.confirmedHead ?? 0))")
    }

    @MainActor static func terminalGatesAndBoundedLedger() async throws {
        let directory = try freshDirectory("incl-gates")
        let p = IncrementalPersistence(directory: directory, limits: try limits())
        await p.start()
        p.openSession(id: "gates", title: "gates")
        let fence = ArchiveFence(sessionID: "gates", attemptID: "finite", generationID: UUID())
        p.beginAttempt(fence: fence, requiresTerminalCoverage: false)
        _ = try await p.awaitQuiescence()
        try require(p.projection?.sessions["gates"]?.attempts[fence]?.outcome == nil, "begin ack must not complete without raw terminal")
        p.submitCanonical(fence: fence, observations: [CanonicalObservation(kind: .mapped, fields: ["block": .unsigned(1)])])
        p.submitCanonical(fence: fence, observations: [CanonicalObservation(kind: .mapped, fields: ["block": .unsigned(2)])])
        _ = try await p.awaitQuiescence()
        try require(p.unconfirmedRevisionCount == 0 && p.retainedAdmissionCount == 0 && p.reservedLedgerBytes == 0,
                    "both same-kind acknowledged revisions clear their own ledger/task/reservation")
        try require(p.projection?.sessions["gates"]?.attempts[fence]?.observations.count == 2, "both canonical revisions retained")
        p.markCaptureFailed(attempt: "finite", reason: "synthetic failure")
        p.markRawTerminal(attempt: "finite")
        p.noteJournalBacklog(session: "gates", remaining: 0)
        _ = try await p.awaitQuiescence()
        try require(p.projection?.sessions["gates"]?.attempts[fence]?.outcome == nil, "failed attempt must not become completed")
        let limited = IncrementalPersistence(directory: try freshDirectory("incl-budget"), limits: try limits(),
            budget: BridgeLimits(maximumAdmittedCount: 2, maximumReservedBytes: 8 * 1024 * 1024))
        await limited.start(); limited.openSession(id: "limited", title: "budget")
        _ = try await limited.awaitQuiescence()
        limited.submitNotes(session: "limited", revision: 1, text: "first")
        limited.submitNotes(session: "limited", revision: 2, text: "second")
        limited.submitNotes(session: "limited", revision: 3, text: "caller retained third")
        try require(limited.unconfirmedRevisionCount == 2 && limited.lastFailure?.contains("LEDGER_BUDGET_FULL") == true,
                    "entry budget rejects third while retaining both admitted revisions")
        try require(limited.reservedLedgerBytes <= 8 * 1024 * 1024, "ledger bytes bounded")
        _ = try await limited.awaitQuiescence()
        limited.retryUnconfirmed()
        limited.submitNotes(session: "limited", revision: 3, text: "caller retained third")
        let close = await limited.close()
        try require(close.closed && limited.retainedAdmissionCount == 0, "close waits queued admission and ack")
        limited.submitNotes(session: "limited", revision: 4, text: "must remain in caller")
        try require(limited.unconfirmedRevisionCount == 0 && limited.lastFailure?.contains("CLOSING_GATE") == true,
                    "closed gate admits no new revision")
        print("PASS no-raw/failed terminal gates + same-kind ack isolation + bounded ledger + queued-close gate")
    }
    static func reducerInvalidWireRejectedBeforeWrite() async throws {
        let directory = try freshDirectory("incl-invalid-reducer")
        let bridge = try await ClientArchiveBridge.open(directory: directory, limits: try limits())
        _ = try await bridge.submit(fence: ArchiveFence(sessionID: "invalid"), deltas: [.sessionOpened(title: "invalid")])
        _ = try await bridge.flush()
        let bytes = try wire("invalid", 1, "orphan", 1, "typed delta valid; wire status invalid", status: "invalid-status")
        let ack = AckCounter()
        do {
            _ = try await bridge.submit(fence: ArchiveFence(sessionID: "invalid"), deltas: [try speechDelta(from: bytes)],
                onAcknowledged: { _ in ack.increment() })
            throw CheckFailure.failed("reducer-invalid new record accepted")
        } catch is CheckFailure { throw CheckFailure.failed("reducer-invalid new record accepted") }
        catch { /* expected pre-write reducer rejection */ }
        let watermark = try await bridge.flush()
        try require(watermark.confirmedHead == 1 && ack.count == 0 && bridge.state.acknowledgedProjection.head == 1,
                    "invalid wire never writes or receives successful acknowledgement")
        print("PASS schema-valid reducer-invalid new wire rejected before write (ack=0, head=1)")
    }

    /// Kill a separate producer process after coverage fsync and before any completed submission.
    static func interruptionBetweenCoverageAndCompleted() async throws {
        let directory = try freshDirectory("incl-sigkill")
        let marker = directory.appendingPathComponent("ready")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        child.arguments = ["--crash-child", directory.path, marker.path]
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        try child.run()
        defer { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while !FileManager.default.fileExists(atPath: marker.path) {
            guard child.isRunning, ProcessInfo.processInfo.systemUptime < deadline else { throw CheckFailure.failed("child did not reach coverage fsync") }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        try require(kill(child.processIdentifier, SIGKILL) == 0, "real SIGKILL delivered")
        child.waitUntilExit()
        try require(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGKILL, "child terminated by signal 9")
        let recovery = try await IncrementalArchiveWriter.inspect(directory: directory)
        try require(recovery.head == 3 && recovery.unfinishedAttempts.count == 1, "coverage durable, completed absent after kill")
        let reopened = await IncrementalPersistence(directory: directory, limits: try limits())
        await reopened.start()
        try require(await reopened.recoveredUnfinishedAttempts.count == 1, "reopen surfaces interrupted attempt")
        await MainActor.run { reopened.noteJournalBacklog(session: "kill-session", remaining: 0) }
        let watermark = try await reopened.awaitQuiescence()
        try require(watermark.confirmedHead == 3, "restart must not synthesize completed from durable coverage")
        try require(await reopened.projection?.sessions["kill-session"]?.attempts.values.allSatisfy { $0.outcome == nil } == true,
                    "interrupted recovery remains unfinished")
        print("PASS SIGKILL after coverage fsync before completed + actual restart (signal 9, head 3)")
    }

    /// 7. App close gate: a close may only report "everything saved" when the caller really holds nothing back.
    ///    Every case asserts the caller's exact in-memory content first, so a false success cannot hide behind it.
    @MainActor static func closeGateCallerPendingAndReportedFailure() async throws {
        // A/B: two real note revisions produced without awaiting; the second is rejected by the real ledger budget.
        // The bounded preflight really drains it (same revision/savedAt), so close may be true — but only if the
        // independent reopen is exactly equal to the caller's pre-close archive.
        let notesDirectory = try freshDirectory("incl-close-notes")
        let notesModel = ClientModel(directory: notesDirectory, configURL: probeConfigURL)
        notesModel.archive.sessions = [LocalSession(id: "caller-notes", title: "fixture")]; notesModel.selection = "caller-notes"
        let notesBudget = BridgeLimits(maximumAdmittedCount: 1, maximumReservedBytes: 8 * 1024 * 1024)
        let notesEnabled = await notesModel.enableIncrementalPersistence(limits: try limits(), budget: notesBudget)
        try require(notesEnabled, "caller-notes model opens with the real entry budget")
        let notesPersistence = notesModel.incremental!
        let seed = try await notesPersistence.awaitQuiescence()
        try require(seed.confirmedHead == 1 && notesPersistence.unconfirmedRevisionCount == 0 && seed.fsyncedHead == 1,
                    "seed bootstrap confirmed before any edit (head \(seed.confirmedHead))")
        try require(notesPersistence.projection?.sessions["caller-notes"]?.notes.isEmpty == true, "no note revision before editing")
        // Same MainActor, no await in between, then close directly (the "no intermediate quiescence" variant).
        notesModel.notes("A", id: "caller-notes")
        notesModel.notes("B", id: "caller-notes")
        let expectedNotes = notesModel.archive.sessions[0]
        let cachedA = expectedNotes.noteHistory[0], cachedB = expectedNotes.noteHistory[1]
        try require(expectedNotes.notes == "B" && expectedNotes.noteHistory.map(\.revision) == [1, 2]
                    && expectedNotes.noteHistory.map(\.text) == ["A", "B"], "caller retains both real note versions")
        try require(notesPersistence.lastFailure?.contains("LEDGER_BUDGET_FULL") == true, "second revision rejected by the real entry budget")
        let notesPending = notesModel.incrementalCloseReadiness()
        try require((notesPending.sessions["caller-notes"]?.notesVersions ?? 0) >= 1,
                    "caller readiness reports the unsubmitted note revision: \(notesPending.reason ?? "nil")")
        let notesClose = await notesModel.closeIncrementalPersistence()
        try require(notesClose.closed, "bounded preflight really drained both revisions: \(notesClose.reason ?? "nil")")
        try require(notesPersistence.status == .closed && !notesPersistence.isClosing, "closed store reports closed")
        try require(!notesModel.incrementalSavingStatus.contains("未确认"), "close status is not a failure text")
        let reopenedNotes = ClientModel(directory: notesDirectory, configURL: probeConfigURL)
        let notesRestored = await reopenedNotes.enableIncrementalPersistence(limits: try limits())
        try require(notesRestored && reopenedNotes.archive == notesModel.archive, "auto-drained close reopens exactly")
        try require(reopenedNotes.archive.sessions[0].noteHistory.map(\.revision) == [1, 2], "both revisions durable")
        for (a, b) in zip([cachedA, cachedB], reopenedNotes.archive.sessions[0].noteHistory) {
            try require(a.savedAt.timeIntervalSinceReferenceDate.bitPattern == b.savedAt.timeIntervalSinceReferenceDate.bitPattern,
                        "drained note revision keeps the caller's exact savedAt bits")
        }
        print("PASS close gate A/B: budget-rejected caller notes drained by preflight + exact reopen (head \(notesPersistence.lastConfirmedHead))")

        // B. journalBacklog is a real close blocker: wires the caller still holds must never be reported saved.
        let backlogDirectory = try freshDirectory("incl-close-backlog")
        let backlog = IncrementalPersistence(directory: backlogDirectory, limits: try limits())
        await backlog.start(); backlog.openSession(id: "backlog", title: "backlog")
        _ = try await backlog.awaitQuiescence()
        backlog.noteJournalBacklog(session: "backlog", remaining: 1)
        try require(backlog.unconfirmedRevisionCount == 0 && backlog.sessionsWithHeldJournal == 1, "caller-held wire is visible with an empty ledger")
        let backlogHead = backlog.lastConfirmedHead
        let backlogClose = await backlog.close()
        try require(!backlogClose.closed && backlogClose.reason != nil, "caller-held journal wire must block close")
        try require(backlogClose.reason!.contains("未提交转写 wire"), "close names the held wire: \(backlogClose.reason!)")
        try require(backlog.status != .closed && !backlog.isClosing, "blocked close leaves a usable decision")
        try require(backlog.lastConfirmedHead == backlogHead && backlog.unconfirmedRevisionCount == 0, "no invented wire/sequence and no head advance")
        // The same backlog after the caller really submits and confirms it is no longer a blocker.
        backlog.noteJournalBacklog(session: "backlog", remaining: 0)
        let backlogClose2 = await backlog.close()
        try require(backlogClose2.closed, "backlog cleared by the real caller then closes: \(backlogClose2.reason ?? "nil")")
        print("PASS close gate B(journalBacklog): held wire blocks close, head/wire retained, real clear then closes")

        // B2. Real ClientModel entry: budget-rejected asr wire is a caller-held journal backlog, drained by preflight.
        let modelBacklogDirectory = try freshDirectory("incl-close-model-backlog")
        let modelBacklog = ClientModel(directory: modelBacklogDirectory, configURL: probeConfigURL)
        modelBacklog.archive.sessions = [LocalSession(id: "s", title: "text backlog")]; modelBacklog.selection = "s"
        let modelBacklogBudget = BridgeLimits(maximumAdmittedCount: 1, maximumReservedBytes: 8 * 1024 * 1024)
        let modelBacklogEnabled = await modelBacklog.enableIncrementalPersistence(limits: try limits(), budget: modelBacklogBudget)
        try require(modelBacklogEnabled, "model backlog fixture opens")
        _ = try await modelBacklog.incremental!.awaitQuiescence()
        modelBacklog.inputText = "saved source"; modelBacklog.submitText(translate: false)
        try require(modelBacklog.archive.sessions[0].speechJournal.count == 2, "real journal holds both authoritative wires")
        try require(modelBacklog.incremental!.sessionsWithHeldJournal == 1, "rejected asr wire is a real caller-held backlog")
        let modelBacklogExpected = modelBacklog.archive
        let modelBacklogClose = await modelBacklog.closeIncrementalPersistence()
        try require(modelBacklogClose.closed, "preflight drained the held wire: \(modelBacklogClose.reason ?? "nil")")
        let modelBacklogReopened = ClientModel(directory: modelBacklogDirectory, configURL: probeConfigURL)
        let modelBacklogRestored = await modelBacklogReopened.enableIncrementalPersistence(limits: try limits())
        try require(modelBacklogRestored && modelBacklogReopened.archive == modelBacklogExpected, "held wire drained with real sequence then exact reopen")
        print("PASS close gate B2: real submitText journal backlog drained in order with exact reopen")

        // C. Product semantics for termination: an unfinished translation is cancelled and its late result is dropped.
        let translationDirectory = try freshDirectory("incl-close-translation")
        let gate = TranslationGate()
        let translationModel = ClientModel(directory: translationDirectory, configURL: probeConfigURL,
            translationOperation: { job in
                await gate.wait()
                return TranslationOutput(job: job, translatedText: "迟到的合成译文", engine: "synthetic-check-only")
            })
        translationModel.archive.sessions = [LocalSession(id: "t", title: "translation")]; translationModel.selection = "t"
        let translationEnabled = await translationModel.enableIncrementalPersistence(limits: try limits())
        try require(translationEnabled, "translation fixture opens")
        _ = try await translationModel.incremental!.awaitQuiescence()
        translationModel.inputText = "source to translate"; translationModel.submitText(translate: false)
        let sourceSegment = translationModel.archive.sessions[0].segments.first!.id
        let translationBefore = translationModel.archive
        translationModel.translateSegment(sessionID: "t", segmentID: sourceSegment)
        try await waitUntil(timeout: 4) { gate.started }
        try require(translationModel.pendingTranslationCount == 1 && translationModel.cancelledTranslationCount == 0,
                    "in-flight translation is reported as live, not finished")
        let livePending = translationModel.incrementalCloseReadiness()
        try require(livePending.activeTranslations == 1 && !livePending.isClean, "caller readiness blocks while a translation is live")
        let translationClose = await translationModel.closeIncrementalPersistence()
        try require(translationClose.closed, "cancelled-by-close translation does not block: \(translationClose.reason ?? "nil")")
        try require(translationModel.cancelledTranslationCount == 1, "cancelled but not yet ended is reported honestly")
        try require(translationModel.archive == translationBefore, "no translation was accepted before the close")
        gate.release()
        try await waitUntil(timeout: 4) { translationModel.activeTranslationCount == 0 }
        try require(translationModel.archive == translationBefore, "late translation result must never mutate the archive after close")
        let translationReopened = ClientModel(directory: translationDirectory, configURL: probeConfigURL)
        let translationRestored = await translationReopened.enableIncrementalPersistence(limits: try limits())
        try require(translationRestored && translationReopened.archive == translationBefore, "reopen keeps exactly the durable source text, no late translation")
        print("PASS close gate C: live translation blocks readiness, close cancels, late result dropped, reopen exact")

        // D. INPUT_REJECTED is the strong false case: the preflight can never drain it, so close must stay false.
        let oversizedDirectory = try freshDirectory("incl-close-oversized")
        let oversizedModel = ClientModel(directory: oversizedDirectory, configURL: probeConfigURL)
        oversizedModel.archive.sessions = [LocalSession(id: "oversized", title: "oversized")]; oversizedModel.selection = "oversized"
        let oversizedEnabled = await oversizedModel.enableIncrementalPersistence(limits: try limits())
        try require(oversizedEnabled, "oversized fixture opens")
        _ = try await oversizedModel.incremental!.awaitQuiescence()
        let oversizedText = String(repeating: "x", count: 16 * 1024 + 1)
        oversizedModel.notes(oversizedText, id: "oversized")
        let oversizedExpected = oversizedModel.archive
        try require(oversizedExpected.sessions[0].notes == oversizedText && oversizedExpected.sessions[0].noteHistory.count == 1,
                    "caller keeps the exact oversized note text")
        try require(oversizedModel.incremental!.lastFailure?.contains("INPUT_REJECTED") == true, "oversized note rejected with the real reason")
        try require(oversizedModel.incremental!.unconfirmedRevisionCount == 0, "rejected note never entered the ledger")
        let oversizedClose = await oversizedModel.closeIncrementalPersistence()
        try require(!oversizedClose.closed && oversizedClose.reason != nil, "oversized caller note must force a false close")
        try require(oversizedClose.reason!.contains("INPUT_REJECTED"), "false close keeps the original rejection reason: \(oversizedClose.reason!)")
        try require(oversizedModel.incremental!.status != .closed && !oversizedModel.incremental!.isClosing, "false close keeps the store usable")
        try require(oversizedModel.archive == oversizedExpected, "caller content retained unchanged, never truncated")
        try require(!oversizedModel.incrementalSavingStatus.contains("全部修订已确认"), "no all-saved wording after a false close")
        print("PASS close gate D: INPUT_REJECTED forces closed=false with the original reason and exact retained text")

        // E. WIRE_INPUT_LIMIT: caller bytes/sequence retained, head unchanged, close false.
        let wireDirectory = try freshDirectory("incl-close-wire")
        let wirePersistence = IncrementalPersistence(directory: wireDirectory, limits: try limits())
        await wirePersistence.start(); wirePersistence.openSession(id: "wire", title: "wire")
        _ = try await wirePersistence.awaitQuiescence()
        let oversizedWire = Data(repeating: 0x20, count: 24 * 1024 + 1)
        let wireAccepted = wirePersistence.submitWire(session: "wire", fence: ArchiveFence(sessionID: "wire"), wire: oversizedWire, sequence: 1)
        try require(!wireAccepted && wirePersistence.lastFailure?.contains("WIRE_INPUT_LIMIT") == true,
                    "oversized wire rejected before decoding with the real limit reason")
        try require(wirePersistence.unconfirmedRevisionCount == 0, "rejected wire never entered the ledger")
        wirePersistence.noteJournalBacklog(session: "wire", remaining: 1)
        let wireHead = wirePersistence.lastConfirmedHead
        let wireClose = await wirePersistence.close()
        try require(!wireClose.closed && wireClose.reason != nil, "held oversized wire must block close")
        try require(wirePersistence.lastConfirmedHead == wireHead && wirePersistence.status != .closed, "head unchanged, no renumbered or invented wire")
        try require(oversizedWire.count == 24 * 1024 + 1 && wirePersistence.lastFailure?.contains("WIRE_INPUT_LIMIT") == true,
                    "caller bytes and sequence retained with the original reason")
        print("PASS close gate E: WIRE_INPUT_LIMIT + held caller wire force closed=false, head \(wireHead) unchanged")

        // F. An explicit caller-reported local inconsistency blocks close until the caller really clears it.
        let reportedDirectory = try freshDirectory("incl-close-reported")
        let reported = IncrementalPersistence(directory: reportedDirectory, limits: try limits())
        await reported.start(); reported.openSession(id: "reported", title: "reported")
        _ = try await reported.awaitQuiescence()
        reported.reportCallerFailure(reason: "CAPTURE_HISTORY_REWRITTEN")
        let reportedHead = reported.lastConfirmedHead
        let reportedClose = await reported.close()
        try require(!reportedClose.closed, "explicit caller failure must block close")
        try require(reportedClose.reason?.contains("CAPTURE_HISTORY_REWRITTEN") == true, "original caller reason preserved: \(reportedClose.reason!)")
        try require(reported.unconfirmedRevisionCount == 0 && reported.lastConfirmedHead == reportedHead && !reported.isClosing,
                    "a caller report is not an invented ledger entry and does not advance the head")
        try require(reported.callerBlockingFailure?.contains("CAPTURE_HISTORY_REWRITTEN") == true, "caller blocking failure stays readable after the attempt")
        reported.clearCallerReportedFailure()
        try require(reported.callerBlockingFailure == nil, "explicit clear removes only the caller report")
        let reportedClose2 = await reported.close()
        try require(reportedClose2.closed, "after the real caller-side repair the store closes: \(reportedClose2.reason ?? "nil")")
        print("PASS close gate F: explicit caller failure blocks close, survives the attempt, clears only explicitly")
    }

}
/// Synthetic ports for the real-ClientModel group only. No real permission prompt and no real device.
@MainActor final class FakePorts: DesktopPermissionGateway, DesktopCapturePort {
    var reads = 0, starts = 0, endedTasks = 0
    var throwAppend = false
    var state: CaptureState = .idle
    var onStateChange: (@MainActor @Sendable (CaptureState) -> Void)?
    var handler: AudioFrameHandler?
    private var backends: [RotatingFakeBackend] = []
    private var identities: [RotatingSpeechTaskIdentity] = []
    func requestMicrophone() async -> Bool { reads += 1; return true }
    func requestSpeech() async -> Bool { reads += 1; return true }
    func start(intent: CaptureIntent, onFrame: @escaping AudioFrameHandler) throws { starts += 1; handler = onFrame; state = .running }
    func stop() { state = .stopped }
    func backend(for identity: RotatingSpeechTaskIdentity) -> any OfflinePCMRecognitionBackend {
        let backend = RotatingFakeBackend(identity: identity, owner: self); backends.append(backend); return backend
    }
    func ended() { endedTasks += 1 }
    func emit(position: Int) {
        let buffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 1000, channels: 1)!, frameCapacity: 4)!
        buffer.frameLength = 4
        for i in 0..<4 { buffer.floatChannelData![0][i] = Float(position + i) }
        handler?(AudioFrame(buffer: buffer, timestamp: SourceTimestamp(source: .microphone, hostSeconds: 12 + Double(position) / 1000,
            samplePosition: Int64(position), sampleRate: 1000, presentationSeconds: nil, receivedUptime: 999)))
    }
}
@MainActor final class RotatingFakeBackend: OfflinePCMRecognitionBackend {
    var osAuthorized = true
    private let identity: RotatingSpeechTaskIdentity
    private weak var owner: FakePorts?
    private var callback: (@MainActor @Sendable (SpeechBackendObservation) -> Void)?
    init(identity: RotatingSpeechTaskIdentity, owner: FakePorts) { self.identity = identity; self.owner = owner }
    func begin(locale: OfflineSpeechLocale, deliver: @escaping @MainActor @Sendable (SpeechBackendObservation) -> Void) throws { callback = deliver }
    func append(_ buffer: AVAudioPCMBuffer) throws {
        if owner?.throwAppend == true { throw CheckFailure.failed("synthetic append failure") }
        callback?(.hypothesis(text: "合成-" + identity.segmentId, isFinal: false))
    }
    func finishAudio() { callback?(.hypothesis(text: "合成final-" + identity.segmentId, isFinal: true)); owner?.ended() }
    func cancel() { owner?.ended() }
}
@MainActor let probeConfigURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("text-mode-config.json")
@MainActor func waitUntil(timeout: Double, _ predicate: @MainActor () -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while !predicate() {
        if ProcessInfo.processInfo.systemUptime >= deadline { throw CheckFailure.failed("synthetic wait timeout") }
        try await Task.sleep(nanoseconds: 2_000_000)
    }
}
final class AckFault: @unchecked Sendable {
    private let lock = NSLock()
    private var triggered = false
    let point: ArchiveFaultPoint
    init(_ point: ArchiveFaultPoint) { self.point = point }
    func inject(_ candidate: ArchiveFaultPoint) throws {
        lock.lock(); let fail = !triggered && candidate == point; if fail { triggered = true }; lock.unlock()
        guard fail else { return }
        throw ArchiveFailure.injected(point)
    }
}

/// Suspends a synthetic translation so the close gate is observed while the operation is genuinely in flight.
@MainActor final class TranslationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false
    private var released = false
    func wait() async {
        started = true
        if released { return }
        await withCheckedContinuation { self.continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
final class AckCounter: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func increment() { lock.lock(); value += 1; lock.unlock() }
}
