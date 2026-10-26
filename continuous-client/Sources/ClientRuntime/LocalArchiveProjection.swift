import Foundation
import MeetingCopilotCore
import IncrementalArchive
import ClientIncrementalBridge

/// Background-only exact projection for new typed-bootstrap stores. Legacy/subset logs fail closed.
public enum LocalArchiveProjection {
    public static func archive(_ projection: BridgeProjection) throws -> LocalArchive {
        guard projection.sessionOrder.count == projection.sessions.count else { throw BridgeFailure.unsupportedBootstrap("session order/bootstrap missing") }
        var result = LocalArchive()
        for id in projection.sessionOrder {
            guard let source = projection.sessions[id], let bootstrap = source.bootstrap else { throw BridgeFailure.unsupportedBootstrap("typed bootstrap missing") }
            var notes: [NoteVersion] = []
            for note in source.notes {
                guard let bits = note.savedAtReferenceBits, let revision = Int(exactly: note.revision) else { throw BridgeFailure.unsupportedBootstrap("notes date missing") }
                notes.append(NoteVersion(revision: revision, text: note.text, savedAt: Date(timeIntervalSinceReferenceDate: Double(bitPattern: bits))))
            }
            guard source.presentations.count == source.core.segments.count else { throw BridgeFailure.unsupportedBootstrap("segment presentation incomplete") }
            let order = source.presentations.sorted { $0.value.insertionIndex < $1.value.insertionIndex }
            var segments: [LocalSegment] = []
            for (index, item) in order.enumerated() {
                guard item.value.insertionIndex == UInt64(index), let events = source.core.segments[item.key] else { throw BridgeFailure.invalid("segment ordering") }
                let revisions = events.map { e in
                    SourceRevision(revision: e.revision!, text: e.text!, status: e.status!, startNS: e.startNs!, endNS: e.endNs!, channelID: e.channelId, streamID: e.streamId, sourceSpans: e.sourceSpans, sourceLanguage: item.value.sourceLanguage)
                }
                let translations = source.core.translations.values.flatMap { $0 }.filter { $0.segmentId == item.key }.sorted {
                    ($0.revision!, $0.eventSeq) < ($1.revision!, $1.eventSeq)
                }.map { e in
                    LocalTranslation(id: e.translationId!, revision: e.revision!, sourceRevision: e.sourceRevision!, sourceText: e.sourceText!, targetLanguage: e.targetLanguage!, text: e.translatedText!)
                }
                segments.append(LocalSegment(id: item.key, channelKind: events.last?.channelKind ?? "typed_text", revisions: revisions, translations: translations))
            }
            // Materials are reconstructed from their acknowledged chunks only. An incomplete material keeps its
            // partial text and is NOT exported as a complete file: `materialCompleteness` reports it.
            var materials: [LocalMaterial] = []
            for materialID in source.materialOrder {
                guard let value = source.materials[materialID], value.complete else { continue }
                materials.append(LocalMaterial(id: value.materialID, fileName: value.fileName, text: value.text,
                    sha256: value.sha256, importedAt: Date(timeIntervalSinceReferenceDate: Double(bitPattern: value.importedAtReferenceBits))))
            }
            var captures: [LocalCaptureAttempt] = []
            for attemptID in source.captureOrder {
                guard let value = source.captures[attemptID], let state = value.state else { throw BridgeFailure.unsupportedBootstrap("capture state missing") }
                let identity = value.identity
                var attempt = LocalCaptureAttempt(id: identity.id, channelID: identity.channelID, streamID: identity.streamID, segmentID: identity.segmentID, locale: identity.locale,
                                                  engineVersion: identity.engineVersion, modelVersion: identity.modelVersion)
                attempt.sourceKind = identity.sourceKind; attempt.sourceURL = identity.sourceURL
                attempt.streamID = state.streamID; attempt.segmentID = state.segmentID
                attempt.lifecycle = state.lifecycle; attempt.failure = state.failure
                attempt.deviceStarted = state.deviceStarted; attempt.audioObserved = state.audioObserved; attempt.asrObserved = state.asrObserved
                attempt.history = value.history; attempt.mode = state.mode; attempt.generationID = state.generationID
                attempt.tasks = value.tasks.map { tasks in tasks.map { task in
                    var local = LocalCaptureTask(streamID: task.streamID, segmentID: task.segmentID, firstObservedBy: task.firstObservedBy)
                    local.finalObserved = task.finalObserved
                    local.sourceBlocks = task.blocks.map { $0.map { b in
                        LocalCaptureBlock(frameStart: b.frameStart, frameEnd: b.frameEnd, mappingRevision: b.mappingRevision, startNS: b.startNS, endNS: b.endNS,
                            hostSeconds: b.hostSecondsBits.map(Double.init(bitPattern:)), samplePosition: b.samplePosition,
                            sampleRate: Double(bitPattern: b.sampleRateBits), presentationSeconds: b.presentationSecondsBits.map(Double.init(bitPattern:)), receivedUptime: Double(bitPattern: b.receivedUptimeBits))
                    } }
                    return local
                } }
                if let generation = state.generationID {
                    guard let uuid = UUID(uuidString: generation) else { throw BridgeFailure.invalid("capture generation") }
                    let fence = ArchiveFence(sessionID: id, attemptID: attemptID, generationID: uuid)
                    if let canonical = source.attempts[fence], !canonical.observations.isEmpty {
                        attempt.canonicalMetadata = try CanonicalProjection.metadata(canonical.observations)
                    }
                }
                captures.append(attempt)
            }
            result.sessions.append(LocalSession(id: id, title: source.title,
                createdAt: Date(timeIntervalSinceReferenceDate: Double(bitPattern: bootstrap.createdAtReferenceBits)),
                isDemo: bootstrap.isDemo, notes: notes.last?.text ?? bootstrap.initialNotes, tags: source.tags,
                noteHistory: notes, segments: segments, speechJournal: source.journal, captureAttempts: captures,
                materials: materials,
                tombstone: source.tombstone.map { LocalTombstone(id: $0.recordID,
                    deletedAt: Date(timeIntervalSinceReferenceDate: Double(bitPattern: $0.deletedAtReferenceBits)),
                    actorKind: $0.actorKind, reason: $0.reason) }))
        }
        return result
    }
}
