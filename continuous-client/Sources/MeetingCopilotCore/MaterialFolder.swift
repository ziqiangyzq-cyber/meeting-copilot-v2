import Foundation
import CryptoKit
import PDFKit

public struct MaterialFolderConfiguration: Codable, Equatable {
    public var path: String
    public var importedIDs: [String]
    public init(path: String, importedIDs: [String] = []) {
        self.path = path; self.importedIDs = importedIDs
    }
}

public struct MaterialFolderScan {
    public var materials: [LocalMaterial]
    public var report: [String]
    public var prefix: String
}

public enum MaterialFolder {
    public enum ReadFailure: Error, LocalizedError {
        case noReadableText, encryptedPDF, tooManyPages
        public var errorDescription: String? {
            switch self {
            case .noReadableText: return "没有可提取文字（可能是扫描件）；本版不做 OCR"
            case .encryptedPDF: return "加密 PDF，未读取"
            case .tooManyPages: return "PDF 超过 300 页，未读取"
            }
        }
    }
    public static func prefix(for url: URL) -> String {
        let hash = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8))
            .prefix(6).map { String(format: "%02x", $0) }.joined()
        return "[文件夹 \(hash)] "
    }

    public static func scan(_ root: URL, maxFiles: Int = 64, maxFileBytes: Int = 2 * 1024 * 1024,
                            maxTotalBytes: Int = 12 * 1024 * 1024) throws -> MaterialFolderScan {
        let root = root.standardizedFileURL
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              FileManager.default.isReadableFile(atPath: root.path) else { throw CocoaError(.fileReadNoPermission) }
        var report: [String] = []
        guard let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, error in report.append("跳过：\(url.lastPathComponent) · \(error.localizedDescription)"); return true })
        else { throw CocoaError(.fileReadUnknown) }
        var candidates: [URL] = []
        var visited = 0
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            visited += 1
            if visited > 5000 { report.append("达到 5000 个目录项上限，其余未扫描"); break }
            let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if v?.isSymbolicLink == true {
                enumerator.skipDescendants()
                report.append("跳过符号链接：\(url.lastPathComponent)")
                continue
            }
            guard v?.isRegularFile == true else { continue }
            guard ["txt", "md", "pdf"].contains(url.pathExtension.lowercased()) else {
                if report.count < 200 { report.append("跳过不支持格式：\(url.path.replacingOccurrences(of: root.path + "/", with: ""))") }
                continue
            }
            candidates.append(url)
        }
        let prefix = prefix(for: root)
        var materials: [LocalMaterial] = []
        var total = 0
        for url in candidates.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            let relative = String(url.path.dropFirst(root.path.count + 1))
            guard materials.count < maxFiles else { report.append("达到 \(maxFiles) 个可用文件上限，其余未导入"); break }
            do {
                var material = try read(url, maxBytes: maxFileBytes)
                let bytes = material.text.utf8.count
                guard total + bytes <= maxTotalBytes else { report.append("跳过：\(relative) · 累计文字超过 12 MiB"); continue }
                material.fileName = prefix + relative
                materials.append(material); total += bytes
                report.append("已读取：\(relative)")
            } catch {
                report.append("跳过：\(relative) · \(error.localizedDescription)")
            }
        }
        report.insert("递归扫描完成 · \(materials.count) 个可用文件 · \(total) 字节文字", at: 0)
        return MaterialFolderScan(materials: materials, report: report, prefix: prefix)
    }

    public static func read(_ url: URL, maxBytes: Int) throws -> LocalMaterial {
        if url.pathExtension.lowercased() != "pdf" { return try MaterialImport.read(url, maxBytes: maxBytes) }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= maxBytes,
              maxBytes > 0 else { throw CocoaError(.fileReadTooLarge) }
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= maxBytes, let pdf = PDFDocument(data: bytes) else { throw CocoaError(.fileReadCorruptFile) }
        guard !pdf.isEncrypted else { throw ReadFailure.encryptedPDF }
        guard pdf.pageCount <= 300 else { throw ReadFailure.tooManyPages }
        var pages: [String] = []
        var total = 0
        for index in 0..<pdf.pageCount {
            try Task.checkCancellation()
            let text = pdf.page(at: index)?.string ?? ""
            total += text.utf8.count
            guard total <= maxBytes else { throw CocoaError(.fileReadTooLarge) }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pages.append("第 \(index + 1) 页\n" + text)
            }
        }
        guard !pages.isEmpty else { throw ReadFailure.noReadableText }
        let text = pages.joined(separator: "\n\n")
        guard text.utf8.count <= maxBytes else { throw CocoaError(.fileReadTooLarge) }
        return LocalMaterial(fileName: url.lastPathComponent, text: text,
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }
}
