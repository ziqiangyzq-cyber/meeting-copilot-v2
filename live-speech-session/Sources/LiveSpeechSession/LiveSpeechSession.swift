import Foundation
import AVFoundation
import MeetingCopilotAudioCapture
import MeetingCopilotPCMBridge
import AudioClock
import AppleOfflineSpeech

public struct LiveSpeechConfiguration: Sendable {
    public let sessionId: String, channelId: String, streamId: String, segmentId: String
    public let source: AudioSource
    public let locale: OfflineSpeechLocale
    public let queueCapacityBlocks: Int, maximumFramesPerBlock: UInt32, maximumBytesPerBlock: Int
    public let maximumInputFrames: Int, maximumBlocksPerPoll: Int
    public let finishDeadlineSeconds: Double
    public let mappingRevision: Int
    public init(sessionId: String, channelId: String, streamId: String, segmentId: String,
                source: AudioSource, locale: OfflineSpeechLocale, queueCapacityBlocks: Int = 32,
                maximumFramesPerBlock: UInt32 = 8192, maximumBytesPerBlock: Int = 1_048_576,
                maximumInputFrames: Int, maximumBlocksPerPoll: Int = 8,
                finishDeadlineSeconds: Double = 5, mappingRevision: Int = 1) {
        self.sessionId = sessionId; self.channelId = channelId; self.streamId = streamId; self.segmentId = segmentId
        self.source = source; self.locale = locale; self.queueCapacityBlocks = queueCapacityBlocks
        self.maximumFramesPerBlock = maximumFramesPerBlock; self.maximumBytesPerBlock = maximumBytesPerBlock
        self.maximumInputFrames = maximumInputFrames; self.maximumBlocksPerPoll = maximumBlocksPerPoll
        self.finishDeadlineSeconds = finishDeadlineSeconds; self.mappingRevision = mappingRevision
    }
}
public struct LiveSpeechGeneration: Hashable, Sendable {
    public let id: UUID
    fileprivate init() { id = UUID() }
}
public enum LiveSpeechFailure: Error, Equatable, Sendable {
    case invalidConfiguration, alreadyActive, staleGeneration, reentrantCall
    case queue(PCMQueueFailure), speech(OfflineSpeechFailure), clock(AudioClockError)
    case wrongSource, missingSourceTimestamp, invalidSourceTimestamp, timestampGap
    case unexpectedFinal, inputClosedBeforeAudio
}
public enum LiveSpeechState: Equatable, Sendable {
    case idle, accepting, draining, finishing, completed, cancelled
    case incomplete(LiveSpeechFailure)
}
public enum LiveSpeechOutput: Equatable, Sendable {
    case transcript(generation: LiveSpeechGeneration, update: OfflineTranscriptUpdate)
    case terminal(generation: LiveSpeechGeneration, state: LiveSpeechState)
}

/// Synchronously copies borrowed frames into the bounded queue; safe to capture in AudioFrameHandler.
/// A lock serializes sealing with enqueue: after closeInput returns no more frames can be accepted.
public final class LiveSpeechProducer: @unchecked Sendable {
    public let generation: LiveSpeechGeneration
    private let queue: BoundedPCMQueue
    private let queueGeneration: PCMGeneration
    private let lock = NSLock()
    private var open = true, invalidated = false
    fileprivate init(generation: LiveSpeechGeneration, queue: BoundedPCMQueue, queueGeneration: PCMGeneration) {
        self.generation = generation; self.queue = queue; self.queueGeneration = queueGeneration
    }
    @discardableResult public func enqueue(_ frame: AudioFrame) -> PCMEnqueueResult {
        lock.lock(); defer { lock.unlock() }
        guard !invalidated else { return .rejectedStaleGeneration }
        guard open else { return .rejectedInactive }
        return queue.enqueue(frame, generation: queueGeneration)
    }
    public var handler: AudioFrameHandler { { [self] frame in _ = enqueue(frame) } }
    fileprivate func seal(invalidate: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        open = false; invalidated = invalidated || invalidate
    }
}

/// One owner, one source, one finite recognition task. No device, permission request, timer or per-frame Task.
@MainActor public final class LiveSpeechSession {
    public private(set) var state: LiveSpeechState = .idle
    public private(set) var generation: LiveSpeechGeneration?
    public private(set) var lastMappedRange: PCMSourceRange?
    public var queueSnapshot: PCMQueueSnapshot? { queue?.snapshot() ?? terminalQueueSnapshot }
    private var terminalQueueSnapshot: PCMQueueSnapshot?
    private let backend: any OfflinePCMRecognitionBackend
    private var configuration: LiveSpeechConfiguration?
    private var intent: SpeechStartIntent?
    private var queue: BoundedPCMQueue?, queueGeneration: PCMGeneration?, producer: LiveSpeechProducer?
    private var adapter: AppleOfflineSpeechAdapter?, mapper: SampleClockMapper?
    private var usedSegments: Set<[String]> = []
    private var sink: (@MainActor @Sendable (LiveSpeechOutput) -> Void)?
    private var pending: [LiveSpeechOutput] = []
    private var operating = false
    public init(backend: any OfflinePCMRecognitionBackend) { self.backend = backend }

