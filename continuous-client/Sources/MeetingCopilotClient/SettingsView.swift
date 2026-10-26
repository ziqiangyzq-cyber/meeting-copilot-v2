import SwiftUI
import AppKit
import AppleOfflineSpeech
import LocalASRProviders
import ClientRuntime

// Product settings window. Two visually separated sections that must never impersonate each other:
//   A · 前端语音（本地 ASR）  — which on-device recogniser, its real availability, a short-audio test.
//   B · 后端 API（纪要/问答/检索增强） — baseURL/modelID and a *reference* to a key.
// Unified testing applies both drafts, loads the local engine and sends only a fixed API probe.
struct SettingsView: View {
    @ObservedObject var asr: ASRSettingsModel
    @ObservedObject var backend: BackendAPISettingsModel
    let captureActive: Bool
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 0) {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("应用设置").font(.system(size: 24, weight: .semibold))
                Text("语音转写和文字翻译可分别使用本机或网络服务，会议纪要独立配置。").font(.subheadline).foregroundStyle(.secondary)
                asrSection.padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(MeetingCopilotTheme.card, in: RoundedRectangle(cornerRadius: 12))
                translationSection.padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(MeetingCopilotTheme.card, in: RoundedRectangle(cornerRadius: 12))
                backendSection.padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(MeetingCopilotTheme.card, in: RoundedRectangle(cornerRadius: 12))
            }.padding(20)
        }
        .disabled(backend.unifiedTesting || captureActive || asr.loading)
        Divider()
        VStack(alignment: .leading, spacing: 10) {
            Text(backend.needsRetest(asr: asr) ? "配置已改变，请重新测试。" : backend.unifiedTestMessage)
                .foregroundStyle(backend.canSaveTogether(asr: asr) ? Color.green : Color.primary)
                .textSelection(.enabled)
            Text("测试所选模式：本机转写加载模型；网络转写发送 1 秒静音，网络翻译 / 纪要发送固定短句，可能消耗少量额度。测试不发送会议内容，不评估识别准确率。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if backend.unifiedTesting {
                    ProgressView().controlSize(.small)
                    Button("取消测试") { backend.cancelUnifiedTest(asr: asr) }
                } else {
                    Button("测试配置") { backend.startUnifiedTest(asr: asr) }
                        .disabled(captureActive || asr.loading)
                }
                Spacer()
                Button("保存并关闭") {
                    if backend.saveTogether(asr: asr) { dismissWindow(id: "settings") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!backend.canSaveTogether(asr: asr))
            }
        }.padding(20)
        }
        .frame(minWidth: 620, minHeight: 560)
        .background(MeetingCopilotTheme.background)
        .tint(MeetingCopilotTheme.accent)
        .preferredColorScheme(.light)
        .toolbarBackground(MeetingCopilotTheme.background, for: .windowToolbar)
        .onAppear {
            backend.syncDraftFromPersisted()
            asr.services.syncDraft()
            asr.pathDraft = asr.requested.modelPath ?? ASRSelection.freshInstall.modelPath ?? ""
            asr.runtimeDraft = asr.requested.runtimePath ?? ASRSelection.freshInstall.runtimePath ?? ""
            asr.contextDraft = asr.requested.context ?? ""
            asr.captureActive = captureActive
        }
        .onChange(of: captureActive) { _, new in asr.captureActive = new }
        .onDisappear { backend.cancelUnifiedTest(asr: asr) }
    }

    // MARK: - A. local ASR

    private var asrSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("语音识别 · 设置 A").font(.headline)
            locationPicker(asrService: true)
            if asr.services.draft.asr.location == .network {
                Picker("识别语言提示", selection: Binding(get: { asr.services.draft.asr.recognitionLanguage ?? "auto" }, set: { asr.services.draft.asr.recognitionLanguage = $0 })) {
                    Text("自动识别（中英混合推荐）").tag("auto")
                    Text("中文").tag("zh")
                    Text("English").tag("en")
                }.frame(width: 330)
                networkFields(asrService: true)
                Text("服务需支持 POST /audio/transcriptions，接收 WAV 并返回 JSON text。按约 8 秒音频段上传；支持电脑声音、麦克风或两路。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
            Text("填写模型与运行环境路径后，在页面底部统一测试和保存。")
                .font(.caption).foregroundStyle(.secondary)

            Picker("引擎", selection: Binding(
                get: { asr.requested.providerID },
                set: { newID in
                    let d = asr.catalog.first { $0.id.rawValue == newID }
                    // Un-implemented providers are refused here, not merely greyed: no silent Apple substitute.
                    _ = asr.request(providerID: newID, locale: asr.requested.locale,
                                    modelPath: d?.pathKind == .directory ? (asr.pathDraft.isEmpty ? nil : asr.pathDraft) : nil)
                })) {
                ForEach(asr.catalog, id: \.id) { d in
                    Text(d.displayName + (d.implemented ? "" : " · 未支持")).tag(d.id.rawValue)
                }
            }.disabled(captureActive)

            if let refusal = asr.lastRefusal {
                Text(refusal.text).font(.caption).foregroundStyle(.red)
            }

            Picker("识别语言", selection: Binding(
                get: { asr.requested.locale },
                set: { _ = asr.request(providerID: asr.requested.providerID, locale: $0,
                                       modelPath: asr.requested.modelPath) })) {
                Text("中文 zh-CN").tag(OfflineSpeechLocale.simplifiedChinese.rawValue)
                Text("English en-US").tag(OfflineSpeechLocale.englishUS.rawValue)
            }.frame(width: 260).disabled(captureActive)

            if asr.descriptor.pathKind == .directory {
                Text("Qwen 需要 macOS 26 或更高，每次处理一段完整语音。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("本地模型目录", text: $asr.pathDraft).textFieldStyle(.roundedBorder)
                    Button("选择模型目录…") { chooseDirectory(runtime: false) }
                }.disabled(captureActive)
                HStack {
                    TextField("本地运行环境目录", text: $asr.runtimeDraft).textFieldStyle(.roundedBorder)
                    Button("选择运行环境…") { chooseDirectory(runtime: true) }
                }.disabled(captureActive)
                TextField("可选：项目名称、专业术语等识别提示", text: $asr.contextDraft, axis: .vertical)
                    .lineLimit(2...4).textFieldStyle(.roundedBorder).disabled(captureActive)
            } else {
                Text("模型由系统管理，无需填写路径。").font(.caption).foregroundStyle(.secondary)
            }

            if captureActive { Text("录制中不可切换；请先停止。").font(.caption).foregroundStyle(.orange) }

            Group {
                Text("状态：\(statusText)").font(.callout)
                Text("已保存：\(asr.persisted.providerID) · \(asr.persisted.locale)")
                    .font(.caption).foregroundStyle(.secondary)

            }.textSelection(.enabled)

            DisclosureGroup("高级与诊断") {
                Text("当前实际引擎：\(asr.activeEngineDescription ?? "尚未加载")").font(.caption).textSelection(.enabled)
                Button("卸载引擎") { asr.unload() }.disabled(captureActive)
                Text("混语实测记录：\(asr.descriptor.mixedLanguageEvidence)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            }
        }
    }

    private func applyDrafts() {
        _ = asr.request(providerID: asr.requested.providerID, locale: asr.requested.locale,
                        modelPath: asr.pathDraft.isEmpty ? nil : asr.pathDraft,
                        runtimePath: asr.runtimeDraft, context: asr.contextDraft)
    }

    private func chooseDirectory(runtime: Bool) {
        guard !captureActive else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.title = runtime ? "选择既有隔离 runtime 目录" : "选择既有 Qwen 模型目录"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if runtime { asr.runtimeDraft = url.path } else { asr.pathDraft = url.path }
        applyDrafts()
    }

    private var statusText: String {
        switch asr.status {
        case .unsupported(let r): return "未支持 · \(r)"
        case .invalidConfiguration(let r): return "配置无效 · \(r)"
        case .permissionRequired(let r): return "缺少系统语音授权 · \(r)"
        case .unavailable(let r): return "本机不可用 · \(r)"
        case .loading: return "正在校验并加载权重 · 等待真实后端确认"
        case .readyToPrepare: return "就绪（可加载）"
        case .prepared: return "已加载，可以开始识别"
        case .failed(let r): return "加载失败 · \(r)"
        }
    }

    private func configBinding<Value>(_ key: WritableKeyPath<NetworkModelConfiguration, Value>, asrService: Bool) -> Binding<Value> {
        Binding(get: { (asrService ? asr.services.draft.asr : asr.services.draft.translation)[keyPath: key] },
                set: { value in
                    if asrService { asr.services.draft.asr[keyPath: key] = value; if asr.services.draft.asr.recognitionLanguage == nil { asr.services.draft.asr.recognitionLanguage = "auto" } }
                    else { asr.services.draft.translation[keyPath: key] = value }
                })
    }
    private func locationPicker(asrService: Bool) -> some View {
        Picker("运行位置", selection: configBinding(\.location, asrService: asrService)) {
            Text("本机模型").tag(ModelLocation.local)
            Text("网络 API（局域网或在线）").tag(ModelLocation.network)
        }.pickerStyle(.segmented)
    }
    private func networkFields(asrService: Bool) -> some View {
        let config = asrService ? asr.services.draft.asr : asr.services.draft.translation
        return VStack(alignment: .leading, spacing: 8) {
            TextField("服务根地址，例如 http://192.168.1.10:8000/v1", text: configBinding(\.baseURL, asrService: asrService)).textFieldStyle(.roundedBorder)
            TextField("服务器上的模型名称", text: configBinding(\.modelID, asrService: asrService)).textFieldStyle(.roundedBorder)
            Toggle("服务器无需 API Key", isOn: configBinding(\.noAuthentication, asrService: asrService))
            if !config.noAuthentication {
                SecureField("API Key（留空保留已保存密钥）", text: Binding(get: { asrService ? asr.services.asrSecret : asr.services.translationSecret }, set: { if asrService { asr.services.asrSecret = $0 } else { asr.services.translationSecret = $0 } })).textFieldStyle(.roundedBorder)
                Text(config.secretReference.isEmpty ? "密钥将保存在 macOS 钥匙串。" : "已有钥匙串密钥；留空保留，填写后替换。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("填写兼容接口的根地址（通常含 /v1），不要填写具体请求路径。公司服务器可用局域网 IP 或域名。HTTP 传输不加密；需要加密时使用 HTTPS。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var translationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("文字翻译 · 独立设置").font(.headline)
            locationPicker(asrService: false)
            if asr.services.draft.translation.location == .network {
                networkFields(asrService: false)
                Text("服务需支持 POST /chat/completions。只发送待翻译原文段；失败保留原文，不会自动切换其他服务。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("使用 macOS 本机翻译及已安装语言资源，无需 Key。此处本机翻译使用系统模型；Qwen 模型目录用于语音识别。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(asr.services.message).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - B. backend API

    private var backendSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("会议纪要与问答 · 设置 B").font(.headline)
            Text("用于生成纪要、行动项和问答。API 密钥保存在 macOS 钥匙串。")
                .font(.caption).foregroundStyle(.secondary)

            TextField("服务地址（baseURL）", text: $backend.draft.baseURL).textFieldStyle(.roundedBorder)
            TextField("模型名称（modelID）", text: $backend.draft.modelID).textFieldStyle(.roundedBorder)
            SecureField("API 密钥（直接粘贴）", text: $backend.secretInput)
                .textFieldStyle(.roundedBorder)
            Text(backend.credentialHint).font(.caption).foregroundStyle(.secondary)

            Text("状态：\(backend.needsRetest(asr: asr) ? "配置已修改，请重新测试" : backend.status.text)").font(.callout)
            Text(BackendAPISettingsModel.verificationNote).font(.caption).foregroundStyle(.secondary)
            Text("已保存：\(backend.persisted.baseURL.isEmpty ? "（未填写）" : backend.persisted.baseURL) · \(backend.persisted.modelID.isEmpty ? "（未填写）" : backend.persisted.modelID)")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("接口说明") {
                Text("支持 Chat Completions 兼容接口；Responses 暂未支持。").font(.caption)
                Text("生成前会确认目标接口与所选会话内容，配置测试只发送固定的短请求。").font(.caption)
            }.font(.caption)
        }
    }
}
