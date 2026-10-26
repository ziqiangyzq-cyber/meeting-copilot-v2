import Foundation
import AVFoundation
import AppleOfflineSpeech
import LocalASRProviders
import APIIntelligence
import Combine

// Client-side product settings. Two independent areas that must never impersonate each other:
//
//   A. Local ASR      — which on-device recogniser runs, its real availability, and a short-audio test.
//   B. Backend API    — baseURL/modelID plus a *reference* to a key; used for notes/Q&A/retrieval later.
//
// Hard rules encoded here (not just documented):
//  * requested / persisted / active are three separate values. `active` is only ever set by a real
//    successful load, never by a pick, a save, or a "the directory exists" check.
//  * a provider the registry does not implement is reported unsupported and can never become active;
//    Qwen is never silently replaced by Apple.
//  * switching is refused while a capture is active.
//  * no download, no install, no model loading of un-integrated providers, no network call at all.

// MARK: - A. Local ASR settings

public struct ASRSelection: Codable, Equatable, Sendable {
    public var providerID: String
    public var locale: String
    /// Directory used by the local provider. Saving this path does not load weights.
    public var modelPath: String?
    public var runtimePath: String?
    /// User-entered terminology only; never populated from reference transcripts.
    public var context: String?
    public init(providerID: String = ASRProviderID.qwen3ASR.rawValue,
                locale: String = OfflineSpeechLocale.simplifiedChinese.rawValue,
                modelPath: String? = nil, runtimePath: String? = nil, context: String? = nil) {
        self.providerID = providerID; self.locale = locale; self.modelPath = modelPath
        self.runtimePath = runtimePath; self.context = context
    }
    public static var freshInstall: ASRSelection {
        // Prefer assets beside the delivered app's product directory. CLI checks can
        // resolve the source location by walking up from the build directory.
        var roots: [URL] = []
        for origin in [Bundle.main.bundleURL.deletingLastPathComponent(),
                       URL(fileURLWithPath: #filePath).deletingLastPathComponent()] {
            var directory = origin
            for _ in 0..<8 {
                roots.append(directory.appendingPathComponent("运行依赖/qwen-asr", isDirectory: true))
                let parent = directory.deletingLastPathComponent()
                if parent == directory { break }
                directory = parent
            }
        }
        for root in roots {
            let model = root.appendingPathComponent("model", isDirectory: true)
            let runtime = root.appendingPathComponent(".venv-local", isDirectory: true)
            guard FileManager.default.fileExists(atPath: model.path),
                  FileManager.default.fileExists(atPath: runtime.appendingPathComponent("bin/python").path) else { continue }
            return ASRSelection(modelPath: model.path, runtimePath: runtime.path,
                                context: ASRConfiguration.defaultTerminologyContext)
        }
        return ASRSelection()
    }
}

public enum ASRSwitchRefusal: Equatable, Sendable {
    case captureActive
    case unsupportedProvider(String)
    public var text: String {
        switch self {
        case .captureActive: return "录制中不可切换识别引擎；请先停止。"
        case .unsupportedProvider(let id): return "该引擎未接入（\(id)），无法启用。"
        }
    }
}

/// What the UI can truthfully say about the current ASR selection.
public enum ASRSettingStatus: Equatable, Sendable {
    case unsupported(String)
    case invalidConfiguration(String)
    case permissionRequired(String)
    case unavailable(String)
    case loading
    case readyToPrepare
    case prepared(String)          // active engine description
    case failed(String)
}

@MainActor public final class ASRSettingsModel: ObservableObject {
    /// What the user last picked in the UI. Not yet saved, not yet loaded.
    @Published public private(set) var requested: ASRSelection
    /// What is on disk. Survives relaunch. Still not proof that a backend can run.
    @Published public private(set) var persisted: ASRSelection
    /// The engine a real `load()` produced. nil until a load actually succeeds.
    @Published public private(set) var activeEngineDescription: String?
    @Published public private(set) var activeSelection: ASRSelection?
    @Published public private(set) var loading = false
    private var loadGeneration = UUID()
    public var loadedProvider: LocalASRProvider? {
        guard activeSelection == requested, activeEngineDescription != nil, provider?.activeEngine != nil else { return nil }
        return provider
    }
    @Published public private(set) var status: ASRSettingStatus = .unavailable("尚未检查")
    @Published public private(set) var lastRefusal: ASRSwitchRefusal?
    /// UI draft state lives on the model, not in view-local `@State`: this toolchain's SwiftUI macro plugin
    /// (needed by `@State`) is not present in CommandLineTools, so views here use only non-macro wrappers.
    @Published public var pathDraft: String = ""
    @Published public var runtimeDraft: String = ""
    @Published public var contextDraft: String = ""
    @Published public var testResult: String = ""
    /// True while a capture runs: every switch is refused, not queued.
    @Published public var captureActive = false