    /// Caller assertions are checked before backend authorization; creates no recognition task yet.
    /// Reuse requires a new session/segment identity. A denied begin never changes an existing generation.
    @discardableResult public func begin(intent: SpeechStartIntent, configuration c: LiveSpeechConfiguration,
        deliver: @escaping @MainActor @Sendable (LiveSpeechOutput) -> Void) throws -> LiveSpeechProducer {
        guard !operating else { throw LiveSpeechFailure.reentrantCall }
        guard state != .accepting && state != .draining && state != .finishing else { throw LiveSpeechFailure.alreadyActive }
        try SpeechStartGate.validate(intent, osAuthorized: true)
        try SpeechStartGate.validate(intent, osAuthorized: backend.osAuthorized)
        guard [c.sessionId, c.channelId, c.streamId, c.segmentId].allSatisfy({ !$0.isEmpty }),
              !usedSegments.contains([c.sessionId, c.segmentId]), c.maximumInputFrames > 0,
              c.maximumBlocksPerPoll > 0, c.maximumBlocksPerPoll <= 65536, c.mappingRevision > 0,
              c.finishDeadlineSeconds.isFinite, c.finishDeadlineSeconds > 0 else { throw LiveSpeechFailure.invalidConfiguration }
        let nextQueue = try BoundedPCMQueue(capacityBlocks: c.queueCapacityBlocks,
            maximumFramesPerBlock: c.maximumFramesPerBlock, maximumBytesPerBlock: c.maximumBytesPerBlock)
        producer?.seal(invalidate: true)
        adapter?.cancel()
        let token = LiveSpeechGeneration(), qToken = nextQueue.beginSession()
        let bridge = LiveSpeechProducer(generation: token, queue: nextQueue, queueGeneration: qToken)
        generation = token; queue = nextQueue; queueGeneration = qToken; producer = bridge; terminalQueueSnapshot = nil
        configuration = c; self.intent = intent; sink = deliver; mapper = nil; adapter = nil; lastMappedRange = nil
        usedSegments.insert([c.sessionId, c.segmentId]); state = .accepting
        return bridge
    }

