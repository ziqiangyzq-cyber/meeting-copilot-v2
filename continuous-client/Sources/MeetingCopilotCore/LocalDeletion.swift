import Foundation

/// Logical deletion surface. Deleting marks an auditable tombstone; content, revisions and the
/// authoritative journal stay in the archive so a reopen can explain the deletion and an audit
/// export can still reproduce the original record.
public enum LocalDeletion {
    public enum Failure: Error, LocalizedError, Equatable {
        case unknownSession, alreadyDeleted
        public var errorDescription: String? {
            switch self {
            case .unknownSession: return "要删除的会话不在当前档案中，未做任何改动。"
            case .alreadyDeleted: return "该会话已有删除记录，未重复写入。"
            }
        }
    }
    @discardableResult
    public static func tombstone(_ archive: inout LocalArchive, sessionID: String, at date: Date = Date(), reason: String = "user_requested") throws -> LocalTombstone {
        guard let index = archive.sessions.firstIndex(where: { $0.id == sessionID }) else { throw Failure.unknownSession }
        guard archive.sessions[index].tombstone == nil else { throw Failure.alreadyDeleted }
        let record = LocalTombstone(deletedAt: date, reason: reason)
        archive.sessions[index].tombstone = record
        return record
    }
    /// Audit view: deleted sessions with their retained content, in deletion order.
    public static func auditLines(_ archive: LocalArchive) -> [String] {
        archive.deletedSessions.sorted { ($0.tombstone!.deletedAt, $0.id) < ($1.tombstone!.deletedAt, $1.id) }.map { session in
            let record = session.tombstone!
            return "已删除会话 \(session.id) · \(session.title) · 删除于 \(ISO8601DateFormatter().string(from: record.deletedAt)) · 记录 \(record.id) · 执行方 \(record.actorKind) · 原因 \(record.reason) · 保留原文段 \(session.segments.count) · 保留随记版本 \(session.noteHistory.count)"
        }
    }
}
