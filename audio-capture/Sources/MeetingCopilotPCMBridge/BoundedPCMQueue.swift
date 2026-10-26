import Foundation
import AVFoundation
import MeetingCopilotAudioCapture

public struct PCMGeneration: Hashable, Sendable {
    public let id: UUID
    fileprivate init() { id = UUID() }
}
public enum PCMQueueFailure: Error, Equatable, Sendable {
    case invalidConfiguration, capacityExceeded(limitBlocks: Int), blockTooLarge
    case invalidPCM(String), staleGeneration, inactive
}
public enum PCMEnqueueResult: Equatable, Sendable {
    case accepted
    case rejectedStaleGeneration
    case rejectedInactive
    case failed(PCMQueueFailure)
}
public enum PCMQueueState: Equatable, Sendable { case idle, active, stopped, failed }
public struct PCMQueueStatistics: Equatable, Sendable {
    public fileprivate(set) var acceptedBlocks: UInt64 = 0
    public fileprivate(set) var consumedBlocks: UInt64 = 0
    public fileprivate(set) var staleRejections: UInt64 = 0
    public fileprivate(set) var inactiveRejections: UInt64 = 0
    public fileprivate(set) var overflowFailures: UInt64 = 0
    public fileprivate(set) var invalidBlockFailures: UInt64 = 0
    /// Explicitly discarded by failure/stop/restart, not silently skipped as continuous input.
    public fileprivate(set) var releasedBlocks: UInt64 = 0
    public fileprivate(set) var highWaterBlocks: Int = 0
}
public struct PCMQueueSnapshot: Equatable, Sendable {
    public let state: PCMQueueState
    public let generation: PCMGeneration?
    public let failure: PCMQueueFailure?
    public let queuedBlocks: Int
    public let queuedFrames: UInt64
    public let queuedBytes: Int
    /// Lifetime cumulative counters; beginSession does not hide old failures/statistics.
    public let statistics: PCMQueueStatistics
}
/// Buffer is a unique memory copy transferred to the MainActor consumer.
/// Do not mutate/share it across consumers; generation is included for client diagnostics.
public struct OwnedPCMBlock {
    public let buffer: AVAudioPCMBuffer
    public let timestamp: SourceTimestamp
    public let generation: PCMGeneration
    public var source: AudioSource { timestamp.source }
    fileprivate let byteCount: Int
}

/// Lock-protected, fixed ring buffer. No Tasks, timer, device, permission or network API.
/// Only producer enqueue/snapshot/isCurrent are cross-thread. Lifecycle and drain are MainActor.
/// The unchecked Sendable invariant: all mutable state and stored PCM are protected by lock;
/// borrowed input is copied synchronously while locked; owned blocks leave only via MainActor drain.
public final class BoundedPCMQueue: @unchecked Sendable {
    public let capacityBlocks: Int
    public let maximumFramesPerBlock: AVAudioFrameCount
    public let maximumBytesPerBlock: Int
    private let lock = NSLock()
    private var slots: [OwnedPCMBlock?]
    private var head = 0
    private var count = 0
    private var frames: UInt64 = 0
    private var bytes = 0
    private var generation: PCMGeneration?
    private var state: PCMQueueState = .idle
    private var failure: PCMQueueFailure?
    private var statistics = PCMQueueStatistics()
    private var isDraining = false // MainActor protects this flag.

