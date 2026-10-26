import Foundation

/// One-time copy of the legacy Foresight data directory into the Meeting Copilot v2 directory.
///
/// This is intentionally a copy, not a rename: the old application and its data remain available as a
/// rollback path. The destination is assembled under a temporary sibling first, then moved into place, so an
/// interrupted copy never leaves a half-populated data directory that the client would treat as authoritative.
public enum LegacyProductMigration {
    public static let legacyDataDirectoryName = "org.local.foresight-rebuild.continuous-client"
    public static let legacyV2DataDirectoryName = "com.efc.meeting-copilot.v2"
    public static let legacyV2KeychainService = "com.efc.meeting-copilot.v2.backend-api"
    public static let destinationDirectoryName = ProductIdentity.dataDirectoryName
    public static let migrationMarkerName = ".migration-from-foresight.json"
    public static let previousV2MigrationMarkerName = ".migration-from-prepublic-v2.json"

    public struct Report: Codable, Sendable {
        public let source: String
        public let destination: String
        public let copiedFiles: Int
        public let excludedLockFiles: [String]
        public let migratedAt: String
        public let sourcePreserved: Bool
    }

    public enum MigrationError: Error, LocalizedError {
        case destinationAlreadyExists(String)
        case sourceMissing(String)
        case copyFailed(String)

        public var errorDescription: String? {
            switch self {
            case .destinationAlreadyExists(let path):
                return "Meeting Copilot 数据目录已经存在，未覆盖：\(path)"
            case .sourceMissing(let path):
                return "找不到旧版 Foresight 数据目录：\(path)"
            case .copyFailed(let reason):
                return "旧版数据复制失败：\(reason)"
            }
        }
    }

    /// Copies the old Application Support directory when, and only when, the new directory does not exist.
    /// Lock files are runtime coordination files, not meeting data, and are excluded from the copy.
    @discardableResult
    public static func migratePreviousV2DataIfNeeded(
        destination: URL,
        sourceDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> Report? {
        let source = sourceDirectory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(legacyV2DataDirectoryName, isDirectory: true)
        return try migrateData(
            source: source,
            destination: destination,
            markerName: previousV2MigrationMarkerName,
            fileManager: fileManager
        )
    }

    @discardableResult
    public static func migrateIfNeeded(destination: URL,
                                       sourceDirectory: URL? = nil,
                                       legacyProductRoots: [URL] = [],
                                       destinationProductRoot: URL? = nil,
                                       fileManager: FileManager = .default) throws -> Report? {
        let source = sourceDirectory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(legacyDataDirectoryName, isDirectory: true)
        return try migrateData(
            source: source,
            destination: destination,
            markerName: migrationMarkerName,
            rewrite: {
                try rewriteLegacyPaths(in: $0,
                                       legacyRoots: legacyProductRoots,
                                       destinationProductRoot: destinationProductRoot)
            },
            fileManager: fileManager
        )
    }

    private static func migrateData(
        source: URL,
        destination: URL,
        markerName: String,
        rewrite: ((URL) throws -> Void)? = nil,
        fileManager: FileManager
    ) throws -> Report? {
        let destination = destination.standardizedFileURL
        guard !fileManager.fileExists(atPath: destination.path) else { return nil }
        guard fileManager.fileExists(atPath: source.path) else { return nil }

        let staging = source.deletingLastPathComponent()
            .appendingPathComponent(".meeting-copilot-migration-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.copyItem(at: source, to: staging)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw MigrationError.copyFailed(error.localizedDescription)
        }

        do {
            let excluded = try removeLockFiles(in: staging, fileManager: fileManager)
            try rewrite?(staging)
            let files = try regularFiles(in: staging, fileManager: fileManager)
            let report = Report(source: source.path,
                                destination: destination.path,
                                copiedFiles: files,
                                excludedLockFiles: excluded,
                                migratedAt: ISO8601DateFormatter().string(from: Date()),
                                sourcePreserved: true)
            let marker = try JSONEncoder.pretty.encode(report)
            try marker.write(to: staging.appendingPathComponent(markerName), options: .atomic)

            let parent = destination.deletingLastPathComponent()
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            guard !fileManager.fileExists(atPath: destination.path) else {
                throw MigrationError.destinationAlreadyExists(destination.path)
            }
            try fileManager.moveItem(at: staging, to: destination)
            return report
        } catch {
            try? fileManager.removeItem(at: staging)
            if error is MigrationError { throw error }
            throw MigrationError.copyFailed(error.localizedDescription)
        }
    }

    /// Rewrites only absolute paths under a known legacy product root in an
    /// existing destination's settings file. This is safe to call on every
    /// launch: unrelated strings, keys, and already-normalized paths are
    /// preserved byte-for-byte in value and the second call is a no-op.
    @discardableResult
    public static func normalizeExistingSettingsPaths(
        destination: URL,
        legacyProductRoots: [URL],
        destinationProductRoot: URL,
        fileManager: FileManager = .default
    ) throws -> Bool {
        let settings = destination.standardizedFileURL.appendingPathComponent("settings.json")
        guard fileManager.fileExists(atPath: settings.path) else { return false }
        let data = try Data(contentsOf: settings)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }

        let destinationRoot = destinationProductRoot.standardizedFileURL
        var replacements = legacyProductRoots.map(\.standardizedFileURL)
        replacements.append(destinationRoot.deletingLastPathComponent()
            .appendingPathComponent("Foresight Meeting", isDirectory: true))
        replacements.append(destinationRoot.deletingLastPathComponent()
            .appendingPathComponent("Foresight-Qwen-006", isDirectory: true))

        // Longest first prevents a shorter overlapping root from winning.
        replacements = Array(Set(replacements.map(\.path))).sorted { $0.count > $1.count }.map {
            URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
        }

        var changed = false
        func rewrite(_ value: Any) -> Any {
            if let string = value as? String {
                for old in replacements {
                    guard string == old.path || string.hasPrefix(old.path + "/") else { continue }
                    changed = true
                    return destinationRoot.path + string.dropFirst(old.path.count)
                }
                return string
            }
            if let array = value as? [Any] { return array.map(rewrite) }
            if let dictionary = value as? [String: Any] {
                return dictionary.mapValues(rewrite)
            }
            return value
        }
        object = rewrite(object) as? [String: Any] ?? object
        guard changed else { return false }
        let rewritten = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try rewritten.write(to: settings, options: .atomic)
        return true
    }

