import Foundation
import AVFoundation
import MeetingCopilotAudioCapture
import MeetingCopilotPCMBridge

enum TestFailure: Error { case consumer, sessionIncomplete, assertion(String) }
func expect(_ value: @autoclosure () -> Bool, _ text: String) throws {
    if !value() { throw TestFailure.assertion(text) }
}
func frame(value: Float = 0.25, frames: AVAudioFrameCount = 32) -> AudioFrame {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for index in 0..<Int(frames) { buffer.floatChannelData![0][index] = value }
    let timestamp = SourceTimestamp(source: .microphone, hostSeconds: 1, samplePosition: 32,
        sampleRate: 48000, presentationSeconds: nil, receivedUptime: 1.1)
    return AudioFrame(buffer: buffer, timestamp: timestamp)
}
func conserved(_ queue: BoundedPCMQueue, _ label: String) throws {
    let s = queue.snapshot()
    try expect(s.statistics.acceptedBlocks == s.statistics.consumedBlocks + s.statistics.releasedBlocks + UInt64(s.queuedBlocks), "Accounting: \(label): \(s)")
}
@main struct PCMQueueTests {
    @MainActor static func main() throws {
        do { _ = try BoundedPCMQueue(capacityBlocks: 0); throw TestFailure.assertion("Invalid capacity accepted") }
        catch PCMQueueFailure.invalidConfiguration {}
        let queue = try BoundedPCMQueue(capacityBlocks: 2)
        let generation = queue.beginSession()
        let borrowed = frame()
        try expect(queue.enqueue(borrowed, generation: generation) == .accepted, "Copy accepted")
        borrowed.buffer.floatChannelData![0][0] = 0.75
        let delivered = try queue.drain(generation: generation, maxBlocks: 1) { block in
            try expect(block.buffer !== borrowed.buffer, "Buffer owns independent allocation")
            try expect(block.buffer.floatChannelData![0][0] == 0.25, "Producer mutation cannot modify owned copy")
            try expect(block.timestamp == borrowed.timestamp && block.generation == generation, "Source timestamp/generation preserved")
        }
        try expect(delivered == 1, "One owned block delivered")
        try conserved(queue, "owned copy")
        print("PASS owned PCM independent memory, source timestamp and bounded MainActor drain")

        let full = queue.beginSession()
        try expect(queue.enqueue(frame(), generation: full) == .accepted, "capacity first")
        try expect(queue.enqueue(frame(), generation: full) == .accepted, "capacity second")
        try expect(queue.snapshot().queuedBlocks == 2 && queue.snapshot().queuedFrames == 64 && queue.snapshot().queuedBytes == 256, "Capacity metrics")
        try conserved(queue, "full")
        try expect(queue.enqueue(frame(), generation: full) == .failed(.capacityExceeded(limitBlocks: 2)), "Overflow fails explicitly")
        let failed = queue.snapshot()
        try expect(failed.state == .failed && failed.queuedBlocks == 0 && failed.queuedFrames == 0 && failed.queuedBytes == 0, "Failure releases pending memory")
        try expect(failed.statistics.overflowFailures == 1 && failed.statistics.releasedBlocks == 2, "Overflow statistics")
        try expect(queue.enqueue(frame(), generation: full) == .failed(.capacityExceeded(limitBlocks: 2)), "Poisoned generation cannot continue")
        do { try queue.drain(generation: full, maxBlocks: 1) { _ in throw TestFailure.assertion("Overflow consumer must not run") }; throw TestFailure.assertion("Overflow drain returned success") }
        catch PCMQueueFailure.capacityExceeded(limitBlocks: 2) {}
        try conserved(queue, "overflow")
        print("PASS bounded capacity, sticky explicit overflow failure, release and accounting")

        let stopped = queue.beginSession()
        _ = queue.enqueue(frame(), generation: stopped)
        try expect(queue.stop(generation: stopped), "Stop active generation")
        try expect(queue.snapshot().queuedBlocks == 0, "Stop releases")
        try expect(queue.enqueue(frame(), generation: stopped) == .rejectedInactive, "Stopped input rejected")
        let restarted = queue.beginSession()
        try expect(restarted != stopped, "New generation")
        try expect(queue.enqueue(frame(), generation: stopped) == .rejectedStaleGeneration, "Old callback rejected")
        try expect(!queue.stop(generation: stopped) && queue.isCurrent(restarted), "Old controller cannot stop new session")
        try expect(queue.enqueue(frame(), generation: restarted) == .accepted, "Restart accepts new frame")
        _ = try queue.drain(generation: restarted, maxBlocks: 1) { _ in }
        try expect(queue.snapshot().statistics.staleRejections == 1 && queue.snapshot().statistics.inactiveRejections == 1, "Rejection statistics")
        try conserved(queue, "stop/restart")
        print("PASS stop/restart release and stale-generation protection")

        let small = try BoundedPCMQueue(capacityBlocks: 1, maximumFramesPerBlock: 16)
        let smallID = small.beginSession()
        try expect(small.enqueue(frame(), generation: smallID) == .failed(.blockTooLarge), "Per-block frame limit")
        let smallBytes = try BoundedPCMQueue(capacityBlocks: 1, maximumBytesPerBlock: 16)
        let smallBytesID = smallBytes.beginSession()
        try expect(smallBytes.enqueue(frame(), generation: smallBytesID) == .failed(.blockTooLarge), "Per-block byte limit")
        try conserved(small, "frame bound"); try conserved(smallBytes, "byte bound")
        print("PASS configured frame/byte block limits")

        // Direct/live append failure: current popped block plus all pending blocks are released.
        let live = try BoundedPCMQueue(capacityBlocks: 3)
        let liveID = live.beginSession()
        _ = live.enqueue(frame(), generation: liveID); _ = live.enqueue(frame(), generation: liveID)
        do {
            try live.drain(generation: liveID, maxBlocks: 2) { _ in throw TestFailure.consumer }
            throw TestFailure.assertion("Consumer error swallowed")
        } catch TestFailure.consumer {}
        let liveS = live.snapshot()
        try expect(liveS.state == .failed && liveS.statistics.acceptedBlocks == 2 && liveS.statistics.consumedBlocks == 0 && liveS.statistics.releasedBlocks == 2 && liveS.queuedBlocks == 0, "Failed current block accounted as released, not consumed")
        try conserved(live, "direct/live throw")
        print("PASS direct/live consumer throw: accepted=2 consumed=0 released=2 queued=0")

        // Matches rotating append failure: backend first error is caught internally, first dispatch
        // returns normally, next guard throws because the logical recognizer session is incomplete.
        let rotating = try BoundedPCMQueue(capacityBlocks: 3)
        let rotatingID = rotating.beginSession()
        _ = rotating.enqueue(frame(), generation: rotatingID); _ = rotating.enqueue(frame(), generation: rotatingID)
        var sessionComplete = true
        var backendAttempts = 0
        do {
            try rotating.drain(generation: rotatingID, maxBlocks: 2) { _ in
                guard sessionComplete else { throw TestFailure.sessionIncomplete }
                backendAttempts += 1
                do { throw TestFailure.consumer } catch { sessionComplete = false }
            }
            throw TestFailure.assertion("Rotating guard error swallowed")
        } catch TestFailure.sessionIncomplete {}
        let rotatingS = rotating.snapshot()
        try expect(backendAttempts == 1 && rotatingS.state == .failed && rotatingS.statistics.acceptedBlocks == 2 && rotatingS.statistics.consumedBlocks == 1 && rotatingS.statistics.releasedBlocks == 1 && rotatingS.queuedBlocks == 0, "Rotating popped guard block released")
        try conserved(rotating, "rotating error")
        print("PASS synthetic rotating error: accepted=2 consumed=1 released=1 queued=0")

        // Consumer can synchronously rotate/restart before throwing. Do not poison the new session.
        let switched = try BoundedPCMQueue(capacityBlocks: 3)
        let oldID = switched.beginSession()
        _ = switched.enqueue(frame(), generation: oldID); _ = switched.enqueue(frame(), generation: oldID)
        var nextID: PCMGeneration?
        do {
            try switched.drain(generation: oldID, maxBlocks: 2) { _ in
                nextID = switched.beginSession()
                throw TestFailure.consumer
            }
            throw TestFailure.assertion("Switch throw swallowed")
        } catch TestFailure.consumer {}
        try expect(switched.isCurrent(nextID!) && switched.snapshot().statistics.releasedBlocks == 2, "Switch releases pending + popped failure without poisoning new generation")
        try conserved(switched, "switch during consumer error")
        _ = switched.enqueue(frame(), generation: nextID!)
        _ = try switched.drain(generation: nextID!, maxBlocks: 1) { _ in }
        try conserved(switched, "new session after error")
        print("PASS generation rotation during throw and new-session success")

        // Lock/thread safety using only synthesized buffers. No Tasks or actual audio engine.
        let parallel = try BoundedPCMQueue(capacityBlocks: 128)
        let parallelID = parallel.beginSession()
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            _ = parallel.enqueue(frame(value: Float(index)), generation: parallelID)
        }
        try expect(parallel.snapshot().queuedBlocks == 100 && parallel.snapshot().statistics.acceptedBlocks == 100, "Concurrent producers retain exact count")
        var values = Set<Int>()
        while parallel.snapshot().queuedBlocks > 0 {
            _ = try parallel.drain(generation: parallelID, maxBlocks: 7) { block in values.insert(Int(block.buffer.floatChannelData![0][0])) }
        }
        try expect(values.count == 100 && parallel.snapshot().statistics.consumedBlocks == 100, "Concurrent delivery without duplicates")
        try conserved(parallel, "concurrent producers")
        print("PASS 100 concurrent synthetic producers and max-7 MainActor batches")

