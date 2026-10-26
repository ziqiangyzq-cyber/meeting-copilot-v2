import Foundation
import DesktopSessionController
import LocalASRProviders
import AppleOfflineSpeech

/// Two capture pumps share one loaded model. The bounded FIFO permits only one
/// native inference at a time; cancelling either channel invalidates the whole pair.
@MainActor public final class SerialQwenBackend: QwenSegmentBackend {
    private let underlying: any QwenSegmentBackend
    private var active = false
    private var closed = false
    private var generation = UUID()
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []
    public init(underlying: any QwenSegmentBackend) { self.underlying = underlying }
    public func preparedEngine(for configuration: ASRConfiguration) -> ASREngineIdentity? {
        closed ? nil : underlying.preparedEngine(for: configuration)
    }
    public func load(_ configuration: ASRConfiguration) async throws -> ASREngineIdentity {
        guard !active, waiters.isEmpty, !closed else { throw QwenControllerError.busy }
        return try await underlying.load(configuration)
    }
    public func transcribe(fileURL: URL, context: String?) async throws -> QwenBatchResult {
        let expected = generation, id = UUID()
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await acquire(id)
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelWaiter(id) }
        }
        defer { if generation == expected { release() } }
        guard !closed, generation == expected else { throw CancellationError() }
        try Task.checkCancellation()
        let result = try await underlying.transcribe(fileURL: fileURL, context: context)
        guard !closed, generation == expected else { throw CancellationError() }
        try Task.checkCancellation()
        return result
    }
    private func acquire(_ id: UUID) async throws {
        guard !closed else { throw CancellationError() }
        if !active { active = true; return }
        // Each of the two controllers has only one in-flight backend operation.
        guard waiters.count < 2 else { throw QwenControllerError.backpressure }
        try await withCheckedThrowingContinuation { waiters.append((id, $0)) }
    }
    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(throwing: CancellationError())
    }
    private func release() {
        if waiters.isEmpty { active = false }
        else { waiters.removeFirst().1.resume() }
    }
    public func cancel() {
        guard !closed else { return }
        closed = true; generation = UUID()
        let pending = waiters; waiters = []; active = false
        pending.forEach { $0.1.resume(throwing: CancellationError()) }
        underlying.cancel()
    }
    public func unload() { cancel(); underlying.unload() }
}