    public let services: SpeechServiceSettings
    private var serviceChanges: AnyCancellable?
    public var readyForCapture: Bool { services.usesNetworkASR ? services.networkASRReady : loadedProvider != nil }
    private var provider: LocalASRProvider?
    private var storable: SettingsStorage

    public var catalog: [ASRProviderDescriptor] { LocalASRRegistry.catalog }

    public init(directory: URL) {
        storable = SettingsStorage(directory: directory)
        services = SpeechServiceSettings(directory: directory)
        let loaded: ASRSelection
        let readFailure: String?
        do { loaded = try storable.loadASR(); readFailure = nil }
        catch { loaded = ASRSelection(); readFailure = error.localizedDescription }
        requested = loaded; persisted = loaded
        pathDraft = loaded.modelPath ?? ""
        runtimeDraft = loaded.runtimePath ?? ""
        contextDraft = loaded.context ?? ""
        serviceChanges = services.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        refresh()
        if let readFailure { status = .failed("设置读取失败，未覆盖原文件：\(readFailure)") }
    }

    public var descriptor: ASRProviderDescriptor {
        LocalASRRegistry.catalog.first { $0.id.rawValue == requested.providerID }
            ?? LocalASRRegistry.catalog[0]
    }

    private func configuration(_ s: ASRSelection) -> ASRConfiguration {
        let runtime: QwenRuntimeConfiguration?
        if s.providerID == ASRProviderID.qwen3ASR.rawValue,
           let path = s.runtimePath, !path.isEmpty, let modelPath = s.modelPath {
            let adjacent = QwenRuntimeConfiguration.adjacent(toModelDirectory: modelPath)
            runtime = QwenRuntimeConfiguration(pythonExecutableURL: URL(fileURLWithPath: path).appendingPathComponent("bin/python"),
                                               modelManifestURL: adjacent.modelManifestURL,
                                               referenceDirectoryURL: adjacent.referenceDirectoryURL)
        } else { runtime = nil }
        return ASRConfiguration(providerID: ASRProviderID(rawValue: s.providerID) ?? .appleSpeech,
                                locale: OfflineSpeechLocale(rawValue: s.locale) ?? .simplifiedChinese,
                                modelPath: s.modelPath, qwenRuntime: runtime,
                                terminologyContext: s.context)
    }

    /// A read-only availability probe. No task is started, no authorization is requested, no model is loaded.
    public func refresh() {
        guard !loading else { return }
        if provider?.activeEngine == nil { activeSelection = nil; activeEngineDescription = nil }
        let config = configuration(requested)
        guard let id = ASRProviderID(rawValue: requested.providerID) else {
            status = .invalidConfiguration("未知的引擎标识 \(requested.providerID)"); return
        }
        guard LocalASRRegistry.catalog.first(where: { $0.id == id })?.implemented == true else {
            status = .unsupported("该引擎未接入（只登记元数据，不可启用）"); return
        }
        let p = provider ?? LocalASRRegistry.make(id)
        provider = p
        let readiness = p.inspect(config)
        switch readiness.state {
        case .unsupported: status = .unsupported(readiness.reason ?? "未接入")
        case .invalidConfiguration: status = .invalidConfiguration(readiness.reason ?? "配置无效")
        case .permissionRequired: status = .permissionRequired(readiness.reason ?? "缺少系统语音授权")
        case .unavailable: status = .unavailable(readiness.reason ?? "本机不可用")
        case .readyToPrepare: status = .readyToPrepare
        case .prepared:
            if let e = p.activeEngine { status = .prepared(describe(e)) } else { status = .readyToPrepare }
        }
    }

    private func describe(_ e: ASREngineIdentity) -> String {
        let model = e.modelVersion ?? "nil（系统模型版本不公开）"
        return "引擎 \(e.engineVersion) · 模型 \(model) · 语言 \(e.locale) · generation \(e.generation)"
    }