        // Core Audio taps may return interleaved Float32. The queue must own
        // planar Float32 bytes before the recognizer sees them.
        let interleavedFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 48000, channels: 2, interleaved: true)!
        let interleaved = AVAudioPCMBuffer(pcmFormat: interleavedFormat, frameCapacity: 32)!
        interleaved.frameLength = 32
        for index in 0..<(32 * 2) {
            interleaved.floatChannelData![0][index] = Float(index)
        }
        let tapQueue = try BoundedPCMQueue(capacityBlocks: 1)
        let tapGeneration = tapQueue.beginSession()
        let tapFrame = AudioFrame(buffer: interleaved,
            timestamp: .init(source: .systemAudio, hostSeconds: nil, samplePosition: nil,
                sampleRate: 48000, presentationSeconds: 1, receivedUptime: 1))
        try expect(tapQueue.enqueue(tapFrame, generation: tapGeneration) == .accepted,
            "interleaved Core Audio tap frame accepted")
        _ = try tapQueue.drain(generation: tapGeneration, maxBlocks: 1) { block in
            try expect(!block.buffer.format.isInterleaved && block.buffer.format.channelCount == 2,
                "queue owns planar stereo PCM")
            try expect(block.buffer.floatChannelData![0][0] == 0 &&
                       block.buffer.floatChannelData![1][0] == 1 &&
                       block.buffer.floatChannelData![0][1] == 2,
                "interleaved channel values deinterleaved exactly")
        }
        print("PASS interleaved tap PCM is copied as planar Float32 with exact channel order")
        print("ALL PCM QUEUE TESTS PASSED; no devices, permissions, capture, Speech, audio files or network")
    }
}
