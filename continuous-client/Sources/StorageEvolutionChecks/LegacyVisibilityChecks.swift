import Foundation
import ClientRuntime
import MeetingCopilotCore

@MainActor func runLegacyVisibilityChecks() async throws {
    let dir = try StorageEvolutionChecks.newDirectory("legacy-visible-readonly")
    let (url, _) = try LegacyMigrationChecks.writeLegacyFixture(directory: dir)
    let before = try LegacyFileFingerprint.capture(url)
    let model = ClientModel(directory: dir, configURL: materialCheckConfigURL)
    await model.enableIncrementalOnLaunch()
    try legacyRequire(model.incremental?.canSubmit == true, "incremental can write")
    try legacyRequire(model.incrementalMigrationReport?.notMigratedCount == 3, "three un-migrated items remain explicit")
    let entries = model.incrementalMigrationReport!.entries.filter {
        if case .notMigrated = $0.disposition { return true }; return false
    }
    try legacyRequire(entries.count == 3, "visible list count matches report")
    let reader = LegacyReadOnlyModel(source: url)
    reader.reload()
    try legacyRequire(reader.failure == nil, "read-only original loads")
    let b = reader.archive?.sessions.first { $0.id == "legacy-b" }
    try legacyRequire(b?.segments.first?.revisions.first?.text == "无权威 wire", "un-migrated source remains viewable")
    try legacyRequire(b?.captureAttempts.first?.id == "attempt-b", "un-migrated attempt remains viewable")
    try legacyRequire(reader.archive?.sessions.first?.captureAttempts.first?.id == "attempt-a", "other attempt remains viewable")
    let reopened = ClientModel(directory: dir, configURL: materialCheckConfigURL)
    await reopened.enableIncrementalOnLaunch()
    try legacyRequire(reopened.incrementalMigrationReport?.notMigratedCount == 3, "reopen restores report and entry condition")
    reader.reload()
    let after = try LegacyFileFingerprint.capture(url)
    try legacyRequire(before == after, "read-only views/reopen leave SHA size mtime inode observations unchanged")
    print("PASS legacy visibility: writable with 3 un-migrated items; original source and attempts readable after reopen; fingerprint unchanged")

    let empty = try StorageEvolutionChecks.newDirectory("legacy-visible-no-old-file")
    let noOld = ClientModel(directory: empty, configURL: materialCheckConfigURL)
    try legacyRequire(noOld.incrementalMigrationReport == nil, "default no old archive has no migration entry")
    let missingReader = LegacyReadOnlyModel(source: empty.appendingPathComponent("sessions.json"))
    missingReader.reload()
    try legacyRequire(missingReader.archive == nil && missingReader.failure?.contains("读取失败") == true, "missing file is explicit failure, not empty archive")
    print("PASS legacy visibility: no old archive shows no migration; missing original reports failure, never empty success")

    let broken = try StorageEvolutionChecks.newDirectory("legacy-visible-corrupt")
    let brokenURL = broken.appendingPathComponent("sessions.json")
    try Data("invalid-json".utf8).write(to: brokenURL)
    let badBefore = try LegacyFileFingerprint.capture(brokenURL)
    let badReader = LegacyReadOnlyModel(source: brokenURL)
    badReader.reload()
    try legacyRequire(badReader.archive == nil && badReader.failure != nil, "malformed original is visible error")
    let badAfter = try LegacyFileFingerprint.capture(brokenURL)
    try legacyRequire(badBefore == badAfter, "failed read leaves original observations unchanged")
    print("PASS legacy visibility: malformed original fails explicitly without rewriting")
}
