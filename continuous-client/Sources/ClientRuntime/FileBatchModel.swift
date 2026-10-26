import Foundation
import Combine

/// Client boundary; the integration controller adapter supplies only actual final segments.
public struct FileBatchFinal: Equatable, Sendable {
    public let text: String
    public let providerID: String
    public let engineVersion: String
    public let modelVersion: String?
    public let sourceURL: URL
    public let startNS: UInt64
    public let endNS: UInt64
    public init(text: String, providerID: String, engineVersion: String, modelVersion: String?, sourceURL: URL, startNS: UInt64, endNS: UInt64) {
        self.text = text; self.providerID = providerID; self.engineVersion = engineVersion
        self.modelVersion = modelVersion; self.sourceURL = sourceURL; self.startNS = startNS; self.endNS = endNS
    }
}

public enum FileBatchState: Equatable {
    case idle
    case running(completed: Int, total: Int)
    case completed(Int)
    case cancelled(saved: Int)
    case failed(String, saved: Int)
}

/// Sequential file batch. Each file is final and durably committed before it counts as completed.
/// Cancelling invalidates the token even if the backend ignores Task cancellation.
@MainActor public final class FileBatchModel: ObservableObject {
    public typealias Recognize = @MainActor (URL) async throws -> [FileBatchFinal]
    public typealias Commit = @MainActor ([FileBatchFinal]) throws -> Void
    @Published public private(set) var state: FileBatchState = .idle
    @Published public private(set) var files: [URL] = []
    public var busy: Bool { if case .running = state { return true }; return false }
    private var task: Task<Void, Never>?
    private var token = UUID()
    private var savedCount = 0

    public init() {}
    @discardableResult public func start(files: [URL], recognize: @escaping Recognize, commit: @escaping Commit) -> Bool {
        guard !busy, !files.isEmpty, files.allSatisfy({ $0.isFileURL }) else { return false }
        self.files = files; savedCount = 0; token = UUID()
        let current = token
        state = .running(completed: 0, total: files.count)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                for url in files {
                    try Task.checkCancellation()
                    let finals = try await recognize(url)
                    try Task.checkCancellation()
                    guard self.token == current else { return }
                    guard !finals.isEmpty, finals.allSatisfy({
                        $0.sourceURL == url && $0.endNS > $0.startNS && !$0.engineVersion.isEmpty && !$0.providerID.isEmpty
                    }) else { throw FileBatchFailure.invalidFinal }
                    // No suspension between the token check and durable commit.
                    try commit(finals)
                    self.savedCount += 1
                    self.state = .running(completed: self.savedCount, total: files.count)
                }
                guard self.token == current else { return }
                self.state = .completed(self.savedCount)
            } catch is CancellationError {
                guard self.token == current else { return }
                self.state = .cancelled(saved: self.savedCount)
            } catch {
                guard self.token == current else { return }
                self.state = .failed(error.localizedDescription, saved: self.savedCount)
            }
            if self.token == current { self.task = nil }
        }
        return true
    }
    /// Production adapter returns only after every segment has received durable acknowledgement.
    @discardableResult public func start(files: [URL], perform: @escaping @MainActor (URL) async throws -> Void) -> Bool {
        guard !busy, !files.isEmpty, files.allSatisfy({ $0.isFileURL }) else { return false }
        self.files = files; savedCount = 0; token = UUID()
        let current = token
        state = .running(completed: 0, total: files.count)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                for url in files {
                    try Task.checkCancellation()
                    try await perform(url)
                    try Task.checkCancellation()
                    guard self.token == current else { return }
                    self.savedCount += 1
                    self.state = .running(completed: self.savedCount, total: files.count)
                }
                guard self.token == current else { return }
                self.state = .completed(self.savedCount)
            } catch is CancellationError {
                guard self.token == current else { return }
                self.state = .cancelled(saved: self.savedCount)
            } catch {
                guard self.token == current else { return }
                self.state = .failed(error.localizedDescription, saved: self.savedCount)
            }
            if self.token == current { self.task = nil }
        }
        return true
    }

    public func cancel() {
        guard busy else { return }
        token = UUID(); task?.cancel(); task = nil
        state = .cancelled(saved: savedCount)
    }
}
public enum FileBatchFailure: Error, LocalizedError {
    case invalidFinal
    public var errorDescription: String? { "文件识别未提供有效 final、实际引擎或来源时间，未写回。" }
}
