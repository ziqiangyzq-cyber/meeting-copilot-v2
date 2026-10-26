import Foundation

/// Logical deletion only. Original content/revisions remain available for an explicit audit export.
public struct LocalTombstone: Codable, Equatable, Sendable {
    public let id: String
    public let deletedAt: Date
    public let actorKind: String
    public let reason: String
    public init(id: String = UUID().uuidString, deletedAt: Date = Date(), actorKind: String = "local_user", reason: String = "user_requested") {
        self.id = id; self.deletedAt = deletedAt; self.actorKind = actorKind; self.reason = reason
    }
}
public extension LocalSession {
    var isDeleted: Bool { tombstone != nil }
}
public extension LocalArchive {
    var activeSessions: [LocalSession] { sessions.filter { !$0.isDeleted } }
    var deletedSessions: [LocalSession] { sessions.filter(\.isDeleted) }
}
