import SwiftUI
import AppKit
import ClientRuntime

struct FileBatchView: View {
    @ObservedObject var batch: FileBatchModel
    let enabled: Bool
    let start: ([URL]) -> Void
    let cancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("音频文件批处理 · 分段识别").font(.headline)
            Text("完整音频段返回最终原文；无原生 partial 或词级时间。每个文件写回确认后才计为完成。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("选择音频文件（可多选）…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true; panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = true; panel.title = "导入本地音频文件进行分段识别"
                    if panel.runModal() == .OK { start(panel.urls) }
                }.disabled(!enabled || batch.busy)
                Button("取消批处理") { cancel() }.disabled(!batch.busy)
            }
            Text(status).font(.caption).textSelection(.enabled)
            ForEach(Array(batch.files.enumerated()), id: \.offset) { _, url in
                Text(url.lastPathComponent).font(.caption).textSelection(.enabled)
            }
        }
    }
    private var status: String {
        switch batch.state {
        case .idle: return "请选择文件；本机模式需加载 Qwen，网络模式需保存配置并允许发送内容。"
        case .running(let completed, let total): return "正在识别 · 已写回 \(completed)/\(total) 个文件"
        case .completed(let count): return "完成 · \(count) 个文件已写回"
        case .cancelled(let saved): return "已取消 · 保留此前已写回 \(saved) 个文件，后续结果不采纳"
        case .failed(let reason, let saved): return "批处理失败：\(reason) · 已写回 \(saved) 个文件保留"
        }
    }
}
