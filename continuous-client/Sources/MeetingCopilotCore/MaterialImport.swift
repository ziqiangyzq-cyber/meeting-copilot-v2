import Foundation
import CryptoKit

public enum MaterialImport {
    // Explicit user-selected UTF-8 files only. Cap is an app input guard, not an engine threshold.
    public static func read(_ url: URL, maxBytes: Int) throws -> LocalMaterial {
        guard ["txt", "md"].contains(url.pathExtension.lowercased()), maxBytes > 0 else { throw CocoaError(.fileReadUnsupportedScheme) }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= maxBytes else { throw CocoaError(.fileReadTooLarge) }
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= maxBytes, let text = String(data: bytes, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        return LocalMaterial(fileName: url.lastPathComponent, text: text, sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }
}
