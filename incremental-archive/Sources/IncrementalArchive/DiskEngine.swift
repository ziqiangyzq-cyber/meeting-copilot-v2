import Foundation
import CryptoKit
import Darwin

struct CheckedFrame: Codable {
    let schemaVersion: Int
    let body: Data
    let sha256: String
}
struct SnapshotBody: Codable, Equatable {
    let schemaVersion: Int, replayStartSequence: UInt64, headSequence: UInt64
    let records: [ArchiveRecord]
}
final class DiskEngine {
    let directory: URL, logURL: URL, snapshotURL: URL, limits: ArchiveLimits
    let fault: (@Sendable (ArchiveFaultPoint) throws -> Void)?
    private(set) var records: [ArchiveRecord] = []
    private var identities: [UUID: ArchiveRecord] = [:]
    private var semantic = SemanticState()
    private var interrupted: Set<ArchiveFence> = []
    private var offset: UInt64 = 0
    private(set) var tail: ArchiveTail?
    var head: UInt64 { records.last?.commitSequence ?? 0 }
    var unfinished: [ArchiveFence] { semantic.unfinished }
    init(directory: URL, limits: ArchiveLimits, fault: (@Sendable (ArchiveFaultPoint) throws -> Void)?) {
        self.directory = directory; self.limits = limits; self.fault = fault
        logURL = directory.appendingPathComponent("records.ndjson")
        snapshotURL = directory.appendingPathComponent("snapshot.json")
    }
    private func assertBackground() { precondition(!Thread.isMainThread, "Archive encoding and IO must run on writer queue") }
    private func locked<T>(_ action: () throws -> T) throws -> T {
        assertBackground()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lockURL = directory.appendingPathComponent("writer.lock")
        let fd = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw ArchiveFailure.io("open lock", errno) }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw ArchiveFailure.busy }
        defer { flock(fd, LOCK_UN) }
        return try action()
    }
    private func encoder() -> JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e }
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func frame<T: Encodable>(_ value: T) throws -> Data {
        let body = try encoder().encode(value)
        return try encoder().encode(CheckedFrame(schemaVersion: 1, body: body, sha256: hash(body)))
    }
    private func decode<T: Decodable>(_ data: Data, as type: T.Type, at offset: UInt64) throws -> T {
        do {
            let frame = try JSONDecoder().decode(CheckedFrame.self, from: data)
            guard frame.schemaVersion == 1 else { throw ArchiveFailure.unsupportedSchema(frame.schemaVersion) }
            guard frame.sha256 == hash(frame.body) else { throw ArchiveFailure.corrupt(offset: offset, reason: "checksum mismatch") }
            return try JSONDecoder().decode(T.self, from: frame.body)
        } catch let error as ArchiveFailure { throw error }
        catch { throw ArchiveFailure.corrupt(offset: offset, reason: String(describing: error)) }
    }
    private func readSuffix() throws {
        assertBackground(); tail = nil
        guard FileManager.default.fileExists(atPath: logURL.path) else {
            guard offset == 0 else { throw ArchiveFailure.corrupt(offset: offset, reason: "log removed") }; return
        }
        let file = try FileHandle(forReadingFrom: logURL); defer { try? file.close() }
        let length = try file.seekToEnd()
        guard length >= offset else { throw ArchiveFailure.corrupt(offset: length, reason: "log shortened; no automatic truncation") }
        guard length <= UInt64(limits.maximumReplayBytes) else { throw ArchiveFailure.replayLimit }
        try file.seek(toOffset: offset)
        var buffer = Data()
        while true {
            let chunk = try file.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 10) {
                let lineLength = buffer.distance(from: buffer.startIndex, to: newline)
                guard lineLength > 0, lineLength + 1 <= limits.maximumEncodedRecordBytes else { throw ArchiveFailure.corrupt(offset: offset, reason: "empty/oversized complete frame") }
                let line = Data(buffer.prefix(lineLength))
                let record = try decode(line, as: ArchiveRecord.self, at: offset)
                guard record.schemaVersion == 1 else { throw ArchiveFailure.unsupportedSchema(record.schemaVersion) }
                guard head < UInt64.max, record.commitSequence == head + 1,
                      record.submission.expectedHead == head, identities[record.submission.id] == nil else { throw ArchiveFailure.corrupt(offset: offset, reason: "sequence/identity discontinuity") }
                _ = try limits.reservation(record.submission)
                var candidate = semantic; try candidate.apply(record)
                guard records.count < limits.maximumReplayRecords else { throw ArchiveFailure.replayLimit }
                semantic = candidate; records.append(record); identities[record.submission.id] = record
                offset += UInt64(lineLength + 1)
                buffer = Data(buffer.dropFirst(lineLength + 1))
            }
            guard buffer.count < limits.maximumEncodedRecordBytes else { throw ArchiveFailure.corrupt(offset: offset, reason: "oversized unterminated frame") }
        }
        if !buffer.isEmpty { tail = ArchiveTail(offset: offset, bytes: buffer) }
    }
    private func requireCompleteTail() throws {
        if let tail { throw ArchiveFailure.incompleteTail(offset: tail.offset, bytes: tail.bytes.count) }
    }
    func bootstrap() throws -> ArchiveRecovery {
        try locked {
            if !FileManager.default.fileExists(atPath: logURL.path), FileManager.default.fileExists(atPath: directory.appendingPathComponent("sessions.json").path) {
                throw ArchiveFailure.legacyMigrationRequired
            }
            try readSuffix()
            if FileManager.default.fileExists(atPath: snapshotURL.path) {
                let size = try FileManager.default.attributesOfItem(atPath: snapshotURL.path)[.size] as? NSNumber
                guard (size?.uint64Value ?? UInt64.max) <= UInt64(limits.maximumReplayBytes) * 2 else { throw ArchiveFailure.replayLimit }
                let snapshot = try decode(Data(contentsOf: snapshotURL), as: SnapshotBody.self, at: 0)
                guard snapshot.schemaVersion == 1 else { throw ArchiveFailure.unsupportedSchema(snapshot.schemaVersion) }
                guard snapshot.replayStartSequence == 0, snapshot.headSequence <= head,
                      (snapshot.records.last?.commitSequence ?? 0) == snapshot.headSequence,
                      snapshot.records == Array(records.prefix(snapshot.records.count)) else { throw ArchiveFailure.corrupt(offset: 0, reason: "snapshot/log prefix or replay start mismatch") }
            }
            interrupted = Set(unfinished)
            return ArchiveRecovery(records: records, head: head, incompleteTail: tail, unfinishedAttempts: unfinished, requiresExplicitRecovery: tail != nil || !unfinished.isEmpty)
        }
    }
    private func write(_ bytes: Data, to fd: Int32) throws {
        try bytes.withUnsafeBytes { raw in
            var done = 0
            while done < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: done), raw.count - done)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw ArchiveFailure.io("append log", errno) }
                done += n
            }
        }
    }
    private func syncFile(_ url: URL) throws {
        try fault?(.beforeFsync)
        let fd = Darwin.open(url.path, O_RDONLY)
        guard fd >= 0 else { throw ArchiveFailure.io("open fsync", errno) }; defer { Darwin.close(fd) }
        guard Darwin.fsync(fd) == 0 else { throw ArchiveFailure.io("fsync file", errno) }
    }
    private func syncDirectory() throws {
        let fd = Darwin.open(directory.path, O_RDONLY)
        guard fd >= 0 else { throw ArchiveFailure.io("open directory fsync", errno) }; defer { Darwin.close(fd) }
        guard Darwin.fsync(fd) == 0 else { throw ArchiveFailure.io("fsync directory", errno) }
    }
    func append(_ request: ArchiveSubmission, reservation: Int) throws -> ArchiveAcknowledgement {
        try locked {
            try readSuffix(); try requireCompleteTail()
            let record = try ArchiveRecord(request)
            if let existing = identities[request.id] {
                guard existing == record else { throw ArchiveFailure.identityConflict(request.id) }
                if request.durability == .fsync { try syncFile(logURL); try syncDirectory() }
                try fault?(.beforeAcknowledgement)
                return ArchiveAcknowledgement(token: ArchiveToken(submissionID: request.id, plannedCommitSequence: existing.commitSequence, fence: request.fence), alreadyPresent: true, durability: request.durability)
            }
            guard request.expectedHead == head else { throw ArchiveFailure.conflict(expected: request.expectedHead, actual: head) }
            if interrupted.contains(request.fence) {
                guard request.deltas.count == 1, case .attemptEnded(let outcome, _) = request.deltas[0], outcome != .completed else {
                    throw ArchiveFailure.fence("recovered interrupted attempt requires explicit incomplete/cancelled terminal; no renewed capture")
                }
            }
            var candidate = semantic; try candidate.apply(record)
            try fault?(.beforeEncode)
            var bytes = try frame(record); bytes.append(10)
            guard bytes.count <= reservation, bytes.count <= limits.maximumEncodedRecordBytes else { throw ArchiveFailure.recordTooLarge(actual: bytes.count, limit: min(reservation, limits.maximumEncodedRecordBytes)) }
            guard offset <= UInt64(limits.maximumReplayBytes), UInt64(bytes.count) <= UInt64(limits.maximumReplayBytes) - offset,
                  records.count < limits.maximumReplayRecords else { throw ArchiveFailure.replayLimit }
            try fault?(.beforeWrite)
            let fd = Darwin.open(logURL.path, O_CREAT | O_WRONLY | O_APPEND, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { throw ArchiveFailure.io("open append", errno) }; defer { Darwin.close(fd) }
            if fault != nil, bytes.count > 2 {
                let split = bytes.count / 2
                try write(Data(bytes.prefix(split)), to: fd); try fault?(.afterPartialWrite)
                try write(Data(bytes.dropFirst(split)), to: fd)
            } else { try write(bytes, to: fd) }
            try fault?(.afterWrite); try fault?(.beforeReadback)
            try readSuffix(); try requireCompleteTail()
            guard identities[request.id] == record else { throw ArchiveFailure.corrupt(offset: offset, reason: "exact record readback mismatch") }
            if request.durability == .fsync { try syncFile(logURL); try syncDirectory() }
            try fault?(.beforeAcknowledgement)
            return ArchiveAcknowledgement(token: ArchiveToken(submissionID: request.id, plannedCommitSequence: record.commitSequence, fence: request.fence), alreadyPresent: false, durability: request.durability)
        }
    }
    func flush(expectedHead: UInt64, durability: ArchiveDurability) throws {
        try locked {
            try readSuffix(); try requireCompleteTail()
            guard expectedHead == head else { throw ArchiveFailure.conflict(expected: expectedHead, actual: head) }
            if durability == .fsync {
                if FileManager.default.fileExists(atPath: logURL.path) { try syncFile(logURL) }
                try syncDirectory()
            }
        }
    }
    func checkpoint(expectedHead: UInt64, durability: ArchiveDurability) throws {
        try locked {
            try readSuffix(); try requireCompleteTail()
            guard expectedHead == head else { throw ArchiveFailure.conflict(expected: expectedHead, actual: head) }
            if durability == .fsync, FileManager.default.fileExists(atPath: logURL.path) { try syncFile(logURL) }
            let snapshot = SnapshotBody(schemaVersion: 1, replayStartSequence: 0, headSequence: head, records: records)
            let bytes = try frame(snapshot)
            guard bytes.count <= limits.maximumReplayBytes * 2 else { throw ArchiveFailure.replayLimit }
            try fault?(.beforeSnapshotWrite)
            try bytes.write(to: snapshotURL, options: .atomic)
            try fault?(.afterSnapshotWrite)
            let actual = try Data(contentsOf: snapshotURL)
            guard actual == bytes, try decode(actual, as: SnapshotBody.self, at: 0) == snapshot else { throw ArchiveFailure.corrupt(offset: 0, reason: "snapshot exact readback mismatch") }
            if durability == .fsync { try syncFile(snapshotURL); try syncDirectory() }
            // No log deletion/rotation in v1, before OR after snapshot acknowledgement.
        }
    }
    func recovery() throws -> ArchiveRecovery {
        try locked {
            try readSuffix()
            return ArchiveRecovery(records: records, head: head, incompleteTail: tail, unfinishedAttempts: unfinished, requiresExplicitRecovery: tail != nil || !unfinished.isEmpty)
        }
    }
}
