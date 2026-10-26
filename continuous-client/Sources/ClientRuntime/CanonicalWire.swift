import Foundation
import RotatingSpeechSession
import CanonicalAudioClock
import MeetingCopilotAudioCapture
import IncrementalArchive

// Converts the controller's actual canonical output into the archive's typed scalar observations.
// Every field is copied from the real RotatingCanonicalOutput; no value is invented, no coverage is computed here.
public enum CanonicalWire {
    public static func observations(_ output: RotatingCanonicalOutput) -> [CanonicalObservation] {
        switch output {
        case .mapped(_, let blockID, let block):
            return [CanonicalObservation(kind: .mapped, fields: blockFields(blockID: blockID, block: block))]
        case .associated(_, let span):
            return [CanonicalObservation(kind: .associated, fields: [
                "blockID": .uuid(span.blockID), "epochID": .uuid(span.epochID),
                "streamID": .string(span.task.streamId), "segmentID": .string(span.task.segmentId),
                "taskStartGlobalFrame": .unsigned(span.taskStartGlobalFrame),
                "globalFrameStart": .unsigned(span.globalFrameStart), "globalFrameEnd": .unsigned(span.globalFrameEnd),
                "taskLocalFrameStart": .signed(Int64(span.taskLocalFrameStart)),
                "taskLocalFrameEnd": .signed(Int64(span.taskLocalFrameEnd)),
                "nominalStartNs": .unsigned(span.nominalStartNs), "nominalEndNs": .unsigned(span.nominalEndNs),
                "mappingRevision": .unsigned(span.mappingRevision), "basis": .string(span.basis.rawValue)])]
        case .settled(_, let blockID, let disposition, let timestamp, let range, let accepted, let returned, let failure):
            var fields: [String: CanonicalScalar] = [
                "blockID": .uuid(blockID), "disposition": .string(String(describing: disposition)),
                "backendAccepted": .boolean(accepted), "ownerReturned": .boolean(returned)]
            if let failure { fields["failure"] = .string(String(describing: failure)) }
            fields.merge(timestampFields(timestamp)) { _, new in new }
            if let range {
                fields["taskLocalFrameStart"] = .signed(Int64(range.frameStart))
                fields["taskLocalFrameEnd"] = .signed(Int64(range.frameEnd))
                fields["mappingRevision"] = .unsigned(UInt64(range.mappingRevision))
                fields["rangeStartNs"] = .unsigned(range.startNs); fields["rangeEndNs"] = .unsigned(range.endNs)
            }
            return [CanonicalObservation(kind: .settled, fields: fields)]
        case .terminalCoverage(_, let coverage):
            var fields: [String: CanonicalScalar] = [
                "completionCoverageValid": .boolean(coverage.completionCoverageValid),
                "canonicalAccountingValid": .boolean(coverage.canonicalAccountingValid),
                "queueAccountingValid": .boolean(coverage.queueAccountingValid),
                "ownerQueueAccountingValid": .boolean(coverage.ownerQueueAccountingValid),
                "transferredBlocks": .unsigned(coverage.transferredBlocks), "transferredFrames": .unsigned(coverage.transferredFrames),
                "mappedBlocks": .unsigned(coverage.mappedBlocks), "mappedFrames": .unsigned(coverage.mappedFrames),
                "recognitionConsumedBlocks": .unsigned(coverage.recognitionConsumedBlocks),
                "recognitionConsumedFrames": .unsigned(coverage.recognitionConsumedFrames),
                "rejectedBeforeMappingBlocks": .unsigned(coverage.rejectedBeforeMappingBlocks),
                "rejectedBeforeMappingFrames": .unsigned(coverage.rejectedBeforeMappingFrames),
                "rejectedAfterMappingBlocks": .unsigned(coverage.rejectedAfterMappingBlocks),
                "rejectedAfterMappingFrames": .unsigned(coverage.rejectedAfterMappingFrames),
                "uncertainAfterMappingBlocks": .unsigned(coverage.uncertainAfterMappingBlocks),
                "uncertainAfterMappingFrames": .unsigned(coverage.uncertainAfterMappingFrames),
                "backendAcceptedBlocks": .unsigned(coverage.backendAcceptedBlocks),
                "backendAcceptedFrames": .unsigned(coverage.backendAcceptedFrames),
                "ownerReturnedBlocks": .unsigned(coverage.ownerReturnedBlocks),
                "startedTasks": .unsigned(coverage.startedTasks),
                "validatedFinalTasks": .unsigned(coverage.validatedFinalTasks),
                "validatedFinalFrames": .unsigned(coverage.validatedFinalFrames)]
            if let epoch = coverage.epochID { fields["epochID"] = .uuid(epoch) }
            if let released = coverage.releasedWithoutTransferBlocks { fields["releasedWithoutTransferBlocks"] = .unsigned(released) }
            if let queue = coverage.queue {
                fields["queueState"] = .string(String(describing: queue.state))
                fields["queueQueuedBlocks"] = .signed(Int64(queue.queuedBlocks))
                fields["queueQueuedFrames"] = .unsigned(queue.queuedFrames)
                fields["queueQueuedBytes"] = .signed(Int64(queue.queuedBytes))
                fields["queueAcceptedBlocks"] = .unsigned(queue.statistics.acceptedBlocks)
                fields["queueConsumedBlocks"] = .unsigned(queue.statistics.consumedBlocks)
                fields["queueReleasedBlocks"] = .unsigned(queue.statistics.releasedBlocks)
                fields["queueStaleRejections"] = .unsigned(queue.statistics.staleRejections)
                fields["queueInactiveRejections"] = .unsigned(queue.statistics.inactiveRejections)
                fields["queueOverflowFailures"] = .unsigned(queue.statistics.overflowFailures)
                fields["queueHighWaterBlocks"] = .signed(Int64(queue.statistics.highWaterBlocks))
                fields["queueInvalidBlockFailures"] = .unsigned(queue.statistics.invalidBlockFailures)
                if let generation = queue.generation { fields["queueGenerationID"] = .uuid(generation.id) }
                if let failure = queue.failure { fields["queueFailure"] = .string(String(describing: failure)) }
            }
            return [CanonicalObservation(kind: .terminalCoverage, fields: fields)]
        }
    }
    private static func blockFields(blockID: UUID, block: CanonicalAudioBlock) -> [String: CanonicalScalar] {
        var fields: [String: CanonicalScalar] = [
            "blockID": .uuid(blockID), "epochID": .uuid(block.anchor.epochID),
            "channel": .string(block.anchor.channel), "startNs": .unsigned(block.anchor.startNs),
            "provenance": .string(block.anchor.provenance.rawValue), "basis": .string(block.anchor.basis.rawValue),
            "mappingRevision": .unsigned(block.anchor.mappingRevision),
            "sampleRate": .signed(block.anchor.format.sampleRate),
            "channelCount": .unsigned(UInt64(block.anchor.format.channelCount)),
            "encoding": .string(block.anchor.format.encoding),
            "globalFrameStart": .unsigned(block.globalFrameStart), "globalFrameEnd": .unsigned(block.globalFrameEnd),
            "nominalStartNs": .unsigned(block.startNs), "nominalEndNs": .unsigned(block.endNs)]
        if let position = block.anchor.nativeSamplePosition { fields["nativeSamplePosition"] = .signed(position) }
        fields.merge(timestampFields(block.rawObservation)) { _, new in new }
        if let basis = block.diagnostic.timestampBasis { fields["observedBasis"] = .string(basis.rawValue) }
        if let observed = block.diagnostic.observedStartNs { fields["observedStartNs"] = .unsigned(observed) }
        if let residual = block.diagnostic.residualNs { fields["residualNs"] = .signed(residual) }
        if let step = block.diagnostic.stepErrorNs { fields["stepErrorNs"] = .signed(step) }
        if let ppm = block.diagnostic.estimatedPPM { fields["estimatedPPMBits"] = .float64(ppm) }
        return fields
    }
    private static func timestampFields(_ t: RawAudioObservation) -> [String: CanonicalScalar] {
        var fields: [String: CanonicalScalar] = ["rawSource": .string(t.source), "rawSampleRate": .float64(t.sampleRate)]
        if let host = t.hostSeconds { fields["rawHostSeconds"] = .float64(host) }
        if let position = t.samplePosition { fields["rawSamplePosition"] = .signed(position) }
        if let pts = t.presentationSeconds { fields["rawPresentationSeconds"] = .float64(pts) }
        fields["rawReceivedUptime"] = .float64(t.receivedUptime)
        return fields
    }
    /// The settled case carries the original SourceTimestamp; fields are copied verbatim, never rederived.
    private static func timestampFields(_ t: SourceTimestamp) -> [String: CanonicalScalar] {
        var fields: [String: CanonicalScalar] = ["rawSource": .string(t.source.rawValue), "rawSampleRate": .float64(t.sampleRate)]
        if let host = t.hostSeconds { fields["rawHostSeconds"] = .float64(host) }
        if let position = t.samplePosition { fields["rawSamplePosition"] = .signed(position) }
        if let pts = t.presentationSeconds { fields["rawPresentationSeconds"] = .float64(pts) }
        fields["rawReceivedUptime"] = .float64(t.receivedUptime)
        return fields
    }
}
