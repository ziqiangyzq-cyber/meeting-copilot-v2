import Foundation
import ObjectiveC
import MeetingCopilotAudioCapture
import MeetingCopilotPCMBridge
import AppleOfflineSpeech
import LiveSpeechSession
import AudioClock
import CanonicalAudioClock

public struct RotatingSpeechConfiguration: Sendable {
    public let sessionId: String, channelId: String
    public let source: AudioSource
    public let locale: OfflineSpeechLocale
    public let maximumInputFrames: Int, maximumFramesPerBlock: UInt32, maximumBytesPerBlock: Int
    public let queueCapacityBlocks: Int, maximumBlocksPerPoll: Int, maximumFramesPerPoll: Int
    public let maxRetiringTasks: Int, finishDeadlineSeconds: Double, mappingRevision: Int
    public let canonicalMaximumTimestampStepNs: UInt64?
    public init(sessionId: String, channelId: String, source: AudioSource, locale: OfflineSpeechLocale,
                maximumInputFrames: Int, maximumFramesPerBlock: UInt32 = 8192,
                maximumBytesPerBlock: Int = 1_048_576, queueCapacityBlocks: Int = 32,
                maximumBlocksPerPoll: Int = 8, maximumFramesPerPoll: Int = 65536,
                maxRetiringTasks: Int = 2, finishDeadlineSeconds: Double = 5, mappingRevision: Int = 1,
                 canonicalMaximumTimestampStepNs: UInt64? = nil) {
        self.sessionId = sessionId; self.channelId = channelId; self.source = source; self.locale = locale
        self.maximumInputFrames = maximumInputFrames; self.maximumFramesPerBlock = maximumFramesPerBlock
        self.maximumBytesPerBlock = maximumBytesPerBlock; self.queueCapacityBlocks = queueCapacityBlocks
        self.maximumBlocksPerPoll = maximumBlocksPerPoll; self.maximumFramesPerPoll = maximumFramesPerPoll
        self.maxRetiringTasks = maxRetiringTasks; self.finishDeadlineSeconds = finishDeadlineSeconds
        self.mappingRevision = mappingRevision; self.canonicalMaximumTimestampStepNs = canonicalMaximumTimestampStepNs
    }
}
public struct RotatingSpeechGeneration: Hashable, Sendable {
    public let id: UUID
    fileprivate init() { id = UUID() }
}
public struct RotatingSpeechTaskIdentity: Equatable, Sendable {
    public let streamId: String, segmentId: String
}
public enum RotatingSpeechFailure: Error, Equatable, Sendable {
    case invalidConfiguration, alreadyActive, staleGeneration, reentrantCall, invalidPollClock
    case queue(PCMQueueFailure), owner(LiveSpeechFailure), clock(AudioClockError)
    case backendFactory(String), reusedBackend, retiringTaskLimit, finalCoverageMismatch
    case wrongSource, missingSourceTimestamp, invalidSourceTimestamp, timestampGap, noAudio
    case canonical(CanonicalClockError), canonicalDiscontinuity(Discontinuity), canonicalCoverageMismatch
}
public enum RotatingSpeechState: Equatable, Sendable {
    case idle, accepting, draining, awaitingFinals, completed, cancelled
    case incomplete(RotatingSpeechFailure)
}
public enum RotatingSpeechOutput: Equatable, Sendable {
    case transcript(generation: RotatingSpeechGeneration, update: OfflineTranscriptUpdate)
    /// Bounded external diagnostic; original host/PTS/native position is never rewritten.
    case dispatched(generation: RotatingSpeechGeneration, task: RotatingSpeechTaskIdentity,
                    timestamp: SourceTimestamp, range: PCMSourceRange)
    /// An incomplete terminal requires the caller to stop and quiesce hardware immediately.
    case terminal(generation: RotatingSpeechGeneration, state: RotatingSpeechState)
}

