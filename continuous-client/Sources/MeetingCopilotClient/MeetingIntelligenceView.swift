import SwiftUI
import AppKit
import ClientRuntime
import MeetingCopilotCore
import APIIntelligence

struct MeetingIntelligenceView: View {
    @ObservedObject var client: ClientModel
    @ObservedObject var backend: BackendAPISettingsModel
    @ObservedObject var intelligence: MeetingIntelligenceModel
    @State private var includeMaterials = false
    @State private var question = ""
    @State private var pendingKind: IntelligenceRequestKind?
    @State private var pendingSnapshot: MeetingSourceSnapshot?
    @State private var pendingBackend: BackendAPISettings?
    @State private var pendingQuestion = ""
    @State private var showingConsent = false
    @State private var exportMessage = ""
    @State private var expandedDrafts: [String: Bool] = [:]
    @Environment(\.openWindow) private var openWindow

    private var snapshot: MeetingSourceSnapshot? {
        client.selected.map { MeetingSourceSnapshot(session: $0, includeMaterials: includeMaterials) }
    }
    private var records: [MeetingDraft] {
        guard let id = client.selected?.id else { return [] }
        var records = intelligence.records(sessionID: id)
        if let unsaved = intelligence.unsavedDraft, unsaved.job.binding.sessionID == id { records.insert(unsaved, at: 0) }
        return records
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("会议纪要与问答").font(.system(size: 18, weight: .semibold))
            Text("根据当前会议生成中文草稿，保留原文与随记。发送前会确认目标服务和内容范围。")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("同时发送当前会话导入的 TXT/MD 资料", isOn: $includeMaterials).disabled(intelligence.running)
            HStack {
                Button { request(.minutes) } label: { Label("生成会议纪要", systemImage: "doc.text") }.buttonStyle(.borderedProminent)
                Button { request(.actionItems) } label: { Label("提取行动项", systemImage: "checklist") }
                Button("纪要模型设置…") { openWindow(id: "settings") }
                if intelligence.running { ProgressView().controlSize(.small); Button("取消生成") { intelligence.cancel() } }
            }
            .disabled(client.selected == nil || client.captureActive || client.error != nil)
            HStack {
                TextField("向会议记录提问，例如：确定了哪些截止日期？", text: $question).textFieldStyle(.roundedBorder)
                Button("提问") { request(.questionAnswer) }
                    .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || intelligence.running || client.captureActive || client.error != nil)
            }
            Text(client.captureActive ? "请先停止采集并等待保存，再生成纪要。" : intelligence.status)
                .font(.caption).foregroundStyle(.secondary)
            if let error = intelligence.error { Text(error).font(.caption).foregroundStyle(.red) }
            if intelligence.unsavedDraft != nil { Button("重试保存草稿") { intelligence.retrySave() } }
            if records.isEmpty && !intelligence.running {
                ContentUnavailableView("还没有会议草稿", systemImage: "doc.text",
                    description: Text("结束采集后，可以生成纪要、提取行动项或向记录提问。"))
                    .frame(minHeight: 180)
            }
            ForEach(records) { draft in
                DisclosureGroup(isExpanded: Binding(
                    get: { expandedDrafts[draft.id] ?? (records.first?.id == draft.id) },
                    set: { expandedDrafts[draft.id] = $0 })) {
                    if let question = draft.job.question { Text("问题：\(question)").font(.callout) }
                    Text(draft.content.draft).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(Array(draft.content.actionItems.enumerated()), id: \.offset) { _, action in
                        Text("• \(action.text)\n负责人：\(action.owner ?? "未明确") · 期限：\(action.dueDate ?? "未明确") · 来源 \(action.citationIDs.joined(separator: ", "))")
                            .textSelection(.enabled)
                    }
                    HStack {
                        Button("复制草稿与来源") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(draft.markdown, forType: .string) }
                        Button("导出草稿 Markdown…") { export(draft) }
                    }
                    DisclosureGroup("来源快照 · \(draft.job.sources.count) 条") {
                        ForEach(draft.job.sources, id: \.citationID) { source in
                            Text("[\(source.citationID)] \(source.text)").font(.caption).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } label: {
                    VStack(alignment: .leading) {
                        Text("\(kindName(draft.content.kind)) · \(draft.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        Text(draft.id == intelligence.unsavedDraft?.id ? "未保存，请复制或导出" :
                            (draft.sourceFingerprint == snapshot?.fingerprint ? "AI 草稿 · 来源与当前记录一致" : "基于旧版本记录 · 可查看来源或重新生成"))
                            .font(.caption).foregroundStyle(draft.id == intelligence.unsavedDraft?.id ? Color.red : Color.secondary)
                    }
                }
                .padding(10).background(MeetingCopilotTheme.background, in: RoundedRectangle(cornerRadius: 8))
            }
            if !exportMessage.isEmpty { Text(exportMessage).font(.caption) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { intelligence.contextChanged(snapshot) }
        .onDisappear { intelligence.contextChanged(nil) }
        .onChange(of: snapshot) { _, value in
            intelligence.contextChanged(value)
            if pendingSnapshot != value { showingConsent = false; pendingKind = nil; pendingSnapshot = nil }
        }
        .confirmationDialog("发送当前会话内容并生成？", isPresented: $showingConsent, titleVisibility: .visible) {
            Button("发送并生成") {
                guard let kind = pendingKind, let pendingSnapshot, pendingSnapshot == snapshot else { return }
                guard pendingBackend == backend.persisted else {
                    intelligence.reportConfigurationError(); pendingKind = nil; self.pendingSnapshot = nil; return
                }
                do {
                    let configuration = try backend.apiConfiguration()
                    intelligence.start(snapshot: pendingSnapshot, kind: kind, question: pendingQuestion, configuration: configuration)
                } catch { intelligence.reportConfigurationError() }
                pendingKind = nil; self.pendingSnapshot = nil
            }
            Button("取消", role: .cancel) { pendingKind = nil; pendingSnapshot = nil }
        } message: {
            Text("将向 \(pendingBackend?.baseURL ?? "")（模型 \(pendingBackend?.modelID ?? "")）发送当前会话的已定稿原文、随记\(includeMaterials ? "和导入资料" : "")，不发送音频、其他会话或密钥文件。可能产生 API 费用。")
        }
    }
    private func request(_ kind: IntelligenceRequestKind) {
        guard !intelligence.running, let snapshot else { return }
        do {
            let config = try backend.apiConfiguration()
            guard intelligence.preflight(snapshot: snapshot, kind: kind, question: question, configuration: config) else { return }
        }
        catch { intelligence.reportConfigurationError(); return }
        pendingKind = kind; pendingSnapshot = snapshot; pendingBackend = backend.persisted
        pendingQuestion = question; showingConsent = true
    }
    private func kindName(_ kind: IntelligenceRequestKind) -> String {
        switch kind { case .minutes: return "会议纪要"; case .actionItems: return "行动项"; case .questionAnswer: return "会话问答" }
    }
    private func export(_ draft: MeetingDraft) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "会议草稿-\(draft.id.prefix(8)).md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try draft.markdown.write(to: url, atomically: true, encoding: .utf8); exportMessage = "草稿已导出。" }
        catch { exportMessage = "导出失败，请换一个可写位置。" }
    }
}