    private static func removeLockFiles(in root: URL, fileManager: FileManager) throws -> [String] {
        guard let enumerator = fileManager.enumerator(at: root,
                                                      includingPropertiesForKeys: [.isRegularFileKey],
                                                      options: [],
                                                      errorHandler: nil) else { return [] }
        var removed: [String] = []
        for case let url as URL in enumerator where url.lastPathComponent.hasSuffix(".lock") {
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            try fileManager.removeItem(at: url)
            removed.append(relative)
        }
        return removed.sorted()
    }

    private static func regularFiles(in root: URL, fileManager: FileManager) throws -> Int {
        guard let enumerator = fileManager.enumerator(at: root,
                                                      includingPropertiesForKeys: [.isRegularFileKey],
                                                      options: [],
                                                      errorHandler: nil) else { return 0 }
        var count = 0
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { count += 1 }
        }
        return count
    }

    /// The old settings file contains absolute model/runtime paths. Rewrite only path-like string values;
    /// keys and all other settings remain intact.
    private static func rewriteLegacyPaths(in root: URL,
                                           legacyRoots: [URL],
                                           destinationProductRoot: URL?) throws {
        let settings = root.appendingPathComponent("settings.json")
        guard FileManager.default.fileExists(atPath: settings.path) else { return }
        let data = try Data(contentsOf: settings)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        var replacements = legacyRoots.map(\.standardizedFileURL)
        if let destinationProductRoot {
            let parent = destinationProductRoot.standardizedFileURL.deletingLastPathComponent()
            replacements.append(parent.appendingPathComponent("Foresight Meeting", isDirectory: true))
            replacements.append(parent.appendingPathComponent("Foresight-Qwen-006", isDirectory: true))
        }

        func rewrite(_ value: Any) -> Any {
            if let string = value as? String {
                for old in replacements where string == old.path || string.hasPrefix(old.path + "/") {
                    if let destinationProductRoot,
                       old.path.hasSuffix("/Foresight Meeting") || old.path.hasSuffix("/Foresight-Qwen-006") {
                        return destinationProductRoot.standardizedFileURL.path + string.dropFirst(old.path.count)
                    }
                    return string
                }
                return string
            }
            if let array = value as? [Any] { return array.map(rewrite) }
            if let dictionary = value as? [String: Any] {
                return dictionary.mapValues(rewrite)
            }
            return value
        }

        object = rewrite(object) as? [String: Any] ?? object
        let rewritten = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try rewritten.write(to: settings, options: .atomic)
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