    /// Invoke AFTER stopping the capture device and quiescing its callbacks. This seals, never discards, accepted PCM.
    public func closeInput(generation token: LiveSpeechGeneration) throws {
        guard !operating else { throw LiveSpeechFailure.reentrantCall }
        guard generation == token else { throw LiveSpeechFailure.staleGeneration }
        guard state == .accepting else { return }
        producer?.seal(); state = .draining
    }
    /// Convenience: closes input and performs one bounded poll. Further polls are mandatory until terminal.
    public func finish(generation token: LiveSpeechGeneration, atUptime now: Double = ProcessInfo.processInfo.systemUptime) throws {
        try closeInput(generation: token)
        try poll(generation: token, atUptime: now)
    }
    /// Exactly one caller drives polls. Batches are bounded; uptime is used only for the final-result deadline.
    public func poll(generation token: LiveSpeechGeneration, atUptime now: Double = ProcessInfo.processInfo.systemUptime) throws {
        guard !operating else { throw LiveSpeechFailure.reentrantCall }
        guard generation == token else { throw LiveSpeechFailure.staleGeneration }
        // Keep the queue alive across terminal cleanup triggered by a synchronous backend callback.
        // drain commits consumedBlocks only after its consumer returns; snapshot after that commit.
        let queueAtPollStart = queue
        operating = true
        defer {
            if isTerminal, let queueAtPollStart { terminalQueueSnapshot = queueAtPollStart.snapshot() }
            flush()
            operating = false
        }
        if state == .finishing { adapter?.pollFinalDeadline(atUptime: now); return }
        guard state == .accepting || state == .draining,
              let c = configuration, let queue, let qToken = queueGeneration else { return }
        do {
            try queue.drain(generation: qToken, maxBlocks: c.maximumBlocksPerPoll) { [self] block in
                try consume(block, configuration: c, token: token)
            }
            guard state == .draining, queue.snapshot().queuedBlocks == 0 else { return }
            // Producer is sealed; drain completed successfully. Only now may stop release the empty queue.
            queue.stop(generation: qToken)
            guard let adapter else { terminate(.inputClosedBeforeAudio); return }
            state = .finishing
            try adapter.finishAudio(atUptime: now)
        } catch {
            if !isTerminal { terminate(Self.failure(error)) }
        }
    }
    public func cancel(generation token: LiveSpeechGeneration) throws {
        guard !operating else { throw LiveSpeechFailure.reentrantCall }
        guard generation == token else { throw LiveSpeechFailure.staleGeneration }
        guard !isTerminal else { return }
        operating = true
        state = .cancelled; release(cancelSpeech: true)
        pending.append(.terminal(generation: token, state: state)); flush(); operating = false
    }
    private var isTerminal: Bool {
        switch state { case .completed, .cancelled, .incomplete: true; default: false }
    }
    private func consume(_ block: OwnedPCMBlock, configuration c: LiveSpeechConfiguration, token: LiveSpeechGeneration) throws {
        guard !isTerminal else { throw LiveSpeechFailure.unexpectedFinal }
        guard block.source == c.source else { throw LiveSpeechFailure.wrongSource }
        guard let rate = Int64(exactly: block.buffer.format.sampleRate), rate > 0,
              block.timestamp.sampleRate == block.buffer.format.sampleRate else { throw AudioClockError.invalidSampleRate }
        let seconds = c.source == .microphone ? block.timestamp.hostSeconds : block.timestamp.presentationSeconds
        guard let seconds else { throw LiveSpeechFailure.missingSourceTimestamp }
        guard seconds.isFinite, seconds >= 0,
              let timestampNs = UInt64(exactly: (seconds * 1_000_000_000).rounded(.down)) else {
            throw LiveSpeechFailure.invalidSourceTimestamp
        }
        if mapper == nil {
            mapper = try SampleClockMapper(sampleRate: rate, mappingRevision: UInt64(c.mappingRevision),
                anchor: SourceAnchor(startNs: timestampNs, basis: .nativeSourceTimestamp,
                                     nativeSamplePosition: block.timestamp.samplePosition))
        }
        // PTS-only streams need a continuity check beyond the mapper's strict-order validation.
        // Allow at most one sample of timestamp quantization, without moving the source anchor.
        if block.timestamp.samplePosition == nil, let previous = lastMappedRange {
            let expected = previous.endNs
            let delta = timestampNs >= expected ? timestampNs - expected : expected - timestampNs
            let tolerance = UInt64(1_000_000_000 / rate) + (1_000_000_000 % rate == 0 ? 0 : 1)
            guard delta <= tolerance else { throw LiveSpeechFailure.timestampGap }
        }
        let mapped = try mapper!.map(sampleRate: rate, frameCount: Int64(block.buffer.frameLength),
            nativeSamplePosition: block.timestamp.samplePosition, sourceTimestampNs: timestampNs)
        guard let start = Int(exactly: mapped.frameStart), let end = Int(exactly: mapped.frameEnd),
              let revision = Int(exactly: mapped.mappingRevision) else { throw AudioClockError.overflow }
        let range = PCMSourceRange(frameStart: start, frameEnd: end, mappingRevision: revision,
                                   startNs: mapped.startNs, endNs: mapped.endNs)
        if adapter == nil {
            let next = try AppleOfflineSpeechAdapter(maxInputFrames: c.maximumInputFrames,
                finalResultTimeoutSeconds: c.finishDeadlineSeconds, backend: backend)
            adapter = next
            try next.start(intent: intent!, locale: c.locale, sessionId: c.sessionId, channelId: c.channelId,
                streamId: c.streamId, segmentId: c.segmentId) { [weak self] output in
                    guard let self, self.generation == token, !self.isTerminal else { return }
                    self.observe(output, token: token)
                }
        }
        guard !isTerminal else { throw LiveSpeechFailure.speech(.notAcceptingPCM) }
        lastMappedRange = range
        try adapter!.append(block.buffer, source: range)
    }
    private func observe(_ output: OfflineSpeechOutput, token: LiveSpeechGeneration) {
        let ownsOperation = !operating
        if ownsOperation { operating = true }
        defer { if ownsOperation { flush(); operating = false } }
        switch output {
        case .failed(let failure): terminate(.speech(failure))
        case .transcript(let update):
            // A final confirms only the mapped segment coverage, not the whole capture session.
            // Preserve that observed text even when an early task end makes the session incomplete.
            pending.append(.transcript(generation: token, update: update))
            if update.status == "final", state != .finishing {
                terminate(.unexpectedFinal); return
            }
            if update.status == "final" {
                state = .completed; release(cancelSpeech: false)
                pending.append(.terminal(generation: token, state: state))
            }
        }
    }
    private func terminate(_ failure: LiveSpeechFailure) {
        guard !isTerminal, let generation else { return }
        state = .incomplete(failure); release(cancelSpeech: true)
        pending.append(.terminal(generation: generation, state: state))
    }
    private func release(cancelSpeech: Bool) {
        producer?.seal(invalidate: true)
        if let queue, let queueGeneration {
            queue.stop(generation: queueGeneration)
            terminalQueueSnapshot = queue.snapshot()
        }
        if cancelSpeech { adapter?.cancel() }
        queue = nil; queueGeneration = nil; producer = nil; adapter = nil; mapper = nil
    }
    private func flush() {
        let outputs = pending; pending.removeAll(keepingCapacity: true)
        for output in outputs { sink?(output) }
        if isTerminal { sink = nil }
    }
    private static func failure(_ error: any Error) -> LiveSpeechFailure {
        if let error = error as? LiveSpeechFailure { return error }
        if let error = error as? PCMQueueFailure { return .queue(error) }
        if let error = error as? AudioClockError { return .clock(error) }
        if let error = error as? OfflineSpeechFailure { return .speech(error) }
        return .speech(.backend("SESSION_FAILURE"))
    }
}
