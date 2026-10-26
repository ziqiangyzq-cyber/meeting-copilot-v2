import Foundation
import AVFoundation
import MeetingCopilotAudioCapture
import MeetingCopilotPCMBridge
import AppleOfflineSpeech
import LocalASRProviders

public enum QwenControllerError: Error, Equatable, Sendable {
    case busy, notReady, invalidConfiguration, invalidPCM, discontinuousSource
    case backpressure, cancelled, drainTimeout, operationTimeout, microphoneDenied, userActionRequired
    case backend(String), noAudio
}
public enum QwenControllerState: Equatable, Sendable {
    case idle, loading, ready, requestingMicrophone, capturing, importing, draining, completed, cancelled
    case failed(QwenControllerError)
}
public enum QwenSegmentSource: String, Sendable { case microphone, systemAudio; case file = "audio_file" }
public struct QwenSessionBinding: Equatable, Sendable {
    public let sessionID: String, channelID: String, streamID: String
    public let source: QwenSegmentSource, mappingRevision: Int
    public let sourceURL: URL?
    public init(sessionID: String, channelID: String, streamID: String, source: QwenSegmentSource, mappingRevision: Int = 1, sourceURL: URL? = nil) {
        self.sessionID = sessionID; self.channelID = channelID; self.streamID = streamID
        self.source = source; self.mappingRevision = mappingRevision; self.sourceURL = sourceURL
    }
}
/// Historical facts for one attempt; engineAtStart never implies current readiness.
public struct QwenAttemptObservation: Equatable, Sendable {
    public let binding: QwenSessionBinding
    public let attemptID: UUID
    public let engineAtStart: ASREngineIdentity
    public let deviceStarted: Bool, audioObserved: Bool, asrObserved: Bool
    public init(binding: QwenSessionBinding, attemptID: UUID, engineAtStart: ASREngineIdentity,
                deviceStarted: Bool, audioObserved: Bool, asrObserved: Bool) {
        self.binding = binding; self.attemptID = attemptID; self.engineAtStart = engineAtStart
        self.deviceStarted = deviceStarted; self.audioObserved = audioObserved; self.asrObserved = asrObserved
    }
}
private func DesktopSessionControllerRecognitionID(attemptID: UUID, sequence: Int) -> String {
    "qwen-task-\(attemptID.uuidString)-\(sequence)"
}
public struct QwenSegmentFinal: Sendable {
    public let binding: QwenSessionBinding
    public let attemptID: UUID, sequence: Int
    public let recognitionStreamID: String
    public let sourceRange: PCMSourceRange
    public let text: String, language: String
    public let engine: ASREngineIdentity
    /// This is the captured segment extent, never word alignment.
    public let timingBasis = "source-audio-segment-not-word-alignment"
    public init(binding: QwenSessionBinding, attemptID: UUID, sequence: Int, sourceRange: PCMSourceRange,
                text: String, language: String, engine: ASREngineIdentity, recognitionStreamID: String? = nil) {
        self.binding = binding; self.attemptID = attemptID; self.sequence = sequence; self.sourceRange = sourceRange
        self.recognitionStreamID = recognitionStreamID ?? DesktopSessionControllerRecognitionID(attemptID: attemptID, sequence: sequence)
        self.text = text; self.language = language; self.engine = engine
    }
}
public struct QwenSegmentLimits: Sendable {
    // Accepted native PCM: float32 noninterleaved, 16k–192kHz, 1–8 channels.
    // Per-block bytes <= maximumFramesPerBlock * 8 * 4; ingress <= ingressBlocks * that.
    // Pending cap includes the active inference and its final awaiting durable writer ack.
    // Native mono assembly <= 8 * 192000 Float samples; queued native mono segments use same bound.
    public let segmentSeconds: Double, drainTimeoutSeconds: Double
    public let maximumPendingSegments: Int, ingressBlocks: Int, maximumFramesPerBlock: UInt32
    /// 1024 blocks at the common 10 ms/48 kHz tap cadence covers roughly
    /// 10 seconds. The former 32-block default covered only ~320 ms and
    /// overflowed before the first 8-second segment could complete.
    public init(segmentSeconds: Double = 8, maximumPendingSegments: Int = 4, ingressBlocks: Int = 1024,
                maximumFramesPerBlock: UInt32 = 8192, drainTimeoutSeconds: Double = 600) {
        self.segmentSeconds = segmentSeconds; self.maximumPendingSegments = maximumPendingSegments
        self.ingressBlocks = ingressBlocks; self.maximumFramesPerBlock = maximumFramesPerBlock
        self.drainTimeoutSeconds = drainTimeoutSeconds
    }
}
private struct PendingQwenSegment: Sendable {
    let pcm: QwenNativePCM, range: PCMSourceRange, sequence: Int
    let recognitionStreamID: String
}