    /// Pick a provider. Only changes `requested`; never sets `active`, never saves.
    @discardableResult public func request(providerID: String, locale: String, modelPath: String?,
                                          runtimePath: String? = nil, context: String? = nil) -> Bool {
        guard !captureActive, !loading else { lastRefusal = .captureActive; return false }
        guard LocalASRRegistry.catalog.contains(where: { $0.id.rawValue == providerID && $0.implemented }) else {
            lastRefusal = .unsupportedProvider(providerID); return false
        }
        let effectiveContext = context ?? (requested.providerID == providerID ? requested.context : nil)
        guard (effectiveContext?.utf8.count ?? 0) <= 4096 else {
            status = .invalidConfiguration("术语 context 超过 4096 UTF-8 字节；未应用草稿。")
            return false
        }
        lastRefusal = nil
        let isSameProvider = requested.providerID == providerID
        let next = ASRSelection(providerID: providerID, locale: locale, modelPath: modelPath,
                                runtimePath: runtimePath ?? (isSameProvider ? requested.runtimePath : nil),
                                context: context ?? (isSameProvider ? requested.context : nil))
        if next == requested { refresh(); return true }
        requested = next
        activeEngineDescription = nil; activeSelection = nil
        provider?.unload(); provider = nil
        refresh()
        return true
    }

    /// Persist the requested selection. Saving is NOT readiness: `active` is untouched here.
    @discardableResult public func save() -> Bool {
        guard !captureActive, !loading else { lastRefusal = .captureActive; return false }
        do { try storable.saveASR(requested) }
        catch { status = .failed("设置保存失败，原配置保留：\(error.localizedDescription)"); return false }
        persisted = requested
        return true
    }

    public var persistenceFileURL: URL { storable.fileURL }
    /// Called only after the shared settings file was atomically written.
    public func acceptUnifiedPersistence(_ selection: ASRSelection) {
        persisted = selection
    }

    /// A real load. Only this can set `active`. Failure keeps the previous active engine description and
    /// reports the reason instead of pretending success.
    @discardableResult public func loadActive() async -> Bool {
        guard !captureActive, !loading else { lastRefusal = .captureActive; return false }
        guard let id = ASRProviderID(rawValue: requested.providerID),
              LocalASRRegistry.catalog.first(where: { $0.id == id })?.implemented == true else {
            status = .unsupported("该引擎尚未接入，不能运行"); return false
        }
        let p = provider ?? LocalASRRegistry.make(id)
        provider = p
        let selection = requested
        let token = UUID(); loadGeneration = token
        loading = true; status = .loading
        defer { if loadGeneration == token { loading = false } }
        do {
            let identity = try await p.loadAsync(configuration(selection))
            try Task.checkCancellation()
            guard loadGeneration == token, selection == requested, !captureActive else { return false }
            activeSelection = selection
            activeEngineDescription = describe(identity)
            status = .prepared(describe(identity))
            return true
        } catch {
            guard loadGeneration == token else { return false }
            activeSelection = nil; activeEngineDescription = nil
            status = .failed(String(describing: p.lastFailure ?? .invalidConfiguration("LOAD_FAILED")))
            return false
        }
    }

