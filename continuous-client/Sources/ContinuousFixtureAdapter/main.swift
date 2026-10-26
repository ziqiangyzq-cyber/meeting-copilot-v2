import Foundation
import MeetingCopilotAudioCapture
import AppleOfflineSpeech
import RotatingSpeechSession
import DesktopSessionController
import SpeechCore
import MeetingCopilotCore
import ClientRuntime

@MainActor private func nullable<T>(_ value: T?) -> Any { if let value { return value }; return NSNull() }
@MainActor private func object<T: Encodable>(_ value: T) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
}
@MainActor private func wait(_ milliseconds: Int, until predicate: @MainActor () -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + Double(milliseconds) / 1000
    while !predicate() {
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw AdapterFailure("DRIVER_WAIT_TIMEOUT") }
        try await Task.sleep(nanoseconds: 2_000_000)
    }
}
private func freshStore(_ path: String) throws -> URL {
    guard !path.isEmpty else { throw AdapterFailure("STORE_DIR_REQUIRED") }
    let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    let fm = FileManager.default
    if fm.fileExists(atPath: url.path) {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              try fm.contentsOfDirectory(atPath: url.path).isEmpty else { throw AdapterFailure("STORE_DIR_MUST_BE_NEW_OR_EMPTY_NON_SYMLINK") }
    } else { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
    return url
}
private func inputData() throws -> Data {
    let env = ProcessInfo.processInfo.environment
    let path = env["INPUT_JSON"] ?? CommandLine.arguments.dropFirst().first
    let data: Data
    if let path, path != "-" {
        let basename = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        guard basename != "expected.json", !basename.hasSuffix(".expected.json") else { throw AdapterFailure("EXPECTED_FILE_IS_NOT_INPUT") }
        data = try Data(contentsOf: URL(fileURLWithPath: path))
    } else { data = FileHandle.standardInput.readDataToEndOfFile() }
    guard data.count <= 2_097_152 else { throw AdapterFailure("INPUT_TOO_LARGE") }
    return data
}
@MainActor private func run(_ input: FixtureInput, directory: URL) async throws -> [String: Any] {
    let config = input.textModeConfig.map { URL(fileURLWithPath: $0) } ??
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("text-mode-config.json")
    let record = AdapterRecord(), factory = FixtureFactory(input)
    var permission: FixturePermissions? = FixturePermissions(), capture: FixtureCapture? = FixtureCapture()
    var controller: DesktopSessionController? = DesktopSessionController(permissions: permission!, capture: capture!,
        backend: DormantFixtureBackend(), backendFactory: { try factory.make($0) })
    var model: ClientModel? = ClientModel(directory: directory, configURL: config, controller: controller!)
    weak var weakModel = model
    weak var weakController = controller
    weak var weakStore = model?.store
    guard model!.loaded, model!.error == nil else { throw AdapterFailure("CLIENT_LOAD_FAILED: \(model!.error ?? "unknown")") }
    model!.add(demo: false)
    guard let sessionID = model!.selection else { throw AdapterFailure("CLIENT_COULD_NOT_CREATE_SESSION") }
    if let text = input.typedBefore {
        model!.inputText = text; model!.submitText(translate: false); model!.editingSegmentID = nil
    }
    factory.beforeAppend = { index in
        do {
            let disk = try ArchiveStore(directory: directory).load()
            let metadata = disk.sessions.first { $0.id == sessionID }?.captureAttempts.last?.canonicalMetadata
            let block = metadata?.blocks.last?.blockID
            let association = metadata?.associations.last?.blockID
            record.preASR.append(PreASRObservation(taskIndex: index, blockID: block, associationID: association,
                associationDurable: block != nil && block == association, storeError: nil))
        } catch {
            record.preASR.append(PreASRObservation(taskIndex: index, blockID: nil, associationID: nil,
                associationDurable: false, storeError: String(describing: error)))
        }
    }
    model!.microphoneEnabled = true; model!.translateFinal = false
    let blocks = input.samples.count / input.blockFrames
    let emittedBlockLimit = input.firstAppendThrow == true ? 2 : blocks
    let configuration = RotatingSpeechConfiguration(sessionId: sessionID, channelId: "mic", source: .microphone,
        locale: .simplifiedChinese, maximumInputFrames: input.budget, maximumFramesPerBlock: UInt32(input.blockFrames),
        maximumBytesPerBlock: input.blockFrames * MemoryLayout<Float>.size,
        queueCapacityBlocks: input.queueCapacityBlocks ?? max(8, blocks), maximumBlocksPerPoll: 1,
        maximumFramesPerPoll: input.blockFrames, maxRetiringTasks: input.maxRetiringTasks ?? max(2, input.taskHypotheses.count),
        finishDeadlineSeconds: input.finishDeadlineSeconds ?? 2)
    await model!.startCapture(configuration: configuration)
    // Preserve the actual model callbacks installed by startCapture. Observer wrappers never project/store data.
    let originalRaw = controller!.onRotatingOutput, originalCanonical = controller!.onCanonicalOutput
    let originalState = controller!.onStateChange
    controller!.onCanonicalOutput = { output in
        originalCanonical?(output)
        switch output {
        case .mapped: record.order.append("mapped")
        case .associated: record.order.append("associated")
        case .settled: record.order.append("settled")
        case .terminalCoverage: record.order.append("terminalCoverage")
        }
    }
    controller!.onStateChange = { snapshot in
        originalState?(snapshot)
        switch snapshot.state { case .terminal, .failed: record.order.append("terminalSnapshot"); default: break }
    }
    controller!.onRotatingOutput = { output in
        switch output {
        case .transcript(let generation, let u):
            var observed = RawOutputObservation(kind: "transcript", generationID: generation.id)
            observed.streamID = u.streamId; observed.segmentID = u.segmentId; observed.text = u.text
            observed.status = u.status; observed.revision = u.revision; observed.replacesRevision = u.replacesRevision
            observed.frameStart = u.source.frameStart; observed.frameEnd = u.source.frameEnd
            observed.mappingRevision = u.source.mappingRevision; observed.startNS = String(u.source.startNs); observed.endNS = String(u.source.endNs)
            record.raw.append(observed); record.order.append("transcript:" + u.status)
        case .dispatched(let generation, let task, let timestamp, let range):
            var observed = RawOutputObservation(kind: "dispatched", generationID: generation.id)
            observed.streamID = task.streamId; observed.segmentID = task.segmentId
            observed.frameStart = range.frameStart; observed.frameEnd = range.frameEnd; observed.mappingRevision = range.mappingRevision
            observed.startNS = String(range.startNs); observed.endNS = String(range.endNs); observed.rawTimestamp = LocalRawObservation(timestamp)
            record.raw.append(observed); record.order.append("dispatched")
        case .terminal(let generation, let state):
            var observed = RawOutputObservation(kind: "terminal", generationID: generation.id)
            observed.terminalState = String(describing: state); record.raw.append(observed); record.order.append("rawTerminal")
            do {
                let disk = try ArchiveStore(directory: directory).load()
                record.terminalCoverageDurableBeforeRaw = disk.sessions.first { $0.id == sessionID }?.captureAttempts.last?.canonicalMetadata?.terminalCoverage != nil
            } catch { record.terminalDiskReadError = String(describing: error) }
        }
        originalRaw?(output)
    }
    var driverError: String?
    func observe(_ phase: String) {
        record.observeDriver(phase: phase, mode: String(describing: controller!.mode),
            snapshotState: String(describing: controller!.snapshot.state), captureActive: model!.captureActive,
            consumedBlocks: controller!.queueSnapshot?.statistics.consumedBlocks, backends: factory.backends)
    }
    var stopRequested = false
    do {
        observe("started")
        guard model!.captureActive else { throw AdapterFailure("CLIENT_START_DID_NOT_ACTIVATE: \(model!.captureStatus)") }
        // Synchronous bounded burst: firstAppendThrow deliberately submits exactly two blocks, not all remaining input.
        for block in 0..<emittedBlockLimit {
            let start = block * input.blockFrames
            try capture!.emit(input.samples[start..<(start + input.blockFrames)], position: start,
                rate: input.sampleRate, hostStart: input.hostStartSeconds ?? 12)
        }
        observe("pcmSubmitted")
        try await wait(input.timeoutMs ?? 5000) {
            observe("waitingForConsumption")
            return controller!.queueSnapshot?.statistics.consumedBlocks == UInt64(emittedBlockLimit) || !model!.captureActive
        }
        observe("consumptionWaitReturned")
        if model!.captureActive {
            if let text = input.typedDuring {
                model!.inputText = text; model!.submitText(translate: false); model!.editingSegmentID = nil
            }
            for taskIndex in input.finalOrder {
                guard model!.captureActive else { break }
                guard factory.backends.indices.contains(taskIndex) else { throw AdapterFailure("FINAL_ORDER_TASK_NOT_CREATED: \(taskIndex)") }
                let backend = factory.backends[taskIndex]
                observe("finalTarget:\(taskIndex)")
                if backend.finishes == 0 {
                    // A live task can only receive a normal final after genuine user stop and drain/endAudio.
                    if !stopRequested { model!.stopCapture(); stopRequested = true }
                    observe("stopRequestedForFinal:\(taskIndex)")
                    let awaitingFinals = factory.backends.filter {
                        $0.finishes > 0 && !$0.observations.contains(where: { $0.isFinal })
                    }.count
                    if awaitingFinals >= configuration.maxRetiringTasks {
                        // The owner cannot endAudio for this active task while every retirement slot awaits
                        // a preceding task's final. Do not reorder input finals or manufacture early finals.
                        driverError = "FINAL_ORDER_BLOCKED_BY_RETIRING_LIMIT: task=\(taskIndex), awaiting=\(awaitingFinals), limit=\(configuration.maxRetiringTasks)"
                        observe("finalOrderBlocked:\(taskIndex)")
                        break // Keep the real stopped/draining owner alive until its original deadline.
                    }
                    try await wait(input.timeoutMs ?? 5000) {
                        observe("waitingForEndAudio:\(taskIndex)")
                        return backend.finishes > 0 || !model!.captureActive
                    }
                    observe("endAudioWaitReturned:\(taskIndex)")
                    if backend.finishes == 0 {
                        driverError = "FINAL_TARGET_TERMINATED_BEFORE_END_AUDIO: task=\(taskIndex)"
                    }
                }
                if model!.captureActive && backend.finishes > 0 {
                    backend.sendFinalFromInput()
                    observe("finalInputDelivered:\(taskIndex)")
                }
            }
            if model!.captureActive && !stopRequested { model!.stopCapture(); stopRequested = true; observe("stopRequestedAfterFinals") }
        }
        try await wait(input.timeoutMs ?? 5000) {
            observe("waitingForTerminal")
            return !model!.captureActive
        }
        observe("terminalWaitReturned")
    } catch {
        let reason = String(describing: error)
        driverError = driverError.map { $0 + "; " + reason } ?? reason
        observe("driverException")
        model!.cancelCapture()
        try? await wait(1000) { !model!.captureActive }
        observe("cancelReturned")
    }
    let memoryArchive = model!.archive
    let diskArchive = try ArchiveStore(directory: directory).load()
    let selected = memoryArchive.sessions.first { $0.id == sessionID }
    let events = try (selected?.speechJournal ?? []).map { try SpeechEvent.decode($0) }
    let runtimeCoverage = controller!.canonicalCoverage.map(LocalCanonicalCoverage.init)
    let queue = controller!.queueSnapshot.map(LocalCanonicalQueue.init)
    let taskObservations = factory.backends.map { $0.observation }
    let sourceOrder = selected?.chronologicalSegments.map(\.id) ?? []
    let clientError = model!.error, captureStatus = model!.captureStatus, unsavedText = model!.unsavedCaptureText
    let permissionCounts: [String: Int] = ["microphone": permission!.microphoneRequests, "speech": permission!.speechRequests]
    let captureCounts: [String: Any] = ["starts": capture!.starts, "stops": capture!.stops,
        "emittedBlocks": capture!.emittedBlocks, "emittedFrames": capture!.emittedFrames, "state": String(describing: capture!.state)]
    let beforeDestroy = memoryArchive
    model = nil; controller = nil; permission = nil; capture = nil
    try await Task.sleep(nanoseconds: 25_000_000)
    let destroyed: [String: Bool] = ["model": weakModel == nil, "controller": weakController == nil, "store": weakStore == nil]
    // Restore with another fully fake set. Construction and store load never authorize/start capture.
    let reopenedPermission = FixturePermissions(), reopenedCapture = FixtureCapture(), reopenedFactory = FixtureFactory(input)
    let reopenedController = DesktopSessionController(permissions: reopenedPermission, capture: reopenedCapture,
        backend: DormantFixtureBackend(), backendFactory: { try reopenedFactory.make($0) })
    let reopened = ClientModel(directory: directory, configURL: config, controller: reopenedController)
    let reopenedSession = reopened.archive.sessions.first { $0.id == sessionID }
    let reopenedEvents = try (reopenedSession?.speechJournal ?? []).map { try SpeechEvent.decode($0) }
    var output: [String: Any] = [
        "case_id": nullable(input.caseId), "data_class": "synthetic", "session_id": sessionID,
        "driver_error": nullable(driverError), "client_error": nullable(clientError),
        "driver_phases": try object(record.driverPhases), "driver_phases_dropped": record.droppedDriverPhases,
        "capture_status": captureStatus, "unsaved_text": nullable(unsavedText),
        "permissions": permissionCounts, "capture": captureCounts, "task_pcm": try object(taskObservations),
        "raw_outputs": try object(record.raw), "callback_order": record.order,
        "pre_asr_disk": try object(record.preASR),
        "terminal_coverage_durable_before_raw": nullable(record.terminalCoverageDurableBeforeRaw),
        "terminal_disk_error": nullable(record.terminalDiskReadError),
        "global_sequences": events.map(\.eventSeq), "source_order_segment_ids": sourceOrder,
        "journal_events": try events.map { try JSONSerialization.jsonObject(with: $0.encoded()) },
        "queue": try queue.map { try object($0) } ?? NSNull(),
        "canonical_coverage": try runtimeCoverage.map { try object($0) } ?? NSNull(),
        "memory_archive": try object(memoryArchive), "disk_archive": try object(diskArchive),
        "memory_equals_disk": memoryArchive == diskArchive, "destroyed": destroyed,
        "reopened_archive": try object(reopened.archive), "reopen_loaded": reopened.loaded,
        "reopen_equals_before_destroy": reopened.archive == beforeDestroy,
        "reopen_global_sequences": reopenedEvents.map(\.eventSeq),
        "reopen_permission_requests": reopenedPermission.microphoneRequests + reopenedPermission.speechRequests,
        "reopen_capture_starts": reopenedCapture.starts, "reopen_backend_count": reopenedFactory.backends.count,
        "submitted_input_samples": Array(input.samples.prefix(emittedBlockLimit * input.blockFrames)),
        "unsubmitted_input_samples": Array(input.samples.dropFirst(emittedBlockLimit * input.blockFrames))
    ]
    output["unique_stream_ids"] = Set(taskObservations.map(\.streamID)).count == taskObservations.count
    output["unique_segment_ids"] = Set(taskObservations.map(\.segmentID)).count == taskObservations.count
    return output
}
@main struct ContinuousFixtureAdapter {
    @MainActor static func main() async {
        do {
            let input = try FixtureInput.decode(inputData())
            guard let store = ProcessInfo.processInfo.environment["STORE_DIR"] else { throw AdapterFailure("STORE_DIR_REQUIRED") }
            let output = try await run(input, directory: freshStore(store))
            let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
            try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
            // Execution success only: independent QA compares actual observations, no hard-coded pass.
        } catch {
            let output: [String: Any] = ["adapter_error": String(describing: error), "data_class": "synthetic"]
            if let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]) {
                try? FileHandle.standardOutput.write(contentsOf: data + Data([10]))
            }
            exit(2)
        }
    }
}
