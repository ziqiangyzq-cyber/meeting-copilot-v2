import Foundation
import MeetingCopilotCore
import IncrementalArchive

@MainActor extension ClientModel {
    /// Only changed scalar state/history suffix/task observations/source blocks are submitted.
    /// The caller's exact LocalCaptureAttempt remains retained when admission rejects the transaction.
    func incrementalFlushCaptureProjection(session id: String) {
        guard let persistence = incremental, let session = archive.sessions.first(where: { $0.id == id }) else { return }
        for actual in session.captureAttempts {
            let previous = submittedCaptureProjection[actual.id]
            guard previous != actual else { continue }
            var deltas: [ArchiveDelta] = []
            if previous == nil {
                deltas.append(.captureInitialized(ArchiveCaptureIdentity(id: actual.id, channelID: actual.channelID,
                    streamID: actual.streamID, segmentID: actual.segmentID, locale: actual.locale, tasksPresent: actual.tasks != nil,
                    engineVersion: actual.engineVersion, modelVersion: actual.modelVersion,
                    sourceKind: actual.sourceKind, sourceURL: actual.sourceURL)))
            }
            let historyCount = previous?.history.count ?? 0
            guard actual.history.count >= historyCount, Array(actual.history.prefix(historyCount)) == (previous?.history ?? []) else {
                persistence.markLocalFailure("CAPTURE_HISTORY_REWRITTEN"); return
            }
            let revision = (submittedCaptureRevision[actual.id] ?? 0) + 1
            deltas.append(.captureState(attemptID: actual.id, revision: revision,
                state: Self.archiveCaptureState(actual, history: Array(actual.history.dropFirst(historyCount)))))
            for task in actual.tasks ?? [] {
                let old = previous?.tasks?.first(where: { $0.segmentID == task.segmentID })
                if old == nil || old?.finalObserved != task.finalObserved {
                    deltas.append(.captureTask(attemptID: actual.id, streamID: task.streamID, segmentID: task.segmentID,
                        firstObservedBy: task.firstObservedBy, finalObserved: task.finalObserved))
                }
                let oldBlocks = old?.sourceBlocks ?? []
                guard Array((task.sourceBlocks ?? []).prefix(oldBlocks.count)) == oldBlocks else {
                    persistence.markLocalFailure("SOURCE_BLOCK_HISTORY_REWRITTEN"); return
                }
                for block in (task.sourceBlocks ?? []).dropFirst(oldBlocks.count) {
                    deltas.append(.captureSourceBlock(attemptID: actual.id, segmentID: task.segmentID,
                        block: ArchiveCaptureSourceBlock(frameStart: block.frameStart, frameEnd: block.frameEnd,
                            mappingRevision: block.mappingRevision, startNS: block.startNS, endNS: block.endNS,
                            hostSecondsBits: block.hostSeconds?.bitPattern, samplePosition: block.samplePosition,
                            sampleRateBits: block.sampleRate.bitPattern, presentationSecondsBits: block.presentationSeconds?.bitPattern,
                            receivedUptimeBits: block.receivedUptime.bitPattern)))
                }
            }
            guard persistence.enqueueDelta(key: "captureProjection:\(actual.id):\(revision)", fence: ArchiveFence(sessionID: id), attempt: actual.id, deltas: deltas) else { return }
            submittedCaptureProjection[actual.id] = actual; submittedCaptureRevision[actual.id] = revision
        }
    }
    static func archiveCaptureState(_ actual: LocalCaptureAttempt, history: [String]) -> ArchiveCaptureState {
        ArchiveCaptureState(lifecycle: actual.lifecycle, failure: actual.failure, deviceStarted: actual.deviceStarted,
            audioObserved: actual.audioObserved, asrObserved: actual.asrObserved, mode: actual.mode, generationID: actual.generationID,
            appendedHistory: history, streamID: actual.streamID, segmentID: actual.segmentID)
    }
    func incrementalFlushPresentations(session id: String) {
        guard let persistence = incremental, let session = archive.sessions.first(where: { $0.id == id }) else { return }
        for (index, segment) in session.segments.enumerated() {
            // nil has its own unambiguous signature, no invented locale for typed sources.
            let language = segment.current?.sourceLanguage
            let signature = language.map { "value:\($0)" } ?? "nil"
            let key = "\(id):\(segment.id)"
            guard submittedPresentations[key] != signature else { continue }
            guard persistence.enqueueDelta(key: "presentation:\(key)", fence: ArchiveFence(sessionID: id), attempt: nil,
                deltas: [.segmentPresentation(segmentID: segment.id, sourceLanguage: language, insertionIndex: UInt64(index))]) else { return }
            submittedPresentations[key] = signature
        }
    }
}
