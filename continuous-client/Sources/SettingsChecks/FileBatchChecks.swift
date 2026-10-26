import Foundation
import ClientRuntime

@MainActor func runFileBatchChecks(root: URL) async throws {
    let url = root.appendingPathComponent("synthetic-input.wav")
    // Explicit fake result: tests exercise client state, never claim actual backend inference.
    let final = FileBatchFinal(text: "fake final", providerID: "fake-qwen", engineVersion: "fake-engine-1", modelVersion: "fake-model", sourceURL: url, startNS: 0, endNS: 1_000_000_000)
    func settle(_ model: FileBatchModel) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while model.busy && ProcessInfo.processInfo.systemUptime < deadline { await Task.yield() }
        try settingsRequire(!model.busy, "fake batch timed out")
    }
    let success = FileBatchModel()
    var stored: [FileBatchFinal] = []
    try settingsRequire(success.start(files: [url], recognize: { _ in [final] }, commit: { stored += $0 }), "batch starts")
    try settingsRequire(!success.start(files: [url], recognize: { _ in [final] }, commit: { _ in }), "duplicate start is refused")
    try await settle(success)
    try settingsRequire(success.state == .completed(1) && stored == [final], "completion requires actual final commit")
    print("PASS fake file-batch: actual supplied finals commit before completion; duplicate start refused")

    let refusal = FileBatchModel()
    _ = refusal.start(files: [url], recognize: { _ in [final] }, commit: { _ in throw FileBatchFailure.invalidFinal })
    try await settle(refusal)
    if case .failed(_, saved: 0) = refusal.state {} else { throw SettingsCheckFailure(message: "commit failure must not show completed") }
    print("PASS fake file-batch: save failure remains failed, never completed")

    let cancelled = FileBatchModel()
    var continuation: CheckedContinuation<[FileBatchFinal], Never>?
    var lateCommits = 0
    _ = cancelled.start(files: [url], recognize: { _ in await withCheckedContinuation { continuation = $0 } }, commit: { _ in lateCommits += 1 })
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    while continuation == nil && ProcessInfo.processInfo.systemUptime < deadline { await Task.yield() }
    try settingsRequire(continuation != nil, "fake backend did not suspend")
    cancelled.cancel()
    continuation?.resume(returning: [final])
    // Run another bounded batch to give the cancelled continuation a scheduling opportunity.
    let barrier = FileBatchModel()
    _ = barrier.start(files: [url], recognize: { _ in await Task.yield(); return [final] }, commit: { _ in })
    try await settle(barrier)
    try settingsRequire(cancelled.state == .cancelled(saved: 0) && lateCommits == 0, "cancelled late final cannot commit")
    print("PASS fake file-batch: cancellation invalidates a backend that ignores cancellation")

    let empty = FileBatchModel()
    _ = empty.start(files: [url], recognize: { _ in [] }, commit: { _ in throw SettingsCheckFailure(message: "empty must not commit") })
    try await settle(empty)
    if case .failed(_, saved: 0) = empty.state {} else { throw SettingsCheckFailure(message: "missing final must fail") }
    print("PASS fake file-batch: missing final cannot masquerade as completed")

    let production = FileBatchModel()
    var ackedFiles = 0
    _ = production.start(files: [url, url], perform: { _ in ackedFiles += 1 })
    try await settle(production)
    try settingsRequire(production.state == .completed(2) && ackedFiles == 2, "production batch counts only acknowledged file operations")
    print("PASS fake file-batch: production adapter counts files only after its operation acknowledges")

    let rejected = FileBatchModel()
    _ = rejected.start(files: [url], perform: { _ in throw FileBatchFailure.invalidFinal })
    try await settle(rejected)
    if case .failed(_, saved: 0) = rejected.state {} else { throw SettingsCheckFailure(message: "production adapter failure cannot complete") }
    print("PASS fake file-batch: production adapter writer rejection stays failed")
}
