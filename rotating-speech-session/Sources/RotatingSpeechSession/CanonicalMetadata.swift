import Foundation
import AVFoundation
import AppleOfflineSpeech
import CanonicalAudioClock
import MeetingCopilotAudioCapture
import MeetingCopilotPCMBridge

/// Actual whole-block backend identity; never CanonicalAudioClock's exact-budget partition identity.
public struct RotatingTaskCanonicalSpan: Equatable, Sendable {
    public let blockID: UUID
    public let task: RotatingSpeechTaskIdentity
    public let epochID: UUID
    public let taskStartGlobalFrame: UInt64
    public let globalFrameStart: UInt64, globalFrameEnd: UInt64
    /// Planned identity-relative frame span established BEFORE ASR. Not proof of consumption.
    public let taskLocalFrameStart: Int, taskLocalFrameEnd: Int
    public let nominalStartNs: UInt64, nominalEndNs: UInt64
    public let mappingRevision: UInt64
    public let basis: EpochAnchor.Basis
}
public enum RotatingCanonicalDisposition: Equatable, Sendable {
    /// Finite-owner poll returned normally and stayed accepting with the expected local range.
    /// Separate backendAccepted evidence is required; this is not a complete validated final.
    case recognitionConsumed
    case rejectedBeforeMapping, rejectedAfterMapping, uncertainAfterMapping
}
public struct RotatingCanonicalCoverage: Equatable, Sendable {
    public let epochID: UUID?
    public let transferredBlocks: UInt64, transferredFrames: UInt64
    public let mappedBlocks: UInt64, mappedFrames: UInt64
    public let recognitionConsumedBlocks: UInt64, recognitionConsumedFrames: UInt64
    public let rejectedBeforeMappingBlocks: UInt64, rejectedBeforeMappingFrames: UInt64
    public let rejectedAfterMappingBlocks: UInt64, rejectedAfterMappingFrames: UInt64
    public let uncertainAfterMappingBlocks: UInt64, uncertainAfterMappingFrames: UInt64
    public let backendAcceptedBlocks: UInt64, backendAcceptedFrames: UInt64
    public let ownerReturnedBlocks: UInt64
    public let startedTasks: UInt64, validatedFinalTasks: UInt64, validatedFinalFrames: UInt64
    public let queue: PCMQueueSnapshot?
    /// True only at settled boundaries; nominal mapping is separate from recognition consumption.
    public var canonicalAccountingValid: Bool {
        transferredBlocks >= mappedBlocks && transferredBlocks - mappedBlocks == rejectedBeforeMappingBlocks &&
        mappedBlocks >= recognitionConsumedBlocks && mappedBlocks - recognitionConsumedBlocks >= rejectedAfterMappingBlocks &&
        mappedBlocks - recognitionConsumedBlocks - rejectedAfterMappingBlocks == uncertainAfterMappingBlocks &&
        transferredFrames >= mappedFrames && transferredFrames - mappedFrames == rejectedBeforeMappingFrames &&
        mappedFrames >= recognitionConsumedFrames && mappedFrames - recognitionConsumedFrames >= rejectedAfterMappingFrames &&
        mappedFrames - recognitionConsumedFrames - rejectedAfterMappingFrames == uncertainAfterMappingFrames
    }
    public var queueAccountingValid: Bool {
        guard let queue else { return transferredBlocks == 0 }
        let s = queue.statistics
        guard s.acceptedBlocks >= s.consumedBlocks else { return false }
        let remaining = s.acceptedBlocks - s.consumedBlocks
        return remaining >= s.releasedBlocks && remaining - s.releasedBlocks == UInt64(queue.queuedBlocks)
    }
    /// Accepted blocks never transferred to dispatch, released by overflow/cancel/failure.
    /// No per-block frame total is inferred: the queue does not expose lifetime released frames.
    public var releasedWithoutTransferBlocks: UInt64? {
        guard let queue else { return nil }
        let rejected = rejectedBeforeMappingBlocks.addingReportingOverflow(rejectedAfterMappingBlocks)
        guard !rejected.overflow, queue.statistics.releasedBlocks >= rejected.partialValue else { return nil }
        return queue.statistics.releasedBlocks - rejected.partialValue
    }
    /// Check only after the poll/cancel boundary. Owner-return count is the outer dispatch consumer's
    /// successful return count, including uncertain early finals, not an ASR final acknowledgement.
    public var ownerQueueAccountingValid: Bool {
        guard let queue else { return transferredBlocks == 0 }
        return canonicalAccountingValid && queueAccountingValid &&
            queue.statistics.consumedBlocks == ownerReturnedBlocks && releasedWithoutTransferBlocks != nil
    }
    public var completionCoverageValid: Bool {
        ownerQueueAccountingValid && mappedBlocks == recognitionConsumedBlocks &&
        rejectedBeforeMappingBlocks == 0 && rejectedAfterMappingBlocks == 0 && uncertainAfterMappingBlocks == 0 &&
        backendAcceptedFrames == mappedFrames && validatedFinalFrames == mappedFrames &&
        validatedFinalTasks == startedTasks && startedTasks > 0 &&
        queue?.queuedBlocks == 0 && queue?.statistics.releasedBlocks == 0 &&
        queue?.statistics.acceptedBlocks == recognitionConsumedBlocks
    }
}
public enum RotatingCanonicalOutput: Equatable, Sendable {
    case mapped(generation: RotatingSpeechGeneration, blockID: UUID, block: CanonicalAudioBlock)
    case associated(generation: RotatingSpeechGeneration, span: RotatingTaskCanonicalSpan)
    /// Original timestamp always present, even when mapping was rejected.
    /// taskLocalRange is the unchanged finite-owner range only if it belongs to this block.
    case settled(generation: RotatingSpeechGeneration, blockID: UUID, disposition: RotatingCanonicalDisposition,
                 timestamp: SourceTimestamp, taskLocalRange: PCMSourceRange?, backendAccepted: Bool,
                 ownerReturned: Bool, failure: RotatingSpeechFailure?)
    /// Emitted after queue drain commits, before the original raw terminal output.
    case terminalCoverage(generation: RotatingSpeechGeneration, coverage: RotatingCanonicalCoverage)
}

/// Counts only successful backend append returns; mapper/owner lastMappedRange is not consumption proof.
@MainActor final class SuccessfulPCMBackend: OfflinePCMRecognitionBackend {
    let underlying: any OfflinePCMRecognitionBackend
    private(set) var appendedFrames: UInt64 = 0
    var osAuthorized: Bool { underlying.osAuthorized }
    init(_ underlying: any OfflinePCMRecognitionBackend) { self.underlying = underlying }
    func begin(locale: OfflineSpeechLocale, deliver: @escaping @MainActor @Sendable (SpeechBackendObservation) -> Void) throws {
        try underlying.begin(locale: locale, deliver: deliver)
    }
    func append(_ buffer: AVAudioPCMBuffer) throws {
        let next = appendedFrames.addingReportingOverflow(UInt64(buffer.frameLength))
        guard !next.overflow else { throw OfflineSpeechFailure.backend("CONSUMPTION_COUNTER_OVERFLOW") }
        try underlying.append(buffer)
        appendedFrames = next.partialValue
    }
    func finishAudio() { underlying.finishAudio() }
    func cancel() { underlying.cancel() }
}
