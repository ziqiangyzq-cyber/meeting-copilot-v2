import AppKit
import Foundation
import MeetingCopilotCore

extension ClientModel {
    public func cancelMaterialFolderScan() {
        materialFolderToken = nil
        materialFolderTask?.cancel(); materialFolderTask = nil
        materialFolderBusy = false
    }
    public var selectedMaterialFolder: MaterialFolderConfiguration? {
        selection.flatMap { materialFolderConfigurations[$0] }
    }

    private var materialFolderConfigURL: URL {
        store.fileURL.deletingLastPathComponent().appendingPathComponent("material-folders.json")
    }

    private func saveFolderConfigurations() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let bytes = try encoder.encode(materialFolderConfigurations)
        try bytes.write(to: materialFolderConfigURL, options: .atomic)
    }

    public func chooseMaterialFolder() {
        guard loaded, error == nil, !materialFolderBusy, let id = selection else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.title = "选择资料文件夹（递归读取 TXT / MD / 文字 PDF，仅本地）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        configureMaterialFolder(url, sessionID: id)
    }

    public func configureMaterialFolder(_ url: URL, sessionID: String) {
        guard loaded, error == nil, !materialFolderBusy, incremental == nil,
              archive.activeSessions.contains(where: { $0.id == sessionID }) else {
            materialStatus = "当前无法连接资料文件夹；增量实验模式暂不支持替换文件夹快照"
            return
        }
        let previous = materialFolderConfigurations
        materialFolderConfigurations[sessionID] = MaterialFolderConfiguration(path: url.path,
            importedIDs: previous[sessionID]?.importedIDs ?? [])
        do { try saveFolderConfigurations() }
        catch {
            materialFolderConfigurations = previous
            materialStatus = "文件夹配置未保存：\(error.localizedDescription)"; return
        }
        refreshMaterialFolder(sessionID: sessionID)
    }

    public func refreshMaterialFolder(sessionID: String? = nil) {
        guard loaded, error == nil, !materialFolderBusy, incremental == nil,
              let id = sessionID ?? selection, let config = materialFolderConfigurations[id],
              archive.activeSessions.contains(where: { $0.id == id }) else { return }
        materialFolderBusy = true; materialFolderReport = []; materialFolderReportSessionID = id
        materialStatus = "正在递归读取资料文件夹，尚未发送给模型"
        let token = UUID(); materialFolderToken = token
        materialFolderTask = Task { [weak self] in
            let scanTask = Task.detached { try MaterialFolder.scan(URL(fileURLWithPath: config.path, isDirectory: true)) }
            do {
                let scan = try await withTaskCancellationHandler(operation: { try await scanTask.value },
                    onCancel: { scanTask.cancel() })
                guard let self, !Task.isCancelled, self.materialFolderToken == token else { return }
                defer { self.materialFolderBusy = false; self.materialFolderTask = nil }
                guard self.error == nil,
                      let index = self.archive.sessions.firstIndex(where: { $0.id == id && !$0.isDeleted }) else { return }
                let previous = self.archive
                let oldIDs = Set(config.importedIDs)
                let oldMaterials = self.archive.sessions[index].materials
                var next = scan.materials
                // Preserve a snapshot's identity/date when its content has not changed.
                for i in next.indices {
                    if let old = oldMaterials.first(where: { $0.fileName == next[i].fileName && $0.sha256 == next[i].sha256 }) {
                        next[i] = old
                    }
                }
                self.archive.sessions[index].materials.removeAll {
                    oldIDs.contains($0.id) || $0.fileName.hasPrefix(scan.prefix)
                }
                self.archive.sessions[index].materials.append(contentsOf: next)
                guard self.persist() else { self.archive = previous; self.materialStatus = "文件夹读取完成但未保存；原资料快照保留"; return }
                self.materialFolderConfigurations[id] = MaterialFolderConfiguration(path: config.path, importedIDs: next.map(\.id))
                self.materialFolderReport = scan.report
                do {
                    try self.saveFolderConfigurations()
                    self.materialStatus = "已读取并保存 \(next.count) 个文件 · 文件夹不会自动上传；生成前可选择发送"
                } catch {
                    self.materialStatus = "资料已保存，文件夹配置更新失败：\(error.localizedDescription)"
                }
            } catch {
                guard let self, self.materialFolderToken == token else { return }
                self.materialFolderBusy = false; self.materialFolderTask = nil
                self.materialStatus = "资料文件夹读取失败，原资料保留：\(error.localizedDescription)"
            }
        }
    }
}