/// One capture ingress, reusable across logical recognition-task boundaries.
public final class RotatingSpeechProducer: @unchecked Sendable {
    public let generation: RotatingSpeechGeneration
    private let queue: BoundedPCMQueue, queueGeneration: PCMGeneration
    private let lock = NSLock()
    private var open = true, invalidated = false
    fileprivate init(generation: RotatingSpeechGeneration, queue: BoundedPCMQueue, token: PCMGeneration) {
        self.generation = generation; self.queue = queue; queueGeneration = token
    }
    @discardableResult public func enqueue(_ frame: AudioFrame) -> PCMEnqueueResult {
        lock.lock(); defer { lock.unlock() }
        guard !invalidated else { return .rejectedStaleGeneration }
        guard open else { return .rejectedInactive }
        return queue.enqueue(frame, generation: queueGeneration)
    }
    public var handler: AudioFrameHandler { { [self] in _ = enqueue($0) } }
    fileprivate func seal(invalidate: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        open = false; invalidated = invalidated || invalidate
    }
}

/// Caller polls serially; no timers, per-frame Tasks, capture devices, or retained transcript history.
@MainActor public final class RotatingSpeechSession {
    public typealias BackendFactory = @MainActor (RotatingSpeechTaskIdentity) throws -> any OfflinePCMRecognitionBackend
    public private(set) var state: RotatingSpeechState = .idle
    public private(set) var generation: RotatingSpeechGeneration?
    public private(set) var startedTasks: UInt64 = 0, finalizedTasks: UInt64 = 0
    public var retiringTaskCount: Int { retiring.count }
    public var retainedOwnerCount: Int { retiring.count + (active == nil ? 0 : 1) }
    public var queueSnapshot: PCMQueueSnapshot? { queue?.snapshot() ?? terminalSnapshot }
    public var onCanonicalOutput: (@MainActor @Sendable (RotatingCanonicalOutput) -> Void)?
    public var canonicalCoverage: RotatingCanonicalCoverage { coverage(queue: queueSnapshot) }
    @MainActor private final class Owner {
        let identity: RotatingSpeechTaskIdentity
        let backend: any OfflinePCMRecognitionBackend
        let session: LiveSpeechSession
        let countedBackend: SuccessfulPCMBackend
        var canonicalStart: UInt64?
        var producer: LiveSpeechProducer!
        var frames = 0
        var finalValidated = false
        init(identity: RotatingSpeechTaskIdentity, backend: any OfflinePCMRecognitionBackend) {
            self.identity = identity; self.backend = backend
            countedBackend = SuccessfulPCMBackend(backend); session = LiveSpeechSession(backend: countedBackend)
        }
    }
    // A lifetime marker lives on the backend itself; no historical backend registry is retained.
    private static var backendOwnershipKey: UInt8 = 0
    private let factory: BackendFactory
    private var active: Owner?, retiring: [Owner] = []
    private var configuration: RotatingSpeechConfiguration?, intent: SpeechStartIntent?
    private var queue: BoundedPCMQueue?, queueGeneration: PCMGeneration?, producer: RotatingSpeechProducer?
    private var terminalSnapshot: PCMQueueSnapshot?
    private var sink: (@MainActor @Sendable (RotatingSpeechOutput) -> Void)?
    private var operating = false
    private var canonicalMapper: CanonicalBlockMapper?
    private var transferredBlocks: UInt64 = 0, transferredFrames: UInt64 = 0
    private var mappedBlocks: UInt64 = 0, mappedFrames: UInt64 = 0
    private var recognitionBlocks: UInt64 = 0, recognitionFrames: UInt64 = 0
    private var rejectedBeforeBlocks: UInt64 = 0, rejectedBeforeFrames: UInt64 = 0
    private var rejectedAfterBlocks: UInt64 = 0, rejectedAfterFrames: UInt64 = 0
    private var uncertainBlocks: UInt64 = 0, uncertainFrames: UInt64 = 0
    private var backendBlocks: UInt64 = 0, backendFrames: UInt64 = 0, ownerReturnedBlocks: UInt64 = 0
    private var validatedFinalFrames: UInt64 = 0
    private var pendingTerminal = false, terminalDelivered = false
    private var continuity: SampleClockMapper?, previousEndNs: UInt64?, lastPollUptime: Double?
    public init(backendFactory: @escaping BackendFactory) { factory = backendFactory }

