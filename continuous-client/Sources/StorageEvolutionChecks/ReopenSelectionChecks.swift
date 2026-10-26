import Foundation
import MeetingCopilotCore
import ClientRuntime

// Reopen-selection checks. A tombstoned session deliberately stays in `archive.sessions` so an audit can still
// reproduce it; that is exactly why the INITIAL selection must not be taken from the whole array. These checks
// exercise the real ClientModel on both storage paths (whole-archive and incremental). Nothing is stubbed.
//
// Regression guard for: deleting `sessions.first`, then reopening, rendered a DELETED session as the active one
// in the detail pane (the sidebar no longer listed it). Verified reachable on both paths before the fix.
enum ReopenSelectionChecks {

    /// Every session is present in the archive, but only the live ones are selectable on reopen.
    @MainActor static func defaultPathPicksALiveSession() throws {
        let dir = try StorageEvolutionChecks.newDirectory("reopen-selection-default")
        let model = ClientModel(directory: dir, configURL: materialCheckConfigURL)
        model.add(demo: false)
        model.add(demo: false)
        let ids = model.archive.sessions.map(\.id)
        model.title("会话A", id: ids[0]); model.title("会话B", id: ids[1])
        try legacyRequire(model.persist(), "fixture must be persisted")

        // Delete the session that occupies `archive.sessions[0]` — the exact slot a reopen would otherwise pick.
        model.selection = ids[0]
        model.deleteSelected()
        try legacyRequire(model.archive.sessions[0].isDeleted, "the first archive slot must be the deleted one")
        _ = model.persist()

        let reopened = ClientModel(directory: dir, configURL: materialCheckConfigURL)
        try legacyRequire(reopened.archive.sessions.count == 2, "reopen keeps both records for audit")
        try legacyRequire(reopened.archive.deletedSessions.count == 1, "the tombstone survives reopen")
        try legacyRequire(!reopened.archive.activeSessions.isEmpty, "one session is still live")
        try legacyRequire(reopened.selection == reopened.archive.activeSessions.first?.id,
                          "initial selection must be a live session, got \(reopened.selection ?? "nil")")
        try legacyRequire(reopened.selected?.isDeleted == false,
                          "the detail pane must never open on a deleted session")
        try legacyRequire(reopened.visibleSessions.count == 1 && reopened.visibleSessions[0].id != ids[0],
                          "the sidebar lists only the live session")
        print("PASS reopen selection (default path) lands on a live session, deleted slot excluded")
    }

    /// The incremental path restores the archive from the projection, where tombstones are equally present.
    @MainActor static func incrementalPathPicksALiveSession() async throws {
        let dir = try StorageEvolutionChecks.newDirectory("reopen-selection-incremental")
        let model = ClientModel(directory: dir, configURL: materialCheckConfigURL)
        await model.enableIncrementalOnLaunch()
        try legacyRequire(model.incremental != nil, "incremental mode must be ready")
        model.add(demo: false)
        model.add(demo: false)
        let ids = model.archive.sessions.map(\.id)
        model.title("增量A", id: ids[0]); model.title("增量B", id: ids[1])
        _ = try? await model.incremental?.awaitQuiescence()

        model.selection = ids[0]
        model.deleteSelected()
        _ = try? await model.incremental?.awaitQuiescence()
        try legacyRequire(model.archive.sessions[0].isDeleted, "the first archive slot must be the deleted one")

        let reopened = ClientModel(directory: dir, configURL: materialCheckConfigURL)
        await reopened.enableIncrementalOnLaunch()
        try legacyRequire(reopened.archive.sessions.count == 2, "incremental reopen keeps the tombstoned record")
        try legacyRequire(reopened.archive.deletedSessions.count == 1, "the tombstone is restored from the journal")
        try legacyRequire(reopened.selection == reopened.archive.activeSessions.first?.id,
                          "incremental reopen must select a live session, got \(reopened.selection ?? "nil")")
        try legacyRequire(reopened.selected?.isDeleted == false,
                          "the incremental reopen must not open on a deleted session")
        print("PASS reopen selection (incremental path) lands on a live session, deleted slot excluded")
    }

