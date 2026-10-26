import Foundation
import ClientRuntime
import MeetingCopilotCore
import IncrementalArchive
import ClientIncrementalBridge

@MainActor func runEngineIdentityChecks() async throws {
    let dir = try StorageEvolutionChecks.newDirectory("engine-default-roundtrip")
    var attempt = LocalCaptureAttempt(id: "engine-a", channelID: "mic", streamID: "s", segmentID: "seg", locale: "zh-CN", engineVersion: "synthetic-check-engine/v1")
    attempt.lifecycle = "completed"
    var session = LocalSession(id: "engine-session", title: "合成身份往返")
    session.captureAttempts = [attempt]
    var archive = LocalArchive(); archive.sessions = [session]
    _ = try ArchiveStore(directory: dir).save(archive)
    let reopened = try ArchiveStore(directory: dir).load()
    try legacyRequire(reopened.sessions[0].captureAttempts[0].engineVersion == attempt.engineVersion, "whole archive preserves engine identity")
    try legacyRequire(reopened.sessions[0].captureAttempts[0].modelVersion == nil, "unknown model version stays nil")
    let old = """
    {"id":"old","channelID":"mic","streamID":"s","segmentID":"seg","locale":"zh-CN","lifecycle":"completed","deviceStarted":false,"audioObserved":false,"asrObserved":false,"history":[]}
    """
    let oldAttempt = try JSONDecoder().decode(LocalCaptureAttempt.self, from: Data(old.utf8))
    try legacyRequire(oldAttempt.engineVersion == nil && oldAttempt.modelVersion == nil, "old attempt decodes with unknown engine")
    print("PASS engine identity: whole archive roundtrip and old-schema nil compatibility")

    let typedDir = try StorageEvolutionChecks.newDirectory("engine-typed-roundtrip")
    let writer = try await IncrementalArchiveWriter.open(directory: typedDir, limits: ArchiveLimits())
    let fence = ArchiveFence(sessionID: "engine-session")
    let first = try await TypedTombstoneChecks.submit(writer, ArchiveSubmission(id: UUID(), expectedHead: 0, fence: fence, deltas: [.sessionBootstrap(ArchiveSessionBootstrap(title: "引擎身份", createdAtReferenceBits: Date().timeIntervalSinceReferenceDate.bitPattern, isDemo: false, initialNotes: "", tags: []))], durability: .fsync))
    let identity = ArchiveCaptureIdentity(id: "engine-a", channelID: "mic", streamID: "s", segmentID: "seg", locale: "zh-CN", engineVersion: attempt.engineVersion)
    let state = ArchiveCaptureState(lifecycle: "prepared", failure: nil, deviceStarted: false, audioObserved: false, asrObserved: false, mode: nil, generationID: nil, appendedHistory: [], streamID: "s", segmentID: "seg")
    _ = try await TypedTombstoneChecks.submit(writer, ArchiveSubmission(id: UUID(), expectedHead: first.token.plannedCommitSequence, fence: fence, deltas: [.captureInitialized(identity), .captureState(attemptID: "engine-a", revision: 1, state: state)], durability: .fsync))
    _ = try await writer.close()
    let records = try await IncrementalArchiveWriter.inspect(directory: typedDir)
    var projection = BridgeProjection(limits: try LegacyMigrationChecks.limits())
    for record in records.records { try projection.apply(record.submission) }
    let restored = try LocalArchiveProjection.archive(projection)
    try legacyRequire(restored.sessions[0].captureAttempts[0].engineVersion == attempt.engineVersion, "typed reopen projection preserves engine version")
    try legacyRequire(restored.sessions[0].captureAttempts[0].modelVersion == nil, "typed unknown model stays nil")
    let oldIdentity = """
    {"id":"old","channelID":"mic","streamID":"s","segmentID":"seg","locale":"zh-CN","tasksPresent":false}
    """
    let oldTyped = try JSONDecoder().decode(ArchiveCaptureIdentity.self, from: Data(oldIdentity.utf8))
    try legacyRequire(oldTyped.engineVersion == nil && oldTyped.modelVersion == nil, "old typed identity remains nil")
    print("PASS engine identity: real typed writer/replay/projection roundtrip and old-schema nil compatibility")
}
