import Foundation

public struct ArchiveFailureNotice: Sendable {
    public let token: ArchiveToken, error: ArchiveFailure, wasAttempted: Bool
}
// Only this serial queue encodes records or touches disk. Admission/status use a short lock.
public final class IncrementalArchiveWriter: @unchecked Sendable {
    private struct Commit {
        let request: ArchiveSubmission, token: ArchiveToken, reservation: Int
        let ack: @Sendable (ArchiveAcknowledgement) throws -> Void
        let failed: @Sendable (ArchiveFailureNotice) -> Void
    }
    private enum ControlKind: Equatable { case flush, checkpoint, close }
    private struct Control {
        let kind: ControlKind, target: UInt64, durability: ArchiveDurability
        let completed: @Sendable (Result<ArchiveWatermark, ArchiveFailure>) -> Void
    }
    private enum Work {
        case commit(Commit), control(Control)
        var bytes: Int { if case .commit(let job) = self { return job.reservation }; return 0 }
    }
    private let queue = DispatchQueue(label: "io.github.ziqiangyzq-cyber.meeting-copilot.incremental-archive.writer", qos: .utility)
    private let lock = NSLock()
    private let limits: ArchiveLimits
    private let engine: DiskEngine
    private var pending: [Work] = []
    private var bytes = 0
    private var running = false
    private var closing = false
    private var closed = false
    private var blocked: ArchiveFailure? = nil
    private var confirmed: UInt64 = 0
    private var synced: UInt64 = 0
    private init(directory: URL, limits: ArchiveLimits, fault: (@Sendable (ArchiveFaultPoint) throws -> Void)?) {
        self.limits = limits; engine = DiskEngine(directory: directory, limits: limits, fault: fault)
    }
    public static func open(directory: URL, limits: ArchiveLimits = ArchiveLimits(), fault: (@Sendable (ArchiveFaultPoint) throws -> Void)? = nil) async throws -> IncrementalArchiveWriter {
        try limits.validate()
        let writer = IncrementalArchiveWriter(directory: directory, limits: limits, fault: fault)
        return try await withCheckedThrowingContinuation { continuation in
            writer.queue.async {
                do {
                    let recovery = try writer.engine.bootstrap()
                    if let tail = recovery.incompleteTail { throw ArchiveFailure.incompleteTail(offset: tail.offset, bytes: tail.bytes.count) }
                    writer.lock.lock(); writer.confirmed = recovery.head; writer.lock.unlock()
                    continuation.resume(returning: writer)
                } catch { continuation.resume(throwing: normalize(error)) }
            }
        }
    }
    public static func inspect(directory: URL, limits: ArchiveLimits = ArchiveLimits()) async throws -> ArchiveRecovery {
        try limits.validate()
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue(label: "io.github.ziqiangyzq-cyber.meeting-copilot.incremental-archive.inspect").async {
                do { continuation.resume(returning: try DiskEngine(directory: directory, limits: limits, fault: nil).bootstrap()) }
                catch { continuation.resume(throwing: normalize(error)) }
            }
        }
    }
    public var status: ArchiveWriterStatus {
        lock.lock(); defer { lock.unlock() }
        return ArchiveWriterStatus(pendingCount: pending.count, reservedBytes: bytes, confirmedHead: confirmed, fsyncedHead: synced, blocked: blocked, closing: closing, closed: closed)
    }
    public var unconfirmedSubmissions: [ArchiveSubmission] {
        lock.lock(); defer { lock.unlock() }
        return pending.compactMap { if case .commit(let c) = $0 { return c.request }; return nil }
    }
    // Progress callbacks may fail first and later acknowledge on explicit retry. They are not one-shot Futures.
    // Ack callback is on the writer queue and may throw if delivery fails; no watermark advances then.
    @discardableResult public func submit(_ request: ArchiveSubmission,
        onAcknowledged: @escaping @Sendable (ArchiveAcknowledgement) throws -> Void,
        onFailure: @escaping @Sendable (ArchiveFailureNotice) -> Void) throws -> ArchiveToken {
        guard request.expectedHead < UInt64.max else { throw ArchiveFailure.sequenceOverflow }
        let reservation = try limits.reservation(request)
        let token = ArchiveToken(submissionID: request.id, plannedCommitSequence: request.expectedHead + 1, fence: request.fence)
        lock.lock(); defer { lock.unlock() }
        guard !closing, !closed else { throw ArchiveFailure.closed }
        // Once faulted, no additional producer data is accepted; caller retains rejected input.
        if let blocked { throw blocked }
        guard pending.count < limits.maximumPendingCount, reservation <= limits.maximumPendingBytes - bytes else { throw ArchiveFailure.queueFull }
        pending.append(.commit(Commit(request: request, token: token, reservation: reservation, ack: onAcknowledged, failed: onFailure)))
        bytes += reservation; scheduleLocked(); return token
    }
    public func retryUnconfirmed() throws {
        lock.lock(); defer { lock.unlock() }
        guard !closed, !running else { throw ArchiveFailure.invalidInput("retry only after blocked writer stopped") }
        blocked = nil; scheduleLocked()
    }
    public func flush(through: UInt64? = nil, durability: ArchiveDurability = .readback) async throws -> ArchiveWatermark {
        try await control(.flush, through: through, durability: durability)
    }
    public func checkpoint(durability: ArchiveDurability = .fsync) async throws -> ArchiveWatermark {
        try await control(.checkpoint, through: nil, durability: durability)
    }
    public func close(durability: ArchiveDurability = .fsync) async throws -> ArchiveWatermark {
        try await control(.close, through: nil, durability: durability)
    }
    private func control(_ kind: ControlKind, through: UInt64?, durability: ArchiveDurability) async throws -> ArchiveWatermark {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock(); defer { lock.unlock() }
            if let blocked { continuation.resume(throwing: blocked); return }
            guard !closed, !closing else { continuation.resume(throwing: ArchiveFailure.closed); return }
            guard pending.count < limits.maximumPendingCount else { continuation.resume(throwing: ArchiveFailure.queueFull); return }
            let target = pending.reduce(confirmed) { head, work in
                if case .commit(let c) = work { return max(head, c.token.plannedCommitSequence) }; return head
            }
            if let through, through > target { continuation.resume(throwing: ArchiveFailure.invalidInput("barrier target not submitted")); return }
            if kind == .close { closing = true }
            pending.append(.control(Control(kind: kind, target: target, durability: durability, completed: { continuation.resume(with: $0.mapError { $0 as Error }) })))
            scheduleLocked()
        }
    }
    private func scheduleLocked() {
        guard !running, blocked == nil, !pending.isEmpty else { return }
        running = true; queue.async { self.drain() }
    }
    private func drain() {
        precondition(!Thread.isMainThread)
        while true {
            lock.lock()
            guard blocked == nil, let work = pending.first else { running = false; lock.unlock(); return }
            let before = confirmed; lock.unlock()
            do {
                switch work {
                case .commit(let job):
                    // A completed/closed record never runs while prior accepted jobs are unconfirmed.
                    for delta in job.request.deltas {
                        switch delta {
                        case .attemptEnded(_, let dependency), .sessionClosed(let dependency):
                            guard dependency == job.request.expectedHead, before >= dependency else { throw ArchiveFailure.fence("terminal requires acknowledged dependency watermark") }
                        default: break
                        }
                    }
                    let ack = try engine.append(job.request, reservation: job.reservation)
                    do { try job.ack(ack) }
                    catch { throw ArchiveFailure.acknowledgementFailed(String(describing: error)) }
                    lock.lock(); confirmed = max(confirmed, ack.token.plannedCommitSequence)
                    if ack.durability == .fsync { synced = max(synced, ack.token.plannedCommitSequence) }
                    bytes -= job.reservation; pending.removeFirst(); lock.unlock()
                case .control(let barrier):
                    guard before >= barrier.target else { throw ArchiveFailure.fence("barrier before acknowledgement watermark") }
                    if barrier.kind == .close, !engine.unfinished.isEmpty { throw ArchiveFailure.fence("normal close requires explicit terminal for every unfinished attempt") }
                    if barrier.kind == .checkpoint { try engine.checkpoint(expectedHead: barrier.target, durability: barrier.durability) }
                    else { try engine.flush(expectedHead: barrier.target, durability: barrier.durability) }
                    lock.lock()
                    if barrier.durability == .fsync { synced = max(synced, barrier.target) }
                    if barrier.kind == .close { closed = true; closing = false }
                    pending.removeFirst()
                    let watermark = ArchiveWatermark(confirmedHead: confirmed, fsyncedHead: synced); lock.unlock()
                    barrier.completed(.success(watermark))
                }
            } catch {
                let failure = normalize(error)
                lock.lock(); blocked = failure; running = false; closing = false
                var retained: [Work] = [], notices: [(Commit, Bool)] = [], barriers: [Control] = []
                for (index, queued) in pending.enumerated() {
                    switch queued {
                    case .commit(let c): retained.append(queued); notices.append((c, index == 0))
                    case .control(let c): barriers.append(c)
                    }
                }
                pending = retained; lock.unlock()
                // Every accepted revision (including the in-flight one) is retained. Wake waiting barriers.
                for (job, attempted) in notices { job.failed(ArchiveFailureNotice(token: job.token, error: failure, wasAttempted: attempted)) }
                for barrier in barriers { barrier.completed(.failure(failure)) }
                return
            }
        }
    }
}
private func normalize(_ error: Error) -> ArchiveFailure {
    if let error = error as? ArchiveFailure { return error }
    return .io(String(describing: error), 0)
}