    /// Deleting everything must leave NO selection at all (empty state), never a deleted session.
    @MainActor static func allDeletedLeavesNoSelection() async throws {
        // Whole-archive path.
        let plain = try StorageEvolutionChecks.newDirectory("reopen-selection-alldeleted")
        let one = ClientModel(directory: plain, configURL: materialCheckConfigURL)
        one.add(demo: false)
        one.deleteSelected()
        try legacyRequire(one.archive.activeSessions.isEmpty, "the only session is deleted")
        _ = one.persist()

        let reopened = ClientModel(directory: plain, configURL: materialCheckConfigURL)
        try legacyRequire(reopened.archive.sessions.count == 1, "the deleted record is retained for audit")
        try legacyRequire(reopened.archive.activeSessions.isEmpty, "nothing is live after deleting all")
        try legacyRequire(reopened.selection == nil, "all-deleted must select nothing, got \(reopened.selection ?? "nil")")
        try legacyRequire(reopened.selected == nil, "the detail pane must fall back to its empty state")
        try legacyRequire(reopened.visibleSessions.isEmpty, "the sidebar is empty")

        // Incremental path.
        let inc = try StorageEvolutionChecks.newDirectory("reopen-selection-alldeleted-inc")
        let two = ClientModel(directory: inc, configURL: materialCheckConfigURL)
        await two.enableIncrementalOnLaunch()
        two.add(demo: false)
        two.deleteSelected()
        _ = try? await two.incremental?.awaitQuiescence()
        try legacyRequire(two.archive.activeSessions.isEmpty, "the only incremental session is deleted")

        let reopenedInc = ClientModel(directory: inc, configURL: materialCheckConfigURL)
        await reopenedInc.enableIncrementalOnLaunch()
        try legacyRequire(reopenedInc.archive.sessions.count == 1, "incremental reopen retains the deleted record")
        try legacyRequire(reopenedInc.selection == nil, "incremental all-deleted must select nothing, got \(reopenedInc.selection ?? "nil")")
        try legacyRequire(reopenedInc.selected == nil, "incremental detail pane must fall back to its empty state")
        print("PASS all sessions deleted leaves an empty selection on both paths (no fallback to a deleted session)")
    }

    /// `selected` itself keeps its full-archive lookup, because the audit view needs it. Only the INITIAL pick is
    /// restricted; narrowing `selected` would break audit rendering of a deleted session.
    @MainActor static func auditLookupStillResolvesDeletedSessions() throws {
        let dir = try StorageEvolutionChecks.newDirectory("reopen-selection-audit")
        let model = ClientModel(directory: dir, configURL: materialCheckConfigURL)
        model.add(demo: false)
        let id = model.archive.sessions[0].id
        model.selection = id
        model.deleteSelected()
        _ = model.persist()

        let reopened = ClientModel(directory: dir, configURL: materialCheckConfigURL)
        let deleted = reopened.archive.deletedSessions.first
        try legacyRequire(deleted?.id == id, "the deleted session is still addressable for audit")
        // Deliberately point the selection AT the deleted session: this is the audit case, and it must resolve.
        reopened.selection = id
        try legacyRequire(reopened.selected?.id == id,
                          "selected must keep resolving deleted sessions for the audit view")
        try legacyRequire(reopened.selected?.isDeleted == true, "and it reports the session as deleted")
        try legacyRequire(reopened.deletedAuditText().contains(id), "the audit text names the deleted session")
        print("PASS selected keeps the full-archive lookup for audit; only the initial pick is restricted")
    }
}

@MainActor func runReopenSelectionChecks() async throws {
    try ReopenSelectionChecks.defaultPathPicksALiveSession()
    try await ReopenSelectionChecks.incrementalPathPicksALiveSession()
    try await ReopenSelectionChecks.allDeletedLeavesNoSelection()
    try ReopenSelectionChecks.auditLookupStillResolvesDeletedSessions()
}