    public init(capacityBlocks: Int, maximumFramesPerBlock: AVAudioFrameCount = 8192,
                maximumBytesPerBlock: Int = 1_048_576) throws {
        guard (1...65536).contains(capacityBlocks), maximumFramesPerBlock > 0,
              maximumBytesPerBlock > 0, maximumBytesPerBlock <= Int.max / capacityBlocks else {
            throw PCMQueueFailure.invalidConfiguration
        }
        self.capacityBlocks = capacityBlocks
        self.maximumFramesPerBlock = maximumFramesPerBlock
        self.maximumBytesPerBlock = maximumBytesPerBlock
        slots = Array(repeating: nil, count: capacityBlocks)
    }
    /// Begin a new caller-controlled bridge session, not a device start.
    /// Releases any pending blocks and invalidates every previous generation.
    @MainActor @discardableResult public func beginSession() -> PCMGeneration {
        lock.lock(); defer { lock.unlock() }
        releaseLocked()
        let next = PCMGeneration()
        generation = next; failure = nil; state = .active
        return next
    }
    /// A stale controller cannot stop a newer session. Returns false for an old generation.
    @MainActor @discardableResult public func stop(generation expected: PCMGeneration) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard generation == expected else { return false }
        releaseLocked()
        state = .stopped
        // Keep failure diagnostic (if any) until explicit beginSession; no automatic recovery.
        return true
    }
    /// Call directly within the capture callback while borrowed PCM is valid.
    /// No per-frame Task. Accepted PCM is always copied into private owned memory before return.
    /// Rejected/failed input is never retained. First overflow poisons the generation and releases
    /// pending blocks; every subsequent current-generation enqueue reports the same failure.
    @discardableResult public func enqueue(_ frame: AudioFrame, generation expected: PCMGeneration) -> PCMEnqueueResult {
        lock.lock(); defer { lock.unlock() }
        guard generation == expected else {
            statistics.staleRejections += 1
            return .rejectedStaleGeneration
        }
        if let failure { return .failed(failure) }
        guard state == .active else {
            statistics.inactiveRejections += 1
            return .rejectedInactive
        }
        guard count < capacityBlocks else {
            statistics.overflowFailures += 1
            return failLocked(.capacityExceeded(limitBlocks: capacityBlocks))
        }
        do {
            try PCMUtilities.validate(frame.buffer)
            guard frame.buffer.frameLength <= maximumFramesPerBlock else {
                statistics.invalidBlockFailures += 1
                return failLocked(.blockTooLarge)
            }
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: frame.buffer.audioBufferList))
            let byteCount = buffers.reduce(0) { $0 + Int($1.mDataByteSize) }
            guard byteCount > 0, byteCount <= maximumBytesPerBlock else {
                statistics.invalidBlockFailures += 1
                return failLocked(.blockTooLarge)
            }
            let owned = try PCMUtilities.copyAsPlanarFloat32(frame.buffer)
            let ownedBytes = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: owned.audioBufferList)
            ).reduce(0) { $0 + Int($1.mDataByteSize) }
            let block = OwnedPCMBlock(buffer: owned, timestamp: frame.timestamp,
                                      generation: expected, byteCount: ownedBytes)
            slots[(head + count) % capacityBlocks] = block
            count += 1; frames += UInt64(owned.frameLength); bytes += ownedBytes
            statistics.acceptedBlocks += 1
            statistics.highWaterBlocks = max(statistics.highWaterBlocks, count)
            return .accepted
        } catch {
            statistics.invalidBlockFailures += 1
            return failLocked(.invalidPCM(String(describing: error)))
        }
    }
    /// Caller drives one serial MainActor consumer (e.g. a single 10–20 ms polling task).
    /// maxBlocks is mandatory and bounds each main-thread batch. consume is synchronous/non-async.
    /// Errors must terminate that recognizer session; never pretend overflow input was continuous.
    /// Empty live queue returns 0. Stop/old-generation/failure throws instead of implying EOS.
    @MainActor @discardableResult public func drain(generation expected: PCMGeneration, maxBlocks: Int,
                     consume: @MainActor (OwnedPCMBlock) throws -> Void) throws -> Int {
        guard maxBlocks > 0 else { throw PCMQueueFailure.invalidConfiguration }
        guard !isDraining else { throw PCMQueueFailure.invalidConfiguration }
        isDraining = true
        defer { isDraining = false }
        var consumed = 0
        while consumed < maxBlocks {
            guard let block = try pop(generation: expected) else { return consumed }
            // No await between removal and consumer. stop/restart on MainActor cannot interleave.
            // A producer may fail concurrently; at most this already-transferred block can finish.
            do {
                try consume(block)
                lock.lock(); statistics.consumedBlocks += 1; lock.unlock()
            } catch {
                lock.lock()
                // pop already removed this block from the ring. Failed consumption is an
                // explicit release, even if the consumer stopped/rotated the generation.
                statistics.releasedBlocks += 1
                if generation == expected, state == .active {
                    _ = failLocked(.invalidPCM("Consumer failed: \(error)"))
                }
                lock.unlock()
                throw error
            }
            consumed += 1
        }
        // Also detect an overflow concurrent with the last consumer callback.
        try checkActive(generation: expected)
        return consumed
    }
    public func snapshot() -> PCMQueueSnapshot {
        lock.lock(); defer { lock.unlock() }
        return PCMQueueSnapshot(state: state, generation: generation, failure: failure,
            queuedBlocks: count, queuedFrames: frames, queuedBytes: bytes, statistics: statistics)
    }
    public func isCurrent(_ expected: PCMGeneration) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation == expected && state == .active && failure == nil
    }
    private func pop(generation expected: PCMGeneration) throws -> OwnedPCMBlock? {
        lock.lock(); defer { lock.unlock() }
        try checkActiveLocked(generation: expected)
        guard count > 0 else { return nil }
        let block = slots[head]!
        slots[head] = nil; head = (head + 1) % capacityBlocks; count -= 1
        frames -= UInt64(block.buffer.frameLength); bytes -= block.byteCount
        return block
    }
    private func checkActive(generation expected: PCMGeneration) throws {
        lock.lock(); defer { lock.unlock() }
        try checkActiveLocked(generation: expected)
    }
    private func checkActiveLocked(generation expected: PCMGeneration) throws {
        guard generation == expected else { throw PCMQueueFailure.staleGeneration }
        if let failure { throw failure }
        guard state == .active else { throw PCMQueueFailure.inactive }
    }
    private func failLocked(_ error: PCMQueueFailure) -> PCMEnqueueResult {
        failure = error; state = .failed
        releaseLocked()
        return .failed(error)
    }
    private func releaseLocked() {
        statistics.releasedBlocks += UInt64(count)
        while count > 0 {
            slots[head] = nil; head = (head + 1) % capacityBlocks; count -= 1
        }
        head = 0; frames = 0; bytes = 0
    }
}