    /// Short-audio test: a fixed synthetic buffer through the full real path. No microphone is opened and no
    /// audio is uploaded. With no usable backend this reports the honest reason instead of a fake transcript.
    public func runShortAudioTest() async -> String {
        guard !captureActive, !loading else { return "录制或加载中不可测试；请先停止。" }
        guard requested.providerID != ASRProviderID.qwen3ASR.rawValue else { return "Qwen 使用完整文件分段识别，请使用文件批处理入口；不提供 PCM partial 测试。" }
        guard let id = ASRProviderID(rawValue: requested.providerID),
              LocalASRRegistry.catalog.first(where: { $0.id == id })?.implemented == true else {
            return "该引擎未接入，无法测试（只登记元数据，未运行）。"
        }
        let p = provider ?? LocalASRRegistry.make(id)
        provider = p
        let readiness = p.inspect(configuration(requested))
        guard readiness.state == .readyToPrepare || readiness.state == .prepared else {
            return "未开始测试：\(readiness.state.rawValue) · \(readiness.reason ?? "无原因")"
        }
        do {
            _ = try await p.loadAsync(configuration(requested))
        } catch {
            return "测试失败于准备阶段：\(String(describing: p.lastFailure ?? .invalidConfiguration("LOAD_FAILED")))"
        }
        guard let buffer = SyntheticPCM.oneSecondOfSilence() else { return "测试失败：无法构造合成 PCM。" }
        var transcript: String?
        var failure: String?
        defer { p.cancel() }
        do {
            try p.start(intent: SpeechStartIntent(userInitiated: true, speechEnabled: true, onDeviceProcessingAuthorized: true),
                        sessionID: "settings-short-audio-test", channelID: "synthetic", streamID: "synthetic-1",
                        segmentID: "seg-test") { event in
                switch event.output {
                case .transcript(let u): if u.status == "final" { transcript = u.text }
                case .failed(let f): failure = String(describing: f)
                }
            }
            try p.append(buffer, source: PCMSourceRange(frameStart: 0, frameEnd: Int(buffer.frameLength),
                                                        mappingRevision: 1, startNs: 0, endNs: 1_000_000_000))
            try p.finishAudio()
            let deadline = ProcessInfo.processInfo.systemUptime + 12
            while transcript == nil && failure == nil && ProcessInfo.processInfo.systemUptime < deadline {
                try Task.checkCancellation()
                p.pollFinalDeadline()
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        } catch {
            failure = String(describing: (error as? ASRProviderError) ?? .invalidConfiguration("TEST_FAILED"))
        }
        if let failure { return "测试未通过：\(failure)（无结果，未伪造文字）" }
        if let transcript { return "测试结果：\(transcript)" }
        return "测试已执行，但未在期限内收到 final（无文字，未伪造）"
    }

    public func unload() {
        guard !captureActive else { lastRefusal = .captureActive; return }
        loadGeneration = UUID(); loading = false
        provider?.unload(); activeEngineDescription = nil; activeSelection = nil; refresh()
    }
}

/// Fixed synthetic PCM. Never microphone input.
public enum SyntheticPCM {
    public static func oneSecondOfSilence(sampleRate: Double = 16_000) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return nil }
        let frames = AVAudioFrameCount(sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        if let ch = buffer.floatChannelData { for i in 0..<Int(frames) { ch[0][i] = 0 } }
        return buffer
    }
}

// MARK: - B. Backend API settings (notes / Q&A / retrieval)

public enum BackendAPIStatus: Equatable, Sendable {
    case unconfigured
    case configuredUnverified
    case credentialReady
    case verificationFailed(String)
    case available
    public var text: String {
        switch self {
        case .unconfigured: return "未配置"
        case .configuredUnverified: return "已配置 · 尚未验证"
        case .credentialReady: return "密钥已就绪 · API 尚未联网验证"
        case .verificationFailed(let r): return "验证失败：\(r)"
        case .available: return "API 连接测试通过"
        }
    }
}

public struct BackendAPISettings: Codable, Equatable, Sendable {
    public var baseURL: String
    public var modelID: String
    /// A *reference* to where the key lives (e.g. an environment variable name). The key value itself is
    /// never stored here, never logged, and never shown.
    public var secretReference: String
    public init(baseURL: String = "", modelID: String = "", secretReference: String = "") {
        self.baseURL = baseURL; self.modelID = modelID; self.secretReference = secretReference
    }
    public var isFilled: Bool { !baseURL.isEmpty && !modelID.isEmpty && !secretReference.isEmpty }
}

@MainActor public final class BackendAPISettingsModel: ObservableObject {
    @Published public private(set) var persisted: BackendAPISettings
    @Published public var draft: BackendAPISettings
    /// Transient input; never encoded into settings, archives, or logs.
    @Published public var secretInput = ""
    @Published public private(set) var unifiedTesting = false
    @Published public private(set) var unifiedTestMessage = "填写完成后，点击“测试配置”。"
    private struct DraftSnapshot: Equatable {
        var asr: ASRSelection
        var backend: BackendAPISettings
        var secret: String
    }
    private var testedSnapshot: DraftSnapshot?
    private var testGeneration = UUID()
    private var unifiedTask: Task<Void, Never>?
    @Published public private(set) var status: BackendAPIStatus
    /// No network call is authorised yet, so verification reports this plainly rather than faking a check.
    public static let verificationNote = "配置测试只发送固定的简短请求，不发送会议内容；主窗口生成纪要 / 待办 / 问答时才发送所选会话内容。"

    private let storable: SettingsStorage
    private let credentials: any BackendCredentialStore

