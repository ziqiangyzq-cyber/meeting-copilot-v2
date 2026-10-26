import Foundation
import IncrementalArchive
import SpeechCore

public struct BridgeState {
    // Delivered acknowledgement watermark; use flush for writer confirmation/durability.
    public let acknowledgedProjection: BridgeProjection
    public let unconfirmed: [ArchiveSubmission]
    public let failures: [UUID: ArchiveFailure]
    public let admittedCount: Int, reservedBytes: Int
}
public struct BridgeLimits {
    public let maximumAdmittedCount: Int, maximumReservedBytes: Int
    public init(maximumAdmittedCount: Int = 32, maximumReservedBytes: Int = 8 * 1024 * 1024) {
        self.maximumAdmittedCount = maximumAdmittedCount; self.maximumReservedBytes = maximumReservedBytes
    }
}
public final class ClientArchiveBridge: @unchecked Sendable {
    public let writer: IncrementalArchiveWriter
    private let queue = DispatchQueue(label: "io.github.ziqiangyzq-cyber.meeting-copilot.client-incremental-bridge.admission")
    private let lock = NSLock()
    private let budget: BridgeLimits
    private var projection: BridgeProjection
    // Accessed ONLY by admission queue after init. Never used as saved UI state.
    private var knownIDs: Set<UUID> = []
    private var planned: BridgeProjection
    private var pending: [UUID: ArchiveSubmission] = [:]
    private var reservations: [UUID: Int] = [:]
    private var reservedBytes = 0
    private var failures: [UUID: ArchiveFailure] = [:]
    private let beforeValidation: (@Sendable () -> Void)?
    private init(writer: IncrementalArchiveWriter, projection: BridgeProjection, budget: BridgeLimits,
                 beforeValidation: (@Sendable () -> Void)?) {
        self.writer = writer; self.projection = projection; planned = projection
        self.budget = budget; self.beforeValidation = beforeValidation
    }
    public static func open(directory: URL, limits: CoreLimits, budget: BridgeLimits = BridgeLimits(),
                            fault: (@Sendable (ArchiveFaultPoint) throws -> Void)? = nil,
                            beforeValidation: (@Sendable () -> Void)? = nil) async throws -> ClientArchiveBridge {
        guard budget.maximumAdmittedCount > 0, budget.maximumAdmittedCount <= 32,
              budget.maximumReservedBytes >= 4096, budget.maximumReservedBytes <= 8 * 1024 * 1024 else { throw BridgeFailure.invalid("bridge budget") }
        let writer = try await IncrementalArchiveWriter.open(directory: directory, fault: fault)
        let recovery = try await IncrementalArchiveWriter.inspect(directory: directory)
        let projected = try await Task.detached {
            var p = BridgeProjection(limits: limits)
            for record in recovery.records { try p.apply(record.submission) }
            return p
        }.value
        guard writer.status.confirmedHead == projected.head else { throw BridgeFailure.invalid("open changed head") }
        let bridge = ClientArchiveBridge(writer: writer, projection: projected, budget: budget, beforeValidation: beforeValidation)
        bridge.knownIDs = Set(recovery.records.map { $0.submission.id })
        return bridge
    }
    public var state: BridgeState {
        lock.lock()
        let p = projection, requests = pending, errors = failures, count = reservations.count, bytes = reservedBytes
        lock.unlock()
        // Sorting outside lock; projection is an immutable COW snapshot.
        return BridgeState(acknowledgedProjection: p, unconfirmed: requests.values.sorted { $0.expectedHead < $1.expectedHead },
                           failures: errors, admittedCount: count, reservedBytes: bytes)
    }
    public func submit(id: UUID = UUID(), fence: ArchiveFence, deltas: [ArchiveDelta],
                       durability: ArchiveDurability = .readback,
                       onAcknowledged: @escaping @Sendable (ArchiveAcknowledgement) -> Void = { _ in },
                       onFailure: @escaping @Sendable (ArchiveFailureNotice) -> Void = { _ in }) async throws -> ArchiveToken {
        try await submit(id: id, fence: fence, durability: durability, onAcknowledged: onAcknowledged, onFailure: onFailure) { _ in deltas }
    }
    private func releaseLocked(_ id: UUID) {
        if let bytes = reservations.removeValue(forKey: id) { reservedBytes -= bytes }
    }
    // No queue.async capture of payload/continuation until bounded permit is granted.
    // `build` runs on the admission queue with the actual planned head, so terminal deltas can carry the
    // exact expected storage watermark instead of a caller guess. Reservation uses build(0) (same delta shape).
    public func submit(id: UUID = UUID(), fence: ArchiveFence, durability: ArchiveDurability = .readback,
                       onAcknowledged: @escaping @Sendable (ArchiveAcknowledgement) -> Void = { _ in },
                       onFailure: @escaping @Sendable (ArchiveFailureNotice) -> Void = { _ in },
                       build: @escaping @Sendable (UInt64) throws -> [ArchiveDelta]) async throws -> ArchiveToken {
        let provisional = min(256 * 1024, budget.maximumReservedBytes)
        try lock.withLock {
            guard reservations[id] == nil else { throw BridgeFailure.invalid("stable ID already admitted; retry original") }
            guard reservations.count < budget.maximumAdmittedCount, provisional <= budget.maximumReservedBytes - reservedBytes else {
                throw ArchiveFailure.queueFull
            }
            reservations[id] = provisional; reservedBytes += provisional
        }
        do {
            let bytes = try await Task.detached { try Self.reservation(fence: fence, deltas: build(0)) }.value
            try lock.withLock {
                guard bytes <= provisional else { throw ArchiveFailure.queueFull }
                reservations[id] = bytes; reservedBytes -= provisional - bytes
            }
        } catch {
            lock.withLock { releaseLocked(id) }
            throw error
        }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                precondition(!Thread.isMainThread)
                do {
                    self.beforeValidation?() // Synthetic slow-validation hook; NEVER inside state lock.
                    let request = ArchiveSubmission(id: id, expectedHead: self.planned.head,
                        fence: fence, deltas: try build(self.planned.head), durability: durability)
                    var candidate = self.planned
                    var localValidationError: Error?
                    do { try candidate.apply(request) }
                    catch {
                        // Only an ID already admitted through this validated projection may delegate replay
                        // identity checks to the writer. New schema-valid but reducer-invalid wire is rejected.
                        guard self.knownIDs.contains(request.id) else { throw error }
                        localValidationError = error
                    }
                    let replayableLocally = localValidationError == nil
                    let validationError = localValidationError
                    self.lock.lock(); self.pending[id] = request; self.lock.unlock()
                    do {
                        let token = try self.writer.submit(request, onAcknowledged: { [weak self] ack in
                            guard let self else { throw BridgeFailure.invalid("bridge released with unconfirmed revision") }
                            self.lock.lock()
                            let request = self.pending[ack.token.submissionID], current = self.projection
                            self.lock.unlock()
                            guard let request, ack.token.submissionID == request.id,
                                  ack.token.plannedCommitSequence == request.expectedHead + 1,
                                  ack.token.fence == request.fence else { throw BridgeFailure.invalid("ack identity/fence mismatch") }
                            if !ack.alreadyPresent {
                                if !replayableLocally {
                                    // Writer accepted a record the local projection cannot replay: surface the divergence.
                                    self.lock.lock(); self.failures[request.id] = .invalidInput("projection/local replay divergence")
                                    self.lock.unlock()
                                    throw BridgeFailure.invalid("projection/local replay divergence")
                                } else {
                                    var next = current
                                    try next.apply(request) // Only serial writer ack mutates saved projection. No long lock.
                                    self.lock.lock()
                                    guard self.projection.head == current.head else { self.lock.unlock(); throw BridgeFailure.invalid("ack projection race") }
                                    self.projection = next
                                    self.lock.unlock()
                                }
                            }
                            self.lock.lock()
                            self.pending.removeValue(forKey: request.id)
                            self.failures.removeValue(forKey: request.id); self.releaseLocked(request.id)
                            self.lock.unlock()
                            // Never read writer.status here: it advances AFTER this callback.
                            onAcknowledged(ack)
                        }, onFailure: { [weak self] notice in
                            guard let self else { return }
                            self.lock.lock()
                            if self.pending[notice.token.submissionID] != nil { self.failures[notice.token.submissionID] = notice.error }
                            self.lock.unlock() // Keep every accepted reservation through failure/retry.
                            onFailure(notice)
                        })
                        self.knownIDs.insert(request.id)
                        self.planned = replayableLocally ? candidate : self.planned
                        continuation.resume(returning: token)
                    } catch {
                        self.lock.lock(); self.pending.removeValue(forKey: id); self.releaseLocked(id); self.lock.unlock()
                        throw validationError ?? error
                    }
                } catch {
                    self.lock.lock(); self.releaseLocked(id); self.lock.unlock()
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    // Closed grammar conservative reservation; NO JSON/wire decoding on caller/MainActor.
    // Bounds mirror current default writer, not a claim of actual heap measurement.
    public static func reservation(fence: ArchiveFence, deltas: [ArchiveDelta]) throws -> Int {
        // Same closed grammar as writer admission. No encoding, decoding or IO.
        try ArchiveLimits().reservation(ArchiveSubmission(
            id: UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)), expectedHead: 0,
            fence: fence, deltas: deltas))
    }

    // Flush only accepted writer jobs; queued bridge admission is visible via admittedCount.
    // Caller must await submit completions before stop/closing barrier; UI guard not yet wired.
    public func flush(durability: ArchiveDurability = .fsync) async throws -> ArchiveWatermark { try await writer.flush(durability: durability) }
    public func close(durability: ArchiveDurability = .fsync) async throws -> ArchiveWatermark { try await writer.close(durability: durability) }
    public func retryUnconfirmed() throws { try writer.retryUnconfirmed() }
}
