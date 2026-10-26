import Foundation
import MeetingCopilotCore

/// Read/decode only: never invokes ArchiveStore.save or launch normalization.
public enum LegacyReadOnlyReader {
    public static func load(_ url: URL) throws -> LocalArchive {
        let archive = try JSONDecoder().decode(LocalArchive.self, from: Data(contentsOf: url))
        guard archive.schemaVersion == 1 else {
            throw NSError(domain: "LegacyReadOnly", code: 1, userInfo: [NSLocalizedDescriptionKey: "旧档版本不支持，无法查看"])
        }
        return archive
    }
}
@MainActor public final class LegacyReadOnlyModel: ObservableObject {
    public let source: URL
    @Published public private(set) var archive: LocalArchive?
    @Published public private(set) var failure: String?
    public init(source: URL) { self.source = source }
    public func reload() {
        do { archive = try LegacyReadOnlyReader.load(source); failure = nil }
        catch {
            archive = nil
            failure = "旧档读取失败：\(error.localizedDescription)。内容不可查看；不能据此认定旧档为空。"
        }
    }
}