    public init(directory: URL, credentials: any BackendCredentialStore = KeychainBackendCredentialStore()) {
        storable = SettingsStorage(directory: directory)
        self.credentials = credentials
        let loaded = (try? storable.loadBackendAPI()) ?? BackendAPISettings()
        persisted = loaded; draft = loaded
        status = loaded.isFilled ? .configuredUnverified : .unconfigured
    }

    @discardableResult public func save() -> Bool {
        var candidate = draft
        let secret = secretInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let newReference = secret.isEmpty ? nil : "KEYCHAIN_" + UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        if let newReference { candidate.secretReference = newReference }
        do {
            // Validate all configuration before writing a password.
            guard let url = URL(string: candidate.baseURL) else { throw APIIntelligenceError.invalidConfiguration }
            let config = APIIntelligenceConfiguration(baseURL: url, modelID: candidate.modelID,
                                                      credentialReference: candidate.secretReference)
            try config.validate()
            if let newReference {
                guard secret.count <= 4096, !secret.contains(where: { $0.isWhitespace }) else {
                    throw APIIntelligenceError.invalidConfiguration
                }
                try credentials.save(secret, reference: newReference)
            }
            do { try storable.saveBackendAPI(candidate) }
            catch {
                if let newReference { try? credentials.remove(reference: newReference) }
                throw error
            }
        } catch {
            // Never include the draft, URL, or credential in diagnostic output.
            status = .verificationFailed("保存失败：请检查地址、模型和密钥，或确认钥匙串可访问")
            return false
        }
        persisted = candidate
        draft = candidate
        secretInput = ""
        status = candidate.isFilled ? .configuredUnverified : .unconfigured
        return true
    }

    /// The settings view holds no `@State` of its own, so it seeds the editable draft from disk on appear.
    public func syncDraftFromPersisted() { draft = persisted; secretInput = "" }

    /// Where the settings file lives, for independent inspection by checks.
    public func storableFileURLForCheck() -> URL { storable.fileURL }

    /// Record the outcome of a verification the user performed elsewhere. Never invents a success.
    public func recordVerification(_ outcome: BackendAPIStatus) { status = outcome }

    /// Build the actual API module configuration. Validation does not obtain a credential or send requests.
    public func apiConfiguration(protocolID: String = "openai-chat-completions") throws -> APIIntelligenceConfiguration {
        guard let url = URL(string: persisted.baseURL),
              persisted.secretReference.range(of: "^[A-Z_][A-Z0-9_]{0,127}$", options: .regularExpression) != nil else {
            throw APIIntelligenceError.invalidConfiguration
        }
        let config = APIIntelligenceConfiguration(baseURL: url, modelID: persisted.modelID,
                                                   credentialReference: persisted.secretReference, protocolID: protocolID)
        try config.validate()
        return config
    }
    public func inspectAPIConfiguration() {
        do {
            _ = try apiConfiguration()
            status = secretIsPresent() ? .credentialReady : .verificationFailed("缺少安全凭据；配置未验证，未发送请求")
        } catch { status = .verificationFailed("API配置无效或协议未支持；未发送请求") }
    }

    /// Reads the local Keychain for new settings; legacy environment references still work.
    public func secretIsPresent() -> Bool {
        guard !persisted.secretReference.isEmpty else { return false }
        if persisted.secretReference.hasPrefix("KEYCHAIN_") {
            return (try? credentials.read(reference: persisted.secretReference))?.isEmpty == false
        }
        return ProcessInfo.processInfo.environment[persisted.secretReference]?.isEmpty == false
    }

    public var credentialHint: String {
        if persisted.secretReference.hasPrefix("KEYCHAIN_") {
            return "已保存到 macOS 钥匙串；留空保留现有密钥，输入新密钥后保存可替换"
        }
        if !persisted.secretReference.isEmpty {
            return "已有环境变量配置；粘贴密钥并保存后改用 macOS 钥匙串"
        }
        return "粘贴 API 密钥后点击保存；密钥存入 macOS 钥匙串"
    }

