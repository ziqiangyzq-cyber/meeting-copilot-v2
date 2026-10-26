import SwiftUI
import AppKit
import MeetingCopilotCore
import ClientRuntime

private enum WorkspaceSection: String, CaseIterable {
    case transcript = "转写与译文", minutes = "会议纪要", materials = "资料"
    var icon: String {
        switch self {
        case .transcript: "text.bubble"
        case .minutes: "doc.text"
        case .materials: "paperclip"
        }
    }
}

struct ClientView: View {
    @ObservedObject var model: ClientModel
    @ObservedObject var asrSettings: ASRSettingsModel
    @ObservedObject var backendSettings: BackendAPISettingsModel
    @ObservedObject var intelligence: MeetingIntelligenceModel
    @Environment(\.openWindow) private var openWindow
    @State private var section: WorkspaceSection = .transcript
    @State private var showNotesManagement = false
    @State private var showDeletedAudit = false
    @State private var deletionTarget: String?
    @State private var followLatest = true

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    pageHeader
                    LegacyMigrationVisibilityView(model: model)
                    captureArea
                    if let unsaved = model.unsavedCaptureText {
                        Label("未保存的转写，请复制保留：\(unsaved)", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red).textSelection(.enabled)
                    }
                    if let error = model.error {
                        HStack {
                            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled)
                            if model.loaded { Button("重试保存") { model.retry() } }
                        }.meetingCopilotCard()
                    }
                    if let session = model.selected {
                        workspace(session)
                        notes(session).meetingCopilotCard()
                        HStack {
                            Label(model.saved, systemImage: model.error == nil ? "checkmark.circle" : "exclamationmark.circle")
                            Spacer()
                            Text(model.exportStatus)
                            Text("记录保存在本机")
                        }.font(.caption).foregroundStyle(.secondary)
                    } else {
                        ContentUnavailableView("开始一场新的会议", systemImage: "waveform",
                            description: Text("新建会议后，选择声音来源并点击开始。"))
                            .frame(minHeight: 280).meetingCopilotCard()
                    }
                }.padding(24).frame(maxWidth: 1400)
                    .frame(maxWidth: .infinity)
            }.background(MeetingCopilotTheme.background)
        }
        .frame(minWidth: 1050, minHeight: 720)
        .tint(MeetingCopilotTheme.accent)
        .preferredColorScheme(.light)
        .toolbarBackground(MeetingCopilotTheme.background, for: .windowToolbar)
        .onChange(of: model.translateFinal) { _, enabled in
            if enabled { model.translateMissingCurrentSegments() }
        }
        .onChange(of: model.targetLanguage) { _, _ in
            if model.translateFinal { model.translateMissingCurrentSegments() }
        }
        .onChange(of: model.selection) { _, _ in
            section = .transcript
            if model.translateFinal { model.translateMissingCurrentSegments() }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "waveform").font(.title2).foregroundStyle(MeetingCopilotTheme.accent)
                Text("Meeting Copilot").font(.system(size: 17, weight: .semibold))
            }.padding(.top, 6)
            Button { model.add(demo: false) } label: {
                Label("新建会议", systemImage: "plus").frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(!model.loaded || model.error != nil || model.captureActive)
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索会议与记录", text: $model.keyword).textFieldStyle(.plain)
            }.padding(9).background(MeetingCopilotTheme.background, in: RoundedRectangle(cornerRadius: 8))
            Text("会议记录").font(.caption).foregroundStyle(.secondary)
            List(selection: $model.selection) {
                ForEach(model.visibleSessions) { session in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(session.title.isEmpty ? "未命名会议" : session.title).font(.system(size: 14, weight: .medium)).lineLimit(2)
                        Label(session.isDemo ? "演示" : "本地记录", systemImage: session.isDemo ? "flask" : "doc.text")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 7).tag(session.id)
                        .contextMenu {
                            Button(role: .destructive) { deletionTarget = session.id } label: {
                                Label("删除会议", systemImage: "trash")
                            }.disabled(model.captureActive || model.materialFolderBusy || model.error != nil)
                        }
                }
            }.listStyle(.sidebar).scrollContentBackground(.hidden).disabled(model.captureActive)
            if !model.deletionStatus.isEmpty { Text(model.deletionStatus.hasPrefix("已记录删除") ? "已删除会议，可在更多中查看记录" : model.deletionStatus).font(.caption).foregroundStyle(.secondary) }
            Menu {
                if !model.deletedSessions.isEmpty {
                    Button("查看已删除记录") { showDeletedAudit = true }
                }
            } label: { Label("更多", systemImage: "ellipsis.circle") }
                .menuStyle(.borderlessButton).disabled(model.captureActive || !model.loaded || model.error != nil)
        }.padding(18).background(.white)
            .alert("删除这场会议？", isPresented: Binding(get: { deletionTarget != nil }, set: { if !$0 { deletionTarget = nil } })) {
                Button("取消", role: .cancel) { deletionTarget = nil }
                Button("删除", role: .destructive) {
                    if let id = deletionTarget { model.deleteSession(id) }
                    deletionTarget = nil
                }
            } message: {
                Text("将从会议列表移除，原文与随记保留在已删除记录中。")
            }
            .sheet(isPresented: $showDeletedAudit) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("已删除记录").font(.title2)
                    ScrollView { Text(model.deletedAuditText()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    Button("关闭") { showDeletedAudit = false }
                }.padding(24).frame(width: 680, height: 420)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
    }

    private var pageHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                if let session = model.selected {
                    TextField("会议标题", text: Binding(
                        get: { model.archive.sessions.first { $0.id == session.id }?.title ?? "" },
                        set: { model.title($0, id: session.id) }))
                        .font(.system(size: 24, weight: .semibold)).textFieldStyle(.plain)
                    Text(session.isDemo ? "演示内容，原文与译文均为自拟数据" : "记录双方讲话，整理会议要点")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Text("会议工作区").font(.system(size: 24, weight: .semibold))
                    Text("转写、翻译与会议纪要").foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button { openWindow(id: "hud") } label: { Label("随行字幕", systemImage: "captions.bubble") }
            Button { openWindow(id: "settings") } label: { Label("设置", systemImage: "slider.horizontal.3") }
            if model.selected != nil {
                Menu {
                    Button("导出 Markdown") { model.exportSelected(.markdown) }
                    Button("导出 JSON") { model.exportSelected(.json) }
                } label: { Label("导出", systemImage: "square.and.arrow.up") }
                    .fixedSize()
            }
        }.controlSize(.large)
    }

    private var captureArea: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("声音来源").font(.system(size: 15, weight: .semibold))
                Spacer()
                if model.captureActive {
                    Label(model.captureStopping ? "正在保存" : "正在采集", systemImage: "record.circle")
                        .foregroundStyle(model.captureStopping ? MeetingCopilotTheme.accent : .green)
                } else {
                    Label(!asrSettings.readyForCapture ? "引擎未加载" : (asrSettings.services.usesNetworkASR ? "网络转写已配置" : "可以开始"),
                        systemImage: !asrSettings.readyForCapture ? "circle" : "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
            }.font(.caption)
            HStack(spacing: 10) {
                sourceChoice("microphone", title: "仅麦克风", detail: "现场讲话 / 系统输入设备", icon: "mic")
                sourceChoice("system", title: "仅电脑声音", detail: "会议对方 / 视频音频", icon: "speaker.wave.2")
                sourceChoice("dual", title: "电脑声音＋麦克风", detail: "同时记录对方和自己", icon: "waveform")
            }.disabled(model.captureActive)
            HStack(spacing: 14) {
                if model.captureActive {
                    Button { model.stopCapture() } label: { Label("停止并保存", systemImage: "stop.fill") }
                        .buttonStyle(.borderedProminent).disabled(model.captureStopping)
                    Button("取消采集") { model.cancelCapture() }.disabled(model.captureStopping)
                } else {
                    Button { Task { await model.startSelectedAudio() } } label: { Label("开始", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent)
                        .disabled(!asrSettings.readyForCapture || (asrSettings.services.usesNetworkASR && !asrSettings.services.contentSendingEnabled) || model.selection == nil || !model.loaded || model.error != nil)
                }
                Toggle("自动翻译为\(model.translationTargetName)", isOn: $model.translateFinal)
                    .toggleStyle(.switch).controlSize(.small)
                Spacer()
                if model.audioInput == "dual" { Label("建议戴耳机", systemImage: "headphones").font(.caption).foregroundStyle(.secondary) }
            }.controlSize(.large)
            if model.audioInput != "microphone", !model.systemAudioPermissionGranted {
                HStack {
                    Label("电脑声音需要“仅系统录音”授权", systemImage: "lock")
                    Button("请求授权并检测") { model.requestSystemAudioPermission() }
                    Button("重新检测") { model.requestSystemAudioPermission() }
                    Button("系统权限设置") { model.openSystemAudioPrivacySettings() }
                }.font(.callout).disabled(model.captureActive)
            }
            if !asrSettings.readyForCapture && !model.captureActive {
                HStack {
                    Text("在设置中测试并加载语音引擎后即可开始。").font(.caption).foregroundStyle(.secondary)
                    Button("加载语音引擎…") { openWindow(id: "settings") }
                }
            }
            if asrSettings.services.usesNetworkASR || asrSettings.services.persisted.translation.location == .network {
                VStack(alignment: .leading, spacing: 5) {
                    if asrSettings.services.usesNetworkASR { Text("语音 → " + asrSettings.services.persisted.asr.baseURL + " · " + asrSettings.services.persisted.asr.modelID) }
                    if asrSettings.services.persisted.translation.location == .network { Text("翻译 → " + asrSettings.services.persisted.translation.baseURL + " · " + asrSettings.services.persisted.translation.modelID) }
                    Toggle("允许本次打开期间向以上服务发送采集声音 / 当前会话待译原文", isOn: Binding(get: { asrSettings.services.contentSendingEnabled }, set: { asrSettings.services.contentSendingEnabled = $0; if $0 && model.translateFinal { model.translateMissingCurrentSegments() } }))
                        .disabled(model.captureActive)
                    Text("网络服务可能计费；关闭后不再开始新请求，已发出的请求可能仍会完成。未允许时网络采集 / 翻译不会开始。")
                }.font(.caption).foregroundStyle(.secondary)
            }
            Text(friendlyCaptureStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            DisclosureGroup("高级设置与采集诊断") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("约每 8 秒显示一段原文，翻译随后出现；切换来源前请先停止并等待保存。").font(.caption).foregroundStyle(.secondary)
                    if model.audioInput != "microphone" {
                        Text("电脑声音使用 Core Audio 系统录音采集，不需要屏幕录制权限，也不会读取或保存屏幕画面。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("打开“仅系统录音”设置") { model.openSystemAudioPrivacySettings() }
                    }
                    if model.audioInput != "system" {
                        Text("麦克风使用 macOS 当前输入设备，可在系统声音设置中选择内置或耳机麦克风。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("麦克风设备设置…") { model.openSoundInputSettings() }
                    }
                    if model.audioInput == "dual" {
                        Text("两路分别保存；当前没有回声消除或自动去重，外放可能造成重复收音。").font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("识别语言", selection: Binding(
                        get: { asrSettings.requested.locale },
                        set: {
                            _ = asrSettings.request(providerID: asrSettings.requested.providerID, locale: $0, modelPath: asrSettings.requested.modelPath)
                            model.recognizerLocale = $0
                        })) {
                        Text("中文 zh-CN").tag("zh-CN"); Text("English en-US").tag("en-US")
                    }.frame(maxWidth: 300).disabled(model.captureActive)
                    if asrSettings.requested.providerID != "qwen3-asr" {
                        Toggle("长会议轮转（实验）", isOn: $model.rotatingEnabled).disabled(model.captureActive)
                    }
                    Text(model.captureStatus).font(.caption).textSelection(.enabled)
                    captureDiagnostics
                }.padding(.top, 10)
            }.font(.caption).foregroundStyle(.secondary)
        }.meetingCopilotCard()
    }

    private var friendlyCaptureStatus: String {
        let status = model.captureStatus
        if status.contains("已结束") && status.contains("保存确认") { return "本次采集已结束，原文已保存。翻译可能还需片刻。" }
        if model.captureStopping { return "正在处理最后一段并保存，请稍候。" }
        if status.contains("失败") || status.contains("未开始") || status.contains("不可用") || status.contains("尚未允许") || status.contains("取消") {
            return status
        }
        if model.captureActive { return "正在记录\(model.audioInputName)，原文按段显示，译文随后生成。" }
        return asrSettings.services.usesNetworkASR ? "网络语音转写：允许发送内容后，选择声音来源并点击开始。" : "选择声音来源后点击开始；本机语音识别不会把录音发送到网络。"
    }

    private func sourceChoice(_ value: String, title: String, detail: String, icon: String) -> some View {
        let selected = model.audioInput == value
        return Button { model.audioInput = value } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 19)).frame(width: 24)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.caption).foregroundStyle(selected ? MeetingCopilotTheme.accent : .secondary)
            }.foregroundStyle(selected ? MeetingCopilotTheme.accent : MeetingCopilotTheme.ink)
                .padding(12).frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                .background(selected ? MeetingCopilotTheme.selection : Color.white, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? MeetingCopilotTheme.accent.opacity(0.6) : MeetingCopilotTheme.line, lineWidth: 1))
        }.buttonStyle(.plain).accessibilityLabel(title).accessibilityValue(selected ? "已选择" : "未选择")
    }

    private func workspace(_ session: LocalSession) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 22) {
                ForEach(WorkspaceSection.allCases, id: \.self) { item in
                    Button { section = item } label: {
                        Label(item.rawValue, systemImage: item.icon)
                            .font(.system(size: 14, weight: section == item ? .semibold : .regular))
                            .foregroundStyle(section == item ? MeetingCopilotTheme.accent : .secondary)
                            .padding(.vertical, 10)
                            .overlay(alignment: .bottom) {
                                if section == item { Capsule().fill(MeetingCopilotTheme.accent).frame(height: 2) }
                            }
                    }.buttonStyle(.plain)
                }
                Spacer()
            }
            Divider()
            switch section {
            case .transcript:
                pairedTranscript(session)
                DisclosureGroup("导入音频或手动补充文字") {
                    VStack(alignment: .leading, spacing: 16) {
                        FileBatchView(batch: model.fileBatch,
                            enabled: (asrSettings.services.usesNetworkASR || asrSettings.loadedProvider?.providerID.rawValue == "qwen3-asr") && !model.captureActive && model.error == nil,
                            start: { model.importQwenFiles($0, settings: asrSettings) }, cancel: { model.cancelQwen() })
                        Divider()
                        manualText
                    }.padding(.top, 12)
                }.font(.caption)
            case .minutes:
                EmptyView()
            case .materials:
                materials(session).id(session.id).onAppear {
                    if model.selectedMaterialFolder != nil { model.refreshMaterialFolder(sessionID: session.id) }
                }
            }
            // Keep the request view mounted across tab changes so its source
            // observer and confirmation binding continue to reject stale jobs.
            MeetingIntelligenceView(client: model, backend: backendSettings, intelligence: intelligence)
                .frame(minHeight: section == .minutes ? 330 : 0, alignment: .top)
                .frame(height: section == .minutes ? nil : 0, alignment: .top)
                .clipped().opacity(section == .minutes ? 1 : 0)
                .accessibilityHidden(section != .minutes)
        }.meetingCopilotCard()
    }

    private var manualText: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.editingSegmentID == nil ? "补充原文" : "修订已录入原文").font(.headline)
                Button("新段") { model.editingSegmentID = nil; model.inputText = "" }
                Spacer()
                Picker("原文语言", selection: $model.sourceLanguage) { Text("英语").tag("en"); Text("中文").tag("zh-Hans") }.frame(width: 160)
                Picker("译为", selection: $model.targetLanguage) { Text("中文").tag("zh-Hans"); Text("英语").tag("en") }.frame(width: 140)
            }
            TextField("输入需要补充的原文", text: $model.inputText, axis: .vertical)
                .lineLimit(2...4).textFieldStyle(.roundedBorder)
            HStack {
                Button("保存原文") { model.submitText(translate: false) }
                Button("保存并翻译") { model.submitText(translate: true) }
                Text(model.translationStatus).font(.caption).foregroundStyle(.secondary)
            }.disabled(model.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.loaded)
        }
    }

    private func notes(_ session: LocalSession) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("随记", systemImage: "square.and.pencil").font(.headline)
                Spacer()
                Text("编辑后自动保存").font(.caption).foregroundStyle(.secondary)
            }
            QuickNoteView(model: model)
            TextEditor(text: Binding(
                get: { model.archive.sessions.first { $0.id == session.id }?.notes ?? "" },
                set: { model.notes($0, id: session.id) }))
                .font(.body).scrollContentBackground(.hidden).padding(10)
                .frame(height: 110).background(MeetingCopilotTheme.background, in: RoundedRectangle(cornerRadius: 10))
                .disabled(!model.loaded)
            DisclosureGroup("标签、编辑历史与会话管理", isExpanded: $showNotesManagement) {
                TextField("标签，用英文逗号分隔", text: Binding(
                    get: { model.archive.sessions.first { $0.id == session.id }?.tags.joined(separator: ",") ?? "" },
                    set: { model.tags($0, id: session.id) })).textFieldStyle(.roundedBorder)
                Text("保留 \(session.noteHistory.count) 次编辑版本").font(.caption)
                Button("删除此会话（保留审计记录）") { model.deleteSelected() }.disabled(model.captureActive)
                Text(model.deletionStatus.hasPrefix("已记录删除") ? "已删除会议，可在更多中查看记录" : model.deletionStatus).font(.caption)
                if !model.deletedSessions.isEmpty {
                    DisclosureGroup("已删除会话审计") { Text(model.deletedAuditText()).font(.caption).textSelection(.enabled) }
                }
            }.font(.caption)
        }
    }

    private func materials(_ session: LocalSession) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("本地参考资料").font(.headline)
                Spacer()
                Button { model.chooseMaterialFolder() } label: { Label("选择文件夹", systemImage: "folder.badge.plus") }
                    .disabled(model.materialFolderBusy)
                Button { model.importMaterial() } label: { Label("导入 TXT / MD", systemImage: "plus") }
                    .disabled(model.materialFolderBusy)
            }
            if let folder = model.selectedMaterialFolder {
                HStack {
                    Label(folder.path, systemImage: "folder").font(.caption).textSelection(.enabled).lineLimit(2)
                    Spacer()
                    Button(model.materialFolderBusy ? "正在扫描…" : "刷新文件夹") { model.refreshMaterialFolder() }
                        .disabled(model.materialFolderBusy)
                }
            }
            Text("自动递归扫描子文件夹，读取 TXT、MD、文字 PDF；复杂格式和扫描件跳过并说明。")
                .font(.caption).foregroundStyle(.secondary)
            if model.materialFolderReportSessionID == session.id, !model.materialFolderReport.isEmpty {
                DisclosureGroup("文件夹读取结果与跳过原因") {
                    ForEach(Array(model.materialFolderReport.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption).textSelection(.enabled)
                    }
                }
            }
            Text("导入资料保存在本机；生成纪要时可以选择是否发送。").font(.caption).foregroundStyle(.secondary)
            if session.materials.isEmpty {
                ContentUnavailableView("还没有参考资料", systemImage: "doc",
                    description: Text("可以添加会议议程、项目背景或术语说明。")).frame(minHeight: 240)
            }
            ForEach(session.materials) { material in
                DisclosureGroup(material.fileName.hasPrefix("[文件夹 ") ? (material.fileName.components(separatedBy: "] ").last ?? material.fileName) : material.fileName) {
                    Text(material.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Text("SHA256：\(material.sha256)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Text(model.materialStatus == "资料仅本地保存和展示，尚未接入模型上下文"
                ? "资料保存在本机；在会议纪要页勾选后才会发送。" : model.materialStatus).font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("资料处理诊断") {
                ForEach(model.materialChunkStatus(session: session.id), id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
            }.font(.caption)
        }
    }

    private func sourceName(_ kind: String) -> String {
        switch kind {
        case "mic": "麦克风"
        case "system": "电脑声音"
        case "audio_file": "音频文件"
        case "typed_text": "手动补充"
        default: "演示"
        }
    }
    private func pairedTranscript(_ session: LocalSession) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                HStack {
                    Text("原文").font(.headline)
                    Spacer()
                    Label("同步滚动", systemImage: "link").font(.caption).foregroundStyle(.secondary)
                    Toggle("跟随最新", isOn: $followLatest).toggleStyle(.checkbox).font(.caption)
                }.frame(maxWidth: .infinity)
                Text(model.translationTargetName).font(.headline).frame(maxWidth: .infinity, alignment: .leading)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if session.segments.isEmpty {
                            Text("等待会议开始，原文与译文会按同一段对齐显示。")
                                .foregroundStyle(.secondary).padding(.vertical, 30)
                        }
                        ForEach(session.chronologicalSegments) { segment in
                            HStack(alignment: .top, spacing: 24) {
                                transcriptCell(session, segment: segment, translated: false)
                                    .padding(.trailing, 12)
                                    .overlay(alignment: .trailing) { Rectangle().fill(MeetingCopilotTheme.line).frame(width: 1) }
                                transcriptCell(session, segment: segment, translated: true)
                            }.id(segment.id)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 8)
                }.frame(height: 290)
                    .accessibilityLabel("原文与译文同步滚动")
                    .onChange(of: session.segments.last?.id) { _, id in
                        if followLatest, let id { proxy.scrollTo(id, anchor: .bottom) }
                    }
                    .onChange(of: session.segments.last?.currentTranslations.count) { _, _ in
                        if followLatest, let id = session.segments.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                    }
            }
        }
    }
    private func transcriptCell(_ session: LocalSession, segment: LocalSegment, translated: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("第 \(session.segments.firstIndex(where: { $0.id == segment.id }).map { $0 + 1 } ?? 0) 段 · \(sourceName(segment.channelKind))").font(.system(size: 11, weight: .medium))
                .foregroundStyle(MeetingCopilotTheme.accent).padding(.horizontal, 7).padding(.vertical, 3)
                .background(MeetingCopilotTheme.selection, in: RoundedRectangle(cornerRadius: 5))
            if translated {
                let display = model.translationPresentation(sessionID: session.id, segment: segment)
                if let text = display.text { Text(text).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled) }
                Text(display.status).font(.caption).foregroundStyle(display.isFailure ? .red : .secondary)
                if display.isFailure {
                    Button("重试翻译") { model.translateSegment(sessionID: session.id, segmentID: segment.id) }
                }
            } else if let current = segment.current {
                Text(current.text).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled)
                HStack {
                    if segment.channelKind == "typed_text" {
                        Button("修订原文") { model.editSource(segment) }
                    }
                    if ["typed_text", "mic", "system", "audio_file"].contains(segment.channelKind) {
                        Button("重新翻译") { model.translateSegment(sessionID: session.id, segmentID: segment.id) }
                    }
                    Spacer()
                    DisclosureGroup("详情") {
                        Text("版本 \(current.revision) · \(current.status)").font(.caption)
                        Text("来源时间 [\(current.startNS), \(current.endNS)) ns（原始观测，尚未校准）").font(.caption).textSelection(.enabled)
                        Text("stream \(current.streamID ?? "")").font(.caption).textSelection(.enabled)
                        ForEach(Array((current.sourceSpans ?? []).enumerated()), id: \.offset) { _, span in
                            Text("native frames [\(span.frameStart), \(span.frameEnd)) · mapping r\(span.mappingRevision)").font(.caption)
                        }
                    }.font(.caption).frame(maxWidth: 180)
                }.buttonStyle(.link).font(.caption)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var captureDiagnostics: some View {
DisclosureGroup("来源与诊断") {
                    ForEach(model.selected?.captureAttempts ?? []) { attempt in
                        DisclosureGroup("采集 \(attempt.id) · \(attempt.lifecycle)") {
                            Text(attempt.failure ?? "无失败记录").font(.caption)
                            Text("来源：\(attempt.sourceKind ?? "历史未记录") · \(attempt.sourceURL ?? "无文件 URL")").font(.caption).textSelection(.enabled)
                            Text("引擎：\(attempt.engineVersion ?? "历史未记录") · 模型：\(attempt.modelVersion ?? "未公开或未记录")").font(.caption).textSelection(.enabled)
                            Text("设备启动 \(String(attempt.deviceStarted)) · 音频观测 \(String(attempt.audioObserved)) · ASR 观测 \(String(attempt.asrObserved))").font(.caption)
                            if let metadata = attempt.canonicalMetadata {
                                ForEach(metadata.blocks) { block in
                                    Text("epoch \(block.anchor.epochID) · \(block.anchor.provenance) · \(block.anchor.basis) · canonical global [\(block.globalFrameStart), \(block.globalFrameEnd)) frames · nominal [\(block.nominalStartNs), \(block.nominalEndNs)) ns（未校准）").font(.caption).textSelection(.enabled)
                                    Text("raw PTS \(block.rawObservation.presentationSeconds.map { String($0) } ?? "nil") · residual \(block.residualNs.map { String($0) } ?? "nil") ns · estimatedPPM \(block.estimatedPPM.map { String($0) } ?? "nil")（统计）").font(.caption)
                                }
                                ForEach(Array(metadata.associations.enumerated()), id: \.offset) { _, span in
                                    Text("actual task \(span.segmentID) · stream \(span.streamID) · canonical global [\(span.globalFrameStart), \(span.globalFrameEnd)) · \(span.basis)").font(.caption).textSelection(.enabled)
                                }
                                ForEach(metadata.settlements) { settled in
                                    Text("\(settled.disposition) · backendAccepted \(String(settled.backendAccepted)) · ownerReturned \(String(settled.ownerReturned)) · raw PTS \(settled.rawObservation.presentationSeconds.map { String($0) } ?? "nil") · \(settled.failure ?? "无失败")").font(.caption)
                                }
                                if let coverage = metadata.terminalCoverage {
                                    Text("终态覆盖：mapped \(coverage.mappedFrames) · consumed \(coverage.recognitionConsumedFrames) · uncertain \(coverage.uncertainAfterMappingFrames) · 守恒 \(String(coverage.canonicalAccountingValid))/\(String(coverage.queueAccountingValid))/\(String(coverage.ownerQueueAccountingValid)) · completion \(String(coverage.completionCoverageValid))").font(.caption)
                                }
                            } else { Text("canonical global timeline: unavailable（历史未提供）").font(.caption) }
                            ForEach(attempt.allTaskIdentities) { task in
                                Text("段 \(task.segmentID) · 流 \(task.streamID) · final \(String(task.finalObserved))").font(.caption).textSelection(.enabled)
                                ForEach(Array((task.sourceBlocks ?? []).enumerated()), id: \.offset) { _, block in
                                    Text("task-local source [\(block.frameStart), \(block.frameEnd)) frames · [\(block.startNS), \(block.endNS)) ns · 尚未校准").font(.caption).textSelection(.enabled)
                                }
                            }
                        }
                    }
                    }
    }
}