/// No device opens at construction/load/import. One owner and one serial inference pump.
@MainActor public final class QwenSegmentController {
    public private(set) var state: QwenControllerState = .idle
    public private(set) var engine: ASREngineIdentity?
    public private(set) var deviceStarted = false, audioObserved = false, asrObserved = false
    public private(set) var attemptID: UUID?
    public private(set) var deliveredSegments = 0
    public private(set) var skippedNoSpeechSegments = 0
    public private(set) var highWaterPendingSegments = 0
    public private(set) var continuityFailureDescription: String?
    private var engineAtStart: ASREngineIdentity?
    public var attemptObservation: QwenAttemptObservation? {
        guard let binding, let attemptID, let engineAtStart else { return nil }
        return .init(binding: binding, attemptID: attemptID, engineAtStart: engineAtStart,
                     deviceStarted: deviceStarted, audioObserved: audioObserved, asrObserved: asrObserved)
    }
    public var onObservationChange: (@MainActor @Sendable (QwenAttemptObservation) -> Void)?
    private func publishObservation() {
        if let observation = attemptObservation { onObservationChange?(observation) }
    }
    public var onFinal: (@MainActor @Sendable (QwenSegmentFinal) -> Void)?
    public var onNoSpeech: (@MainActor @Sendable () -> Void)?
    public var commitFinal: (@MainActor @Sendable (QwenSegmentFinal) async throws -> Void)?
    public var onStateChange: (@MainActor @Sendable (QwenControllerState) -> Void)?
    public var queueSnapshot: PCMQueueSnapshot? { ingress?.queue.snapshot() }
    public var canReconfigure: Bool { !isBusy }
    private var isBusy: Bool {
        switch state { case .loading, .requestingMicrophone, .capturing, .importing, .draining: true; default: false }
    }
    private let backend: any QwenSegmentBackend
    private let permissions: any DesktopPermissionGateway
    private let microphone: any DesktopCapturePort
    private let limits: QwenSegmentLimits
    private var token = UUID(), binding: QwenSessionBinding?, configuration: ASRConfiguration?
    private var ingress: QwenPCMIngress?
    private var captureTask: Task<Void, Never>?, inferenceTask: Task<Void, Never>?, deadlineTask: Task<Void, Never>?
    private var operationDeadlineTask: Task<Void, Never>?
    private var pending: [PendingQwenSegment] = []
    private var activeInference = false
    private var assembly: [Float] = [], rate: Double?, anchorNs: UInt64?, totalFrames = 0, segmentStart = 0, sequence = 0
    private var nativeSampleEnd: Int64?
    private var previousHostNs: UInt64?, previousBlockFrames = 0
    private var io = QwenFileIO(), directory: URL?
    private var delivering = false
    private var activeCommit: (@MainActor @Sendable (QwenSegmentFinal) async throws -> Void)?
    private var progressWaiters: [CheckedContinuation<Void, Never>] = []
    private func progress() {
        let waiters = progressWaiters; progressWaiters = []
        for waiter in waiters { waiter.resume() }
    }
    private func waitForProgress() async {
        await withCheckedContinuation { progressWaiters.append($0) }
    }
    private func waitForInference(_ expected: UUID) async throws {
        while activeInference || !pending.isEmpty { try check(expected); await waitForProgress() }
        try check(expected)
    }
    public init(backend: (any QwenSegmentBackend)? = nil, permissions: (any DesktopPermissionGateway)? = nil,
                microphone: (any DesktopCapturePort)? = nil, limits: QwenSegmentLimits = .init()) {
        self.backend = backend ?? ProductionQwenSegmentBackend()
        self.permissions = permissions ?? SystemDesktopPermissions()
        self.microphone = microphone ?? SystemMicrophonePort(); self.limits = limits
    }
    @discardableResult public func adoptPreparedConfiguration(_ config: ASRConfiguration) throws -> ASREngineIdentity {
        guard !isBusy, !delivering else { throw QwenControllerError.busy }
        try validateLimits()
        guard (config.providerID == .qwen3ASR || config.providerID == .networkAPI), let loaded = backend.preparedEngine(for: config) else { throw QwenControllerError.notReady }
        token = UUID(); engine = loaded; configuration = config; publish(.ready); return loaded
    }
    @discardableResult public func prepare(_ config: ASRConfiguration) async throws -> ASREngineIdentity {
        guard !isBusy, !delivering else { throw QwenControllerError.busy }
        guard (config.providerID == .qwen3ASR || config.providerID == .networkAPI), limits.segmentSeconds.isFinite, limits.segmentSeconds > 0,
              limits.segmentSeconds <= 8, (1...16).contains(limits.maximumPendingSegments),
              (1...4096).contains(limits.ingressBlocks), (1...65536).contains(limits.maximumFramesPerBlock),
              limits.drainTimeoutSeconds.isFinite, limits.drainTimeoutSeconds > 0, limits.drainTimeoutSeconds <= 600 else {
            throw QwenControllerError.invalidConfiguration
        }
        token = UUID(); let expected = token; engine = nil; configuration = nil; publish(.loading)
        do {
            let loaded = try await backend.load(config)
            try check(expected)
            engine = loaded; configuration = config; publish(.ready); return loaded
        } catch {
            if token == expected { fail(Self.error(error)) }
            throw error
        }
    }
    /// Caller owns system capture permission/start/awaited stop; this accepts no hardware itself.
    public func begin(_ b: QwenSessionBinding) throws -> QwenPCMIngress {
        try beginIngress(b, reuseAttempt: false)
    }
    private func beginIngress(_ b: QwenSessionBinding, reuseAttempt: Bool) throws -> QwenPCMIngress {
        guard !isBusy, !delivering else { throw QwenControllerError.busy }
        guard let configuration, let engine, backend.preparedEngine(for: configuration) == engine else { throw QwenControllerError.notReady }
        try validate(b)
        guard b.source != .file else { throw QwenControllerError.invalidConfiguration }
        if !reuseAttempt { reset(b) }
        let queue = try BoundedPCMQueue(capacityBlocks: limits.ingressBlocks, maximumFramesPerBlock: limits.maximumFramesPerBlock,
                                       maximumBytesPerBlock: Int(limits.maximumFramesPerBlock) * 8 * 4)
        let producer = QwenPCMIngress(queue: queue, generation: queue.beginSession()); ingress = producer
        publish(.capturing); launchCapturePump(expected: token, producer: producer)
        return producer
    }
    public func userPressedStartMicrophone(userInitiated: Bool, binding b: QwenSessionBinding) async throws {
        guard userInitiated else { throw QwenControllerError.userActionRequired }
        guard b.source == .microphone else { throw QwenControllerError.invalidConfiguration }
        guard !isBusy, !delivering else { throw QwenControllerError.busy }
        guard let configuration, let engine, backend.preparedEngine(for: configuration) == engine else { throw QwenControllerError.notReady }
        try validate(b); reset(b)
        let expected = token; publish(.requestingMicrophone)
        let granted = await permissions.requestMicrophone()
        try check(expected)
        guard granted else { fail(.microphoneDenied); throw QwenControllerError.microphoneDenied }
        publish(.ready)
        let producer = try beginIngress(b, reuseAttempt: true)
        let captureToken = token
        microphone.onStateChange = { [weak self] s in
            guard let self, self.token == captureToken else { return }
            if case .failed(let error) = s { self.fail(.backend("capture: \(error)")) }
        }
        do {
            try microphone.start(intent: .init(userInitiated: true, microphoneEnabled: true), onFrame: producer.handler)
            guard microphone.state == .running else { throw QwenControllerError.backend("DEVICE_DID_NOT_START") }
            deviceStarted = true; publishObservation()
        }
        catch { fail(Self.error(error)); throw error }
    }
    /// External capture owner reports hardware facts only after native start succeeds.
    public func externalDeviceStarted() throws {
        guard state == .capturing, binding?.source == .systemAudio else { throw QwenControllerError.notReady }
        deviceStarted = true; publishObservation()
    }
    public func externalCaptureFailed(_ description: String) {
        guard binding?.source == .systemAudio, state == .capturing else { return }
        fail(.backend("system capture: " + description))
    }
    public func stopAndDrain() async throws {
        guard state == .capturing, !delivering else { throw QwenControllerError.busy }
        let expected = token
        microphone.onStateChange = nil; microphone.stop()
        ingress?.seal(); publish(.draining); armDeadline(expected)
        while state == .draining { await waitForProgress() }
        try check(expected)
        if case .failed(let error) = state { throw error }
        guard state == .completed else { throw QwenControllerError.cancelled }
    }
    public func transcribeFile(_ url: URL, binding b: QwenSessionBinding) async throws {
        guard !isBusy, !delivering else { throw QwenControllerError.busy }
        guard let configuration, let engine, backend.preparedEngine(for: configuration) == engine else { throw QwenControllerError.notReady }
        try validate(b)
        guard b.source == .file, url.isFileURL, b.sourceURL == nil || b.sourceURL == url else { throw QwenControllerError.invalidConfiguration }
        let fileBinding = QwenSessionBinding(sessionID: b.sessionID, channelID: b.channelID, streamID: b.streamID,
            source: .file, mappingRevision: b.mappingRevision, sourceURL: url)
        reset(fileBinding); let expected = token, fileIO = io
        publish(.importing)
        do {
            try await fileIO.open(url); try check(expected)
            while let pcm = try await fileIO.read(maximumFrames: limits.maximumFramesPerBlock) {
                try check(expected)
                // File input can suspend; capture input cannot. Never build an unbounded file queue.
                while pending.count + (activeInference ? 1 : 0) >= limits.maximumPendingSegments {
                    await waitForProgress(); try check(expected)
                }
                try accept(pcm, timestampNs: nil)
                launchInference(expected)
            }
            await fileIO.close(); try check(expected)
            sealTail(); publish(.draining); armDeadline(expected); launchInference(expected)
            try await waitForInference(expected)
            try complete(expected)
        } catch {
            await fileIO.close()
            if token == expected { fail(Self.error(error)) }
            throw error
        }
    }
    public func isCurrent(_ final: QwenSegmentFinal) -> Bool {
        final.attemptID == token && final.binding == binding && (state == .capturing || state == .importing || state == .draining)
    }
    public func cancel() {
        guard !delivering else { return }
        invalidate(); backend.cancel(); engine = nil; configuration = nil; publish(.cancelled)
    }
    public func unload() throws {
        guard !isBusy, !delivering else { throw QwenControllerError.busy }
        invalidate(); backend.unload(); engine = nil; configuration = nil; publish(.idle)
    }
    private func validateLimits() throws {
        guard limits.segmentSeconds.isFinite, limits.segmentSeconds > 0, limits.segmentSeconds <= 8,
              (1...16).contains(limits.maximumPendingSegments), (1...4096).contains(limits.ingressBlocks),
              (1...65536).contains(limits.maximumFramesPerBlock), limits.drainTimeoutSeconds.isFinite,
              limits.drainTimeoutSeconds > 0, limits.drainTimeoutSeconds <= 600 else { throw QwenControllerError.invalidConfiguration }
    }
    private func validate(_ b: QwenSessionBinding) throws {
        guard [b.sessionID, b.channelID, b.streamID].allSatisfy({ !$0.isEmpty }), b.mappingRevision > 0 else { throw QwenControllerError.invalidConfiguration }
    }
    private func reset(_ b: QwenSessionBinding) {
        token = UUID(); attemptID = token; binding = b; activeCommit = commitFinal; pending = []; assembly = []; rate = nil; anchorNs = nil
        ingress = nil
        totalFrames = 0; segmentStart = 0; sequence = 0; deliveredSegments = 0; skippedNoSpeechSegments = 0; highWaterPendingSegments = 0
        engineAtStart = engine
        deviceStarted = false; audioObserved = false; asrObserved = false; nativeSampleEnd = nil
        previousHostNs = nil; previousBlockFrames = 0; continuityFailureDescription = nil
        activeInference = false; io = QwenFileIO(); directory = nil
        publishObservation()
    }
    private func check(_ expected: UUID) throws {
        guard expected == token, !Task.isCancelled else { throw QwenControllerError.cancelled }
        if case .failed(let e) = state { throw e }
    }
    private func launchCapturePump(expected: UUID, producer: QwenPCMIngress) {
        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                while self.state == .capturing || self.state == .draining {
                    try self.check(expected)
                    if let violation = producer.failure { throw QwenControllerError.backend("ingress: \(violation)") }
                    var blocks: [OwnedPCMBlock] = []
                    try producer.queue.drain(generation: producer.generation, maxBlocks: 4) { blocks.append($0) }
                    for block in blocks {
                        let owned = QwenOwnedBuffer(buffer: block.buffer)
                        let pcm = try await Task.detached { try QwenFileIO.extract(owned.buffer) }.value
                        try self.check(expected)
                        guard block.source.rawValue == self.binding?.source.rawValue,
                              block.timestamp.sampleRate == pcm.rate else { throw QwenControllerError.invalidPCM }
                        if let position = block.timestamp.samplePosition {
                            guard position >= 0, self.nativeSampleEnd == nil || self.nativeSampleEnd == position else {
                                self.continuityFailureDescription = "麦克风采样位置跳变（预期 \(self.nativeSampleEnd.map(String.init) ?? "首块")，实际 \(position)）"
                                throw QwenControllerError.discontinuousSource
                            }
                            let end = position.addingReportingOverflow(Int64(pcm.samples.count))
                            guard !end.overflow else { throw QwenControllerError.invalidPCM }
                            self.nativeSampleEnd = end.partialValue
                        } else if self.nativeSampleEnd != nil {
                            self.continuityFailureDescription = "音频输入丢失采样位置"
                            throw QwenControllerError.discontinuousSource
                        }
                        let seconds = block.source == .microphone ? block.timestamp.hostSeconds : block.timestamp.presentationSeconds
                        guard let seconds, seconds.isFinite, seconds >= 0,
                              let ns = UInt64(exactly: (seconds * 1e9).rounded(.down)) else { throw QwenControllerError.invalidPCM }
                        // Native sample positions are the continuity authority. The hardware
                        // sample clock and host clock can drift; compare adjacent host times
                        // for gross jumps, not accumulated drift against nominal sample rate.
                        if block.source == .microphone, block.timestamp.samplePosition != nil {
                            if let previous = self.previousHostNs {
                                let step = UInt64((Double(self.previousBlockFrames) * 1e9 / pcm.rate).rounded())
                                let tolerance = max(UInt64(2_000_000), step / 1000)
                                let delta = ns >= previous ? ns - previous : UInt64.max
                                let residual = delta >= step ? delta - step : step - delta
                                guard residual <= tolerance else {
                                    self.continuityFailureDescription = "麦克风时间戳跳变（相邻块偏差 \(residual) ns）"
                                    throw QwenControllerError.discontinuousSource
                                }
                            }
                            self.previousHostNs = ns; self.previousBlockFrames = pcm.samples.count
                            try self.accept(pcm, timestampNs: self.anchorNs == nil ? ns : nil)
                        } else {
                            try self.accept(pcm, timestampNs: ns)
                        }
                        self.launchInference(expected)
                    }
                    if self.state == .draining && producer.queue.snapshot().queuedBlocks == 0 {
                        self.sealTail(); self.launchInference(expected)
                        try await self.waitForInference(expected)
                        try self.complete(expected); return
                    }
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
            } catch { if self.token == expected { self.fail(Self.error(error)) } }
        }
    }
    private func accept(_ pcm: QwenNativePCM, timestampNs: UInt64?) throws {
        guard !pcm.samples.isEmpty, pcm.samples.count <= Int(limits.maximumFramesPerBlock) else { throw QwenControllerError.invalidPCM }
        if let rate { guard rate == pcm.rate else { throw QwenControllerError.invalidPCM } }
        else { rate = pcm.rate; anchorNs = timestampNs ?? 0 }
        if let timestampNs {
            let expected = time(totalFrames), tolerance = UInt64(ceil(1e9 / pcm.rate))
            let delta = timestampNs >= expected ? timestampNs - expected : expected - timestampNs
            guard delta <= tolerance else { throw QwenControllerError.discontinuousSource }
        }
        let segmentFrames = Int((pcm.rate * limits.segmentSeconds).rounded(.down))
        guard segmentFrames > 0 else { throw QwenControllerError.invalidConfiguration }
        // Decode/format/source/continuity are validated before this fact; queue budget follows.
        if !audioObserved {
            let expected = token
            audioObserved = true; publishObservation()
            try check(expected)
        }
        var offset = 0
        while offset < pcm.samples.count {
            let count = min(segmentFrames - assembly.count, pcm.samples.count - offset)
            assembly.append(contentsOf: pcm.samples[offset..<(offset + count)])
            totalFrames += count; offset += count
            if assembly.count == segmentFrames { try enqueueAssembly() }
        }
    }
    private func time(_ frames: Int) -> UInt64 { (anchorNs ?? 0) + UInt64((Double(frames) * 1e9 / (rate ?? 16000)).rounded(.down)) }
    private func enqueueAssembly() throws {
        guard !assembly.isEmpty, let rate, let binding else { return }
        guard pending.count + (activeInference ? 1 : 0) < limits.maximumPendingSegments else { throw QwenControllerError.backpressure }
        sequence += 1
        pending.append(.init(pcm: .init(samples: assembly, rate: rate), range: .init(frameStart: segmentStart, frameEnd: totalFrames,
            mappingRevision: binding.mappingRevision, startNs: time(segmentStart), endNs: time(totalFrames)), sequence: sequence,
            recognitionStreamID: DesktopSessionControllerRecognitionID(attemptID: token, sequence: sequence)))
        highWaterPendingSegments = max(highWaterPendingSegments, pending.count + (activeInference ? 1 : 0))
        assembly = []; segmentStart = totalFrames
    }
    private func sealTail() {
        do { try enqueueAssembly() } catch { fail(Self.error(error)) }
    }
    private func launchInference(_ expected: UUID) {
        guard !activeInference, !pending.isEmpty, expected == token else { return }
        activeInference = true
        let fileIO = io
        inferenceTask = Task { [weak self] in
            guard let self else { return }
            var localDirectory: URL?
            do {
                localDirectory = try await fileIO.makeDirectory(); try self.check(expected)
                self.directory = localDirectory
                while !self.pending.isEmpty {
                    let segment = self.pending.removeFirst()
                    self.armOperationDeadline(expected)
                    let url = try await fileIO.write(segment.pcm, directory: localDirectory!, sequence: segment.sequence)
                    try self.check(expected)
                    let result = try await self.backend.transcribe(fileURL: url, context: self.configuration?.terminologyContext)
                    try self.check(expected)
                    guard let binding = self.binding, let engine = self.engine, result.engine == engine else { throw QwenControllerError.backend("ENGINE_IDENTITY_CHANGED_OR_EMPTY_FINAL") }
                    let empty = result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    if result.noSpeech {
                        guard empty else { throw QwenControllerError.backend("INVALID_NO_SPEECH_RESULT") }
                        guard binding.source != .file else { throw QwenControllerError.noAudio }
                        self.skippedNoSpeechSegments += 1
                        self.onNoSpeech?()
                        self.operationDeadlineTask?.cancel(); self.operationDeadlineTask = nil
                        try await fileIO.removeSegment(url, directory: localDirectory!)
                        try self.check(expected); self.progress()
                        continue
                    }
                    guard !empty else { throw QwenControllerError.backend("ENGINE_IDENTITY_CHANGED_OR_EMPTY_FINAL") }
                    self.asrObserved = true; self.publishObservation()
                    try self.check(expected)
                    let final = QwenSegmentFinal(binding: binding, attemptID: expected, sequence: segment.sequence, sourceRange: segment.range,
                                                text: result.text, language: result.language, engine: result.engine, recognitionStreamID: segment.recognitionStreamID)
                    guard let commit = self.activeCommit else { throw QwenControllerError.backend("DURABLE_COMMIT_HANDLER_REQUIRED") }
                    try await commit(final)
                    try self.check(expected)
                    self.operationDeadlineTask?.cancel(); self.operationDeadlineTask = nil
                    self.deliveredSegments += 1
                    self.progress()
                    self.delivering = true
                    self.onFinal?(final)
                    self.delivering = false
                    try await fileIO.removeSegment(url, directory: localDirectory!)
                    try self.check(expected)
                }
                try self.check(expected); self.activeInference = false; self.progress()
            } catch { if self.token == expected { self.fail(Self.error(error)) } }
            if let localDirectory { try? await fileIO.removeDirectory(localDirectory) }
        }
    }
    private func complete(_ expected: UUID) throws {
        try check(expected)
        guard totalFrames > 0, deliveredSegments + skippedNoSpeechSegments == sequence, pending.isEmpty, !activeInference, assembly.isEmpty else { throw QwenControllerError.noAudio }
        deadlineTask?.cancel(); deadlineTask = nil; publish(.completed)
    }
    private func armOperationDeadline(_ expected: UUID) {
        operationDeadlineTask?.cancel()
        operationDeadlineTask = Task { [weak self, seconds = limits.drainTimeoutSeconds] in
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) } catch { return }
            guard let self, self.token == expected, self.isBusy else { return }
            self.fail(self.state == .draining ? .drainTimeout : .operationTimeout)
        }
    }
    private func armDeadline(_ expected: UUID) {
        deadlineTask?.cancel()
        deadlineTask = Task { [weak self, seconds = limits.drainTimeoutSeconds] in
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) } catch { return }
            guard let self, self.token == expected, self.state == .draining else { return }
            self.fail(.drainTimeout)
        }
    }
    private func invalidate() {
        token = UUID(); ingress?.seal()
        if let ingress { ingress.queue.stop(generation: ingress.generation) }
        microphone.onStateChange = nil; microphone.stop()
        captureTask?.cancel(); inferenceTask?.cancel(); deadlineTask?.cancel(); operationDeadlineTask?.cancel()
        pending = []; assembly = []; activeInference = false
        let oldIO = io, oldDirectory = directory; directory = nil
        Task { await oldIO.close(); if let oldDirectory { try? await oldIO.removeDirectory(oldDirectory) } }
    }
    private func fail(_ e: QwenControllerError) {
        invalidate(); backend.cancel(); engine = nil; configuration = nil; publish(.failed(e))
    }
    private func publish(_ next: QwenControllerState) { state = next; progress(); onStateChange?(next) }
    private static func error(_ error: Error) -> QwenControllerError {
        if let error = error as? QwenControllerError { return error }
        if error is CancellationError { return .cancelled }
        return .backend(String(describing: error))
    }
}