    private func snapshot(asr: ASRSettingsModel) -> DraftSnapshot {
        let hasDirectory = asr.descriptor.pathKind == .directory
        let selection = ASRSelection(providerID: asr.requested.providerID, locale: asr.requested.locale,
            modelPath: hasDirectory ? asr.pathDraft.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            runtimePath: hasDirectory ? asr.runtimeDraft.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            context: hasDirectory ? asr.contextDraft : asr.requested.context)
        var config = draft
        config.baseURL = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        config.modelID = config.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return DraftSnapshot(asr: selection, backend: config,
                             secret: secretInput.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func canSaveTogether(asr: ASRSettingsModel) -> Bool {
        !unifiedTesting && !asr.captureActive && !asr.loading &&
        testedSnapshot == snapshot(asr: asr) && asr.services.testMatches && (asr.services.draft.asr.location == .network || asr.loadedProvider != nil)
    }

    public func needsRetest(asr: ASRSettingsModel) -> Bool {
        testedSnapshot != nil && (testedSnapshot != snapshot(asr: asr) || !asr.services.testMatches || (asr.services.draft.asr.location == .local && asr.loadedProvider == nil))
    }

    public func startUnifiedTest(asr: ASRSettingsModel) {
        guard !unifiedTesting, !asr.captureActive, !asr.loading else { return }
        unifiedTask = Task { await testTogether(asr: asr) }
    }

    public func cancelUnifiedTest(asr: ASRSettingsModel) {
        guard unifiedTesting else { return }
        testGeneration = UUID()
        unifiedTask?.cancel()
        if asr.loading { asr.unload() }
        unifiedTesting = false
        testedSnapshot = nil
        asr.services.invalidateTest()
        unifiedTestMessage = "测试已取消；没有保存配置。"
    }

    public func testTogether(asr: ASRSettingsModel,
                            probe: any BackendConfigurationProbing = BackendConfigurationProbe()) async {
        guard !unifiedTesting, !asr.captureActive, !asr.loading else { return }
        let current = snapshot(asr: asr)
        let generation = UUID()
        testGeneration = generation
        testedSnapshot = nil
        unifiedTesting = true
        defer { if testGeneration == generation { unifiedTesting = false } }
        guard asr.request(providerID: current.asr.providerID, locale: current.asr.locale,
                          modelPath: current.asr.modelPath, runtimePath: current.asr.runtimePath,
                          context: current.asr.context) else {
            unifiedTestMessage = "A 测试失败：无法应用语音配置。"
            return
        }
        unifiedTestMessage = "正在测试 A：检查路径并加载语音引擎，首次加载可能需要等待。"
        if asr.services.draft.asr.location == .local && asr.loadedProvider == nil {
            guard await asr.loadActive() else {
                if testGeneration == generation {
                    unifiedTestMessage = "A 测试失败：\(asr.status)；未保存。"
                }
                return
            }
        }
        guard testGeneration == generation, !Task.isCancelled else { return }
        do { try await asr.services.test() }
        catch {
            guard testGeneration == generation else { return }
            unifiedTestMessage = "转写 / 翻译测试失败：" + error.localizedDescription + "；未保存。"
            return
        }
        let hasBackend = !current.backend.baseURL.isEmpty || !current.backend.modelID.isEmpty ||
                         !current.backend.secretReference.isEmpty || !current.secret.isEmpty
        if hasBackend {
            unifiedTestMessage = "A 引擎加载通过；正在测试 B 的地址、密钥和模型响应。"
            do {
                let secret: String
                if !current.secret.isEmpty { secret = current.secret }
                else if current.backend.secretReference.hasPrefix("KEYCHAIN_") {
                    secret = try credentials.read(reference: current.backend.secretReference) ?? ""
                } else {
                    secret = ProcessInfo.processInfo.environment[current.backend.secretReference] ?? ""
                }
                guard secret.count <= 4096, !secret.contains(where: { $0.isWhitespace }) else {
                    throw APIIntelligenceError.invalidConfiguration
                }
                try await probe.test(settings: current.backend, secret: secret)
            } catch {
                guard testGeneration == generation else { return }
                let reason: String
                if case APIIntelligenceError.httpRejected(let code) = error {
                    reason = "服务返回 HTTP \(code)，请检查地址、密钥与模型"
                } else if error is CancellationError {
                    reason = "测试已取消"
                } else {
                    reason = "配置无效、连接超时或模型未返回有效响应"
                }
                unifiedTestMessage = "B 测试失败：\(reason)；未保存。"
                return
            }
        }
        guard testGeneration == generation, !Task.isCancelled,
              current == snapshot(asr: asr), asr.services.testMatches, !asr.captureActive else {
            unifiedTestMessage = "配置已改变，请重新测试；未保存。"
            return
        }
        testedSnapshot = current
        if hasBackend { status = .available }
        unifiedTestMessage = hasBackend
            ? "测试通过：所选转写 / 翻译服务通过，B 模型响应成功。可以保存并关闭。"
            : "测试通过：所选转写 / 翻译服务通过；B 未配置，已跳过。可以保存并关闭。"
    }

    @discardableResult public func saveTogether(asr: ASRSettingsModel) -> Bool {
        guard canSaveTogether(asr: asr),
              asr.persistenceFileURL.standardizedFileURL == storable.fileURL.standardizedFileURL else {
            unifiedTestMessage = "配置未测试、已改变或存储位置不一致，请重新测试。"
            return false
        }
        let current = snapshot(asr: asr)
        var candidate = current.backend
        let newReference = current.secret.isEmpty ? nil :
            "KEYCHAIN_" + UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        if let newReference { candidate.secretReference = newReference }
        let serviceSave: (SpeechServiceConfiguration, [String])
        do { serviceSave = try asr.services.prepareSave() }
        catch { unifiedTestMessage = error.localizedDescription; return false }
        do {
            if let newReference { try credentials.save(current.secret, reference: newReference) }
            do { try storable.saveAll(asr: current.asr, backend: candidate, speechServices: serviceSave.0) }
            catch {
                if let newReference { try? credentials.remove(reference: newReference) }
                throw error
            }
        } catch {
            asr.services.rollback(serviceSave.1)
            unifiedTestMessage = "保存失败：原配置保留，请检查钥匙串或文件写入权限。"
            return false
        }
        persisted = candidate
        draft = candidate
        secretInput = ""
        asr.acceptUnifiedPersistence(current.asr)
        asr.services.acceptSave(serviceSave.0)
        testedSnapshot = nil
        // The save is the end of the test transaction. Leave unifiedTesting
        // true here and onDisappear's cancelUnifiedTest() would unload the
        // Qwen engine that was just successfully loaded, making the main
        // window report "engine not loaded" immediately after a green test.
        unifiedTesting = false
        status = candidate.isFilled ? .available : .unconfigured
        unifiedTestMessage = "A 与 B 配置已一起保存。"
        return true
    }
}

// MARK: - storage

/// `settings.json` lives beside the archive. It is a separate file: the archive schema is untouched.
public struct SettingsStorage {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    public var fileURL: URL { directory.appendingPathComponent("settings.json") }

    private struct Payload: Codable, Equatable {
        var schemaVersion: Int = 1
        var asr: ASRSelection = ASRSelection.freshInstall
        var backendAPI: BackendAPISettings = BackendAPISettings()
        var speechServices: SpeechServiceConfiguration?
    }

    private func load() throws -> Payload {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return Payload() }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(Payload.self, from: data)
    }
    private func mutate(_ body: (inout Payload) -> Void) throws {
        var p = try load()
        body(&p)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(p).write(to: fileURL, options: .atomic)
    }
    public func loadSpeechServices() throws -> SpeechServiceConfiguration { try load().speechServices ?? .init() }
    public func loadASR() throws -> ASRSelection { try load().asr }
    public func loadBackendAPI() throws -> BackendAPISettings { try load().backendAPI }
    public func saveASR(_ s: ASRSelection) throws { try mutate { $0.asr = s } }
    public func saveAll(asr: ASRSelection, backend: BackendAPISettings, speechServices: SpeechServiceConfiguration? = nil) throws {
        guard backend.secretReference.isEmpty ||
              backend.secretReference.range(of: "^[A-Z_][A-Z0-9_]{0,127}$", options: .regularExpression) != nil else {
            throw NSError(domain: "Settings", code: 2)
        }
        try mutate { $0.asr = asr; $0.backendAPI = backend; if let speechServices { $0.speechServices = speechServices } }
    }
    public func saveBackendAPI(_ b: BackendAPISettings) throws {
        // This field accepts an environment-variable IDENTIFIER only, never an arbitrary credential value.
        guard b.secretReference.isEmpty || b.secretReference.range(of: "^[A-Z_][A-Z0-9_]{0,127}$", options: .regularExpression) != nil else {
            throw NSError(domain: "Settings", code: 2, userInfo: [NSLocalizedDescriptionKey: "密钥引用须为环境变量名；拒绝保存密钥值"])
        }
        try mutate { $0.backendAPI = b }
    }
}