    /// Validates explicit caller intent before creating any backend. No device is started.
    @discardableResult public func begin(intent: SpeechStartIntent, configuration c: RotatingSpeechConfiguration,
        deliver: @escaping @MainActor @Sendable (RotatingSpeechOutput) -> Void) throws -> RotatingSpeechProducer {
        guard !operating else { throw RotatingSpeechFailure.reentrantCall }
        guard !isRunning else { throw RotatingSpeechFailure.alreadyActive }
        try SpeechStartGate.validate(intent, osAuthorized: true)
        guard !c.sessionId.isEmpty, !c.channelId.isEmpty, c.maximumInputFrames > 0,
              c.maximumFramesPerBlock > 0, Int(c.maximumFramesPerBlock) <= c.maximumInputFrames,
              (1...65536).contains(c.maximumBlocksPerPoll), c.maximumFramesPerPoll >= Int(c.maximumFramesPerBlock),
              (1...64).contains(c.maxRetiringTasks), c.finishDeadlineSeconds.isFinite,
              c.finishDeadlineSeconds > 0, c.mappingRevision > 0 else { throw RotatingSpeechFailure.invalidConfiguration }
        let q = try BoundedPCMQueue(capacityBlocks: c.queueCapacityBlocks,
            maximumFramesPerBlock: c.maximumFramesPerBlock, maximumBytesPerBlock: c.maximumBytesPerBlock)
        producer?.seal(invalidate: true)
        let token = RotatingSpeechGeneration(), qToken = q.beginSession()
        let p = RotatingSpeechProducer(generation: token, queue: q, token: qToken)
        generation = token; queue = q; queueGeneration = qToken; producer = p
        configuration = c; self.intent = intent; sink = deliver; terminalSnapshot = nil
        startedTasks = 0; finalizedTasks = 0; continuity = nil; previousEndNs = nil; lastPollUptime = nil
        canonicalMapper = nil; transferredBlocks = 0; transferredFrames = 0; mappedBlocks = 0; mappedFrames = 0
        recognitionBlocks = 0; recognitionFrames = 0; rejectedBeforeBlocks = 0; rejectedBeforeFrames = 0
        rejectedAfterBlocks = 0; rejectedAfterFrames = 0; uncertainBlocks = 0; uncertainFrames = 0
        backendBlocks = 0; backendFrames = 0; ownerReturnedBlocks = 0; validatedFinalFrames = 0
        pendingTerminal = false; terminalDelivered = false
        state = .accepting
        return p
    }
    /// Only after the caller has stopped capture and quiesced callbacks. Never drops accepted PCM.
    public func closeInput(generation token: RotatingSpeechGeneration) throws {
        try check(token)
        if state == .accepting { producer?.seal(); state = .draining }
    }
    public func finish(generation token: RotatingSpeechGeneration,
                       atUptime now: Double = ProcessInfo.processInfo.systemUptime) throws {
        try closeInput(generation: token); try poll(generation: token, atUptime: now)
    }
    /// Per poll <= maxRetiringTasks+1 owner deadline polls and a bounded PCM batch.
    /// Frames are bounded conservatively by floor(maximumFramesPerPoll / maximumFramesPerBlock).
    public func poll(generation token: RotatingSpeechGeneration,
                     atUptime now: Double = ProcessInfo.processInfo.systemUptime) throws {
        try check(token)
        guard isRunning else { return }
        operating = true
        let q = queue
        defer { cleanupTerminal(); if isTerminal { terminalSnapshot = q?.snapshot() }; deliverTerminal(); operating = false }
        guard now.isFinite, now >= 0, lastPollUptime.map({ now >= $0 }) ?? true else {
            fail(.invalidPollClock); return
        }
        lastPollUptime = now
        do {
            // Snapshot is at most the configured retiring limit; completed references are promptly purged.
            for owner in retiring { try owner.session.poll(generation: owner.producer.generation, atUptime: now) }
            purgeCompleted()
            guard isRunning, let c = configuration, let queue, let qToken = queueGeneration else { return }
            if state == .accepting || state == .draining {
                let batch = min(c.maximumBlocksPerPoll, c.maximumFramesPerPoll / Int(c.maximumFramesPerBlock))
                try queue.drain(generation: qToken, maxBlocks: batch) { [self] block in
                    guard isRunning else { throw RotatingSpeechFailure.owner(.unexpectedFinal) }
                    try dispatch(block, atUptime: now, configuration: c, token: token)
                }
                guard isRunning else { return }
                if state == .draining, queue.snapshot().queuedBlocks == 0 {
                    // If retirement is full, wait with the sealed active owner until a slot opens.
                    if active != nil && retiring.count >= c.maxRetiringTasks { return }
                    try sealActive(atUptime: now)
                    guard isRunning else { return }
                    queue.stop(generation: qToken)
                    if startedTasks == 0 { fail(.noAudio); return }
                    state = .awaitingFinals
                }
            }
            purgeCompleted()
            if state == .awaitingFinals, active == nil, retiring.isEmpty {
                guard finalizedTasks == startedTasks else { fail(.finalCoverageMismatch); return }
                guard canonicalCoverage.completionCoverageValid else { fail(.canonicalCoverageMismatch); return }
                state = .completed; emitTerminal()
            }
        } catch { if isRunning { fail(Self.failure(error)) } }
    }
    public func cancel(generation token: RotatingSpeechGeneration) throws {
        try check(token)
        guard isRunning else { return }
        operating = true
        state = .cancelled; producer?.seal(invalidate: true); emitTerminal(); cleanupTerminal(); deliverTerminal(); operating = false
    }
    private func check(_ token: RotatingSpeechGeneration) throws {
        guard !operating else { throw RotatingSpeechFailure.reentrantCall }
        guard generation == token else { throw RotatingSpeechFailure.staleGeneration }
    }
    private var isRunning: Bool { state == .accepting || state == .draining || state == .awaitingFinals }
    private var isTerminal: Bool { switch state { case .completed, .cancelled, .incomplete: true; default: false } }
    private func dispatch(_ block: OwnedPCMBlock, atUptime now: Double,
                          configuration c: RotatingSpeechConfiguration, token: RotatingSpeechGeneration) throws {
        let blockID = UUID(), frames = UInt64(block.buffer.frameLength)
        transferredBlocks += 1; transferredFrames += frames
        var mapped: CanonicalAudioBlock?, failure: RotatingSpeechFailure?
        var accepted = false, returned = false, range: PCMSourceRange?
        var disposition: RotatingCanonicalDisposition = .rejectedBeforeMapping
        defer {
            switch disposition {
            case .recognitionConsumed: recognitionBlocks += 1; recognitionFrames += frames
            case .rejectedBeforeMapping: rejectedBeforeBlocks += 1; rejectedBeforeFrames += frames
            case .rejectedAfterMapping: rejectedAfterBlocks += 1; rejectedAfterFrames += frames
            case .uncertainAfterMapping: uncertainBlocks += 1; uncertainFrames += frames
            }
            if accepted { backendBlocks += 1; backendFrames += frames }
            if returned { ownerReturnedBlocks += 1 }
            onCanonicalOutput?(.settled(generation: token, blockID: blockID, disposition: disposition,
                timestamp: block.timestamp, taskLocalRange: range, backendAccepted: accepted,
                ownerReturned: returned, failure: failure))
        }
        do {
            mapped = try mapCanonical(block, configuration: c, token: token)
            mappedBlocks += 1; mappedFrames += frames; disposition = .rejectedAfterMapping
            onCanonicalOutput?(.mapped(generation: token, blockID: blockID, block: mapped!))
            try validateContinuity(block, configuration: c)
            if let active, Int(frames) > c.maximumInputFrames - active.frames {
                guard retiring.count < c.maxRetiringTasks else { throw RotatingSpeechFailure.retiringTaskLimit }
                try sealActive(atUptime: now); purgeCompleted()
            }
            guard isRunning else { throw terminalFailure }
            if active == nil { try makeOwner(configuration: c, token: token) }
            guard let active, let canonical = mapped else { throw RotatingSpeechFailure.backendFactory("NO_OWNER") }
            if active.canonicalStart == nil { active.canonicalStart = canonical.globalFrameStart }
            let localStart = active.frames, localEnd = localStart + Int(frames)
            onCanonicalOutput?(.associated(generation: token, span: RotatingTaskCanonicalSpan(blockID: blockID,
                task: active.identity, epochID: canonical.anchor.epochID, taskStartGlobalFrame: active.canonicalStart!,
                globalFrameStart: canonical.globalFrameStart, globalFrameEnd: canonical.globalFrameEnd,
                taskLocalFrameStart: localStart, taskLocalFrameEnd: localEnd,
                nominalStartNs: canonical.startNs, nominalEndNs: canonical.endNs,
                mappingRevision: canonical.anchor.mappingRevision, basis: canonical.anchor.basis)))
            active.frames = localEnd
            let before = active.countedBackend.appendedFrames
            let result = active.producer.enqueue(AudioFrame(buffer: block.buffer, timestamp: block.timestamp))
            guard result == .accepted else {
                if case .failed(let error) = result { throw RotatingSpeechFailure.queue(error) }
                throw RotatingSpeechFailure.owner(.staleGeneration)
            }
            try active.session.poll(generation: active.producer.generation, atUptime: now)
            returned = true
            accepted = active.countedBackend.appendedFrames - before == frames
            if let current = active.session.lastMappedRange,
               current.frameStart == localStart, current.frameEnd == localEnd { range = current }
            if !accepted { returned = false; throw terminalFailure }
            if isRunning, active.session.state == .accepting, range != nil {
                disposition = .recognitionConsumed
                sink?(.dispatched(generation: token, task: active.identity, timestamp: block.timestamp, range: range!))
            } else {
                disposition = .uncertainAfterMapping; failure = terminalFailure
            }
        } catch {
            failure = Self.failure(error)
            if mapped != nil { disposition = accepted ? .uncertainAfterMapping : .rejectedAfterMapping }
            throw error
        }
    }
    private var terminalFailure: RotatingSpeechFailure {
        if case .incomplete(let failure) = state { return failure }
        return .canonicalCoverageMismatch
    }
    private func mapCanonical(_ block: OwnedPCMBlock, configuration c: RotatingSpeechConfiguration,
                              token: RotatingSpeechGeneration) throws -> CanonicalAudioBlock {
        guard block.source == c.source else { throw RotatingSpeechFailure.wrongSource }
        let t = block.timestamp, f = block.buffer.format
        let format = AudioFormatIdentity(sampleRate: try TimestampConversion.integralRate(f.sampleRate),
            channelCount: f.channelCount, encoding: "avpcm:\(f.commonFormat.rawValue):interleaved=\(f.isInterleaved)")
        let raw = RawAudioObservation(source: t.source.rawValue, hostSeconds: t.hostSeconds,
            samplePosition: t.samplePosition, sampleRate: t.sampleRate,
            presentationSeconds: t.presentationSeconds, receivedUptime: t.receivedUptime)
        if canonicalMapper == nil {
            let seconds = c.source == .microphone ? t.hostSeconds : t.presentationSeconds
            guard let seconds else { throw RotatingSpeechFailure.missingSourceTimestamp }
            let anchor = EpochAnchor(epochID: token.id, channel: c.channelId,
                startNs: try TimestampConversion.nanoseconds(seconds: seconds),
                provenance: c.source == .microphone ? .sourceHost : .sourcePTS, format: format,
                mappingRevision: UInt64(c.mappingRevision), nativeSamplePosition: t.samplePosition)
            let rate = UInt64(format.sampleRate)
            let oneSample = 1_000_000_000 / rate + (1_000_000_000 % rate == 0 ? 0 : 1)
            canonicalMapper = try CanonicalBlockMapper(anchor: anchor,
                policy: DiscontinuityPolicy(maximumTimestampStepNs: c.canonicalMaximumTimestampStepNs ?? oneSample))
        }
        switch try canonicalMapper!.map(frameCount: UInt64(block.buffer.frameLength), format: format, raw: raw) {
        case .accepted(let canonical): return canonical
        case .requiresNewEpoch(let reason): throw RotatingSpeechFailure.canonicalDiscontinuity(reason)
        }
    }
    private func coverage(queue: PCMQueueSnapshot?) -> RotatingCanonicalCoverage {
        RotatingCanonicalCoverage(epochID: canonicalMapper?.anchor.epochID,
            transferredBlocks: transferredBlocks, transferredFrames: transferredFrames,
            mappedBlocks: mappedBlocks, mappedFrames: mappedFrames,
            recognitionConsumedBlocks: recognitionBlocks, recognitionConsumedFrames: recognitionFrames,
            rejectedBeforeMappingBlocks: rejectedBeforeBlocks, rejectedBeforeMappingFrames: rejectedBeforeFrames,
            rejectedAfterMappingBlocks: rejectedAfterBlocks, rejectedAfterMappingFrames: rejectedAfterFrames,
            uncertainAfterMappingBlocks: uncertainBlocks, uncertainAfterMappingFrames: uncertainFrames,
            backendAcceptedBlocks: backendBlocks, backendAcceptedFrames: backendFrames,
            ownerReturnedBlocks: ownerReturnedBlocks, startedTasks: startedTasks,
            validatedFinalTasks: finalizedTasks, validatedFinalFrames: validatedFinalFrames, queue: queue)
    }
    private func makeOwner(configuration c: RotatingSpeechConfiguration, token: RotatingSpeechGeneration) throws {
        guard startedTasks < UInt64.max else { throw RotatingSpeechFailure.invalidConfiguration }
        let unique = UUID().uuidString
        let identity = RotatingSpeechTaskIdentity(streamId: "stream-\(token.id)-\(unique)", segmentId: "segment-\(token.id)-\(unique)")
        let backend: any OfflinePCMRecognitionBackend
        do { backend = try factory(identity) } catch { throw RotatingSpeechFailure.backendFactory(String(describing: error)) }
        guard objc_getAssociatedObject(backend, &Self.backendOwnershipKey) == nil else {
            throw RotatingSpeechFailure.reusedBackend
        }
        objc_setAssociatedObject(backend, &Self.backendOwnershipKey, NSNumber(value: true), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        let owner = Owner(identity: identity, backend: backend)
        owner.producer = try owner.session.begin(intent: intent!, configuration: LiveSpeechConfiguration(
            sessionId: c.sessionId, channelId: c.channelId, streamId: identity.streamId, segmentId: identity.segmentId,
            source: c.source, locale: c.locale, queueCapacityBlocks: 1, maximumFramesPerBlock: c.maximumFramesPerBlock,
            maximumBytesPerBlock: c.maximumBytesPerBlock, maximumInputFrames: c.maximumInputFrames,
            maximumBlocksPerPoll: 1, finishDeadlineSeconds: c.finishDeadlineSeconds, mappingRevision: c.mappingRevision)) {
                [weak self, weak owner] output in
                guard let self, let owner, self.generation == token, self.isRunning else { return }
                self.observe(output, owner: owner, token: token)
            }
        startedTasks += 1; active = owner
    }
    private func sealActive(atUptime now: Double) throws {
        guard let owner = active else { return }
        active = nil; retiring.append(owner)
        try owner.session.closeInput(generation: owner.producer.generation)
        try owner.session.poll(generation: owner.producer.generation, atUptime: now)
    }
    private func observe(_ output: LiveSpeechOutput, owner: Owner, token: RotatingSpeechGeneration) {
        let ownsOperation = !operating
        if ownsOperation { operating = true }
        defer { if ownsOperation { purgeCompleted(); cleanupTerminal(); deliverTerminal(); operating = false } }
        switch output {
        case .transcript(_, let update):
            // Forward raw revisions and identity even for an unexpected early final.
            sink?(.transcript(generation: token, update: update))
            if update.status == "final", owner.session.state == .completed {
                guard update.source.frameStart == 0, update.source.frameEnd == owner.frames,
                      update.source.endNs == owner.session.lastMappedRange?.endNs,
                      update.streamId == owner.identity.streamId, update.segmentId == owner.identity.segmentId else {
                    fail(.finalCoverageMismatch); return
                }
                owner.finalValidated = true
            }
        case .terminal(_, let ownerState):
            switch ownerState {
            case .completed:
                guard owner.finalValidated else { fail(.finalCoverageMismatch); return }
            case .incomplete(let error): fail(.owner(error))
            case .cancelled: fail(.owner(.speech(.backend("UNEXPECTED_CANCEL"))))
            default: break
            }
        }
    }
    private func purgeCompleted() {
        retiring.removeAll { owner in
            if owner.session.state == .completed, owner.finalValidated { finalizedTasks += 1; validatedFinalFrames += UInt64(owner.frames); return true }
            return false
        }
    }
    private func validateContinuity(_ block: OwnedPCMBlock, configuration c: RotatingSpeechConfiguration) throws {
        guard block.source == c.source else { throw RotatingSpeechFailure.wrongSource }
        guard let rate = Int64(exactly: block.buffer.format.sampleRate), rate > 0,
              block.timestamp.sampleRate == block.buffer.format.sampleRate else { throw AudioClockError.invalidSampleRate }
        let seconds = c.source == .microphone ? block.timestamp.hostSeconds : block.timestamp.presentationSeconds
        guard let seconds else { throw RotatingSpeechFailure.missingSourceTimestamp }
        guard seconds.isFinite, seconds >= 0,
              let ns = UInt64(exactly: (seconds * 1_000_000_000).rounded(.down)) else { throw RotatingSpeechFailure.invalidSourceTimestamp }
        if continuity == nil {
            continuity = try SampleClockMapper(sampleRate: rate, mappingRevision: UInt64(c.mappingRevision),
                anchor: SourceAnchor(startNs: ns, basis: .nativeSourceTimestamp, nativeSamplePosition: block.timestamp.samplePosition))
        }
        if block.timestamp.samplePosition == nil, let end = previousEndNs {
            let delta = ns >= end ? ns - end : end - ns
            let tolerance = UInt64(1_000_000_000 / rate) + (1_000_000_000 % rate == 0 ? 0 : 1)
            guard delta <= tolerance else { throw RotatingSpeechFailure.timestampGap }
        }
        let range = try continuity!.map(sampleRate: rate, frameCount: Int64(block.buffer.frameLength),
            nativeSamplePosition: block.timestamp.samplePosition, sourceTimestampNs: ns)
        previousEndNs = range.endNs
    }
    private func fail(_ error: RotatingSpeechFailure) {
        guard isRunning else { return }
        state = .incomplete(error); producer?.seal(invalidate: true); emitTerminal()
    }
    private func emitTerminal() { pendingTerminal = true }
    private func deliverTerminal() {
        guard pendingTerminal, !terminalDelivered, let generation else { return }
        pendingTerminal = false; terminalDelivered = true
        onCanonicalOutput?(.terminalCoverage(generation: generation, coverage: canonicalCoverage))
        sink?(.terminal(generation: generation, state: state)); sink = nil
    }
    private func cleanupTerminal() {
        guard isTerminal else { return }
        producer?.seal(invalidate: true)
        if let queue, let queueGeneration { queue.stop(generation: queueGeneration); terminalSnapshot = queue.snapshot() }
        for owner in retiring + (active.map { [$0] } ?? []) {
            switch owner.session.state {
            case .completed, .cancelled, .incomplete: break
            default: try? owner.session.cancel(generation: owner.producer.generation)
            }
        }
        active = nil; retiring.removeAll(); queue = nil; queueGeneration = nil; producer = nil
        continuity = nil; intent = nil; configuration = nil
    }
    private static func failure(_ error: any Error) -> RotatingSpeechFailure {
        if let e = error as? RotatingSpeechFailure { return e }
        if let e = error as? PCMQueueFailure { return .queue(e) }
        if let e = error as? LiveSpeechFailure { return .owner(e) }
        if let e = error as? CanonicalClockError { return .canonical(e) }
        if let e = error as? AudioClockError { return .clock(e) }
        if let e = error as? OfflineSpeechFailure { return .owner(.speech(e)) }
        return .backendFactory(String(describing: error))
    }
}
