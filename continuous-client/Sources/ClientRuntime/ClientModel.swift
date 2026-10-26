import SwiftUI
import AppKit
import MeetingCopilotCore
import LocalTranslationEngine
import DesktopSessionController
import LiveSpeechSession
import AppleOfflineSpeech
import RotatingSpeechSession
import SpeechCore
import IncrementalArchive
import ClientIncrementalBridge
import LocalASRProviders
import MeetingCopilotAudioCapture

public enum SegmentTranslationActivity: Equatable {
    case translating
    case failed(String)
}
public struct SegmentTranslationPresentation {
    public let text: String?
    public let status: String
    public let isOriginal: Bool
    public let isFailure: Bool
}

@MainActor public final class ClientModel: ObservableObject {
    @Published public var archive = LocalArchive()
    @Published public var selection: String? {
        didSet {
            guard oldValue != selection else { return }
            if captureActive { cancelCapture() }
            if let previous = oldValue { drafts[previous] = (inputText, editingSegmentID) }
            let draft = selection.flatMap { drafts[$0] }
            inputText = draft?.0 ?? ""; editingSegmentID = draft?.1
        }
    }
    private var drafts: [String: (String, String?)] = [:]
    @Published public var error: String?
    @Published public var saved = "尚未保存"
    @Published public var loaded = false
    @Published public var inputText = ""
    @Published public var sourceLanguage = "en"
    @Published public var targetLanguage = "zh-Hans"
    @Published public var editingSegmentID: String?
    @Published private var translationStatuses: [String: String] = [:]
    @Published private var segmentTranslationActivities: [String: SegmentTranslationActivity] = [:]
    public var translationStatus: String {
        get { selection.flatMap { translationStatuses[$0] } ?? (translateFinal ? "自动翻译已开启 · 每段原文保存后生成译文" : "自动翻译已关闭") }
        set { if let id = selection { translationStatuses[id] = newValue } }
    }
    private func setTranslationStatus(_ message: String, sessionID: String) { translationStatuses[sessionID] = message }
    public var translationTargetName: String {
        let code = TranslationLanguages.code(targetLanguage)
        return Locale(identifier: "zh_CN").localizedString(forLanguageCode: code) ?? targetLanguage
    }
    private func translationActivityKey(sessionID: String, segment: LocalSegment) -> String {
        "\(sessionID):\(segment.id):\(targetLanguage):r\(segment.current?.revision ?? 0)"
    }
    public func translationPresentation(sessionID: String, segment: LocalSegment) -> SegmentTranslationPresentation {
        guard let source = segment.current else {
            return .init(text: nil, status: "暂无原文", isOriginal: false, isFailure: false)
        }
        if TranslationLanguages.sameLanguage(source.sourceLanguage ?? sourceLanguage, targetLanguage, text: source.text) {
            return .init(text: source.text, status: "\(translationTargetName)原文 · 无需翻译", isOriginal: true, isFailure: false)
        }
        if let translation = segment.currentTranslations.last(where: {
            TranslationLanguages.sameLanguage($0.targetLanguage, targetLanguage)
        }) {
            return .init(text: translation.text, status: "译文已保存", isOriginal: false, isFailure: false)
        }
        switch segmentTranslationActivities[translationActivityKey(sessionID: sessionID, segment: segment)] {
        case .translating:
            return .init(text: nil, status: "正在翻译成\(translationTargetName)…", isOriginal: false, isFailure: false)
        case .failed(let message):
            return .init(text: nil, status: "翻译失败：\(message)", isOriginal: false, isFailure: true)
        case nil:
            return .init(text: nil, status: translateFinal ? "等待翻译成\(translationTargetName)…" : "自动翻译已关闭", isOriginal: false, isFailure: false)
        }
    }
    /// Also covers originals saved before automatic translation was enabled.
    public func translateMissingCurrentSegments() {
        guard loaded, error == nil, let session = selected else { return }
        let pending = session.segments.filter { segment in
            let display = translationPresentation(sessionID: session.id, segment: segment)
            return display.text == nil &&
                segmentTranslationActivities[translationActivityKey(sessionID: session.id, segment: segment)] != .translating
        }
        for segment in pending { translateSegment(sessionID: session.id, segmentID: segment.id) }
    }
    var coordinators: [String: TextSessionCoordinator] = [:]
    private var translationTasks: [String: Task<Void, Never>] = [:]
    /// Real, currently-unfinished translation tasks, keyed by request key with the exact task token. A task is
    /// removed only when its body really ends; cancelling a suspended task is not proof that it ended.
    private var translationTaskTokens: [String: UUID] = [:]
    /// Tokens whose task was cancelled but whose body has not ended yet. Their outcome is already decided
    /// (dropped, never accepted), so they are reported but they never block a close the way a live one does.
    private var cancelledTranslationTokens: Set<UUID> = []
    /// Every translation task whose body is still running (cancelled ones included).
    public var activeTranslationCount: Int { translationTaskTokens.count }
    /// Translation tasks that can still produce a result and therefore must block a close.
    public var pendingTranslationCount: Int { translationTaskTokens.values.filter { !cancelledTranslationTokens.contains($0) }.count }
    /// Cancelled tasks whose body has not ended yet: reported, never awaited forever.
    public var cancelledTranslationCount: Int { activeTranslationCount - pendingTranslationCount }
    /// Explicit product semantics for termination: "closing cancels translations that have not produced a
    /// result". Cancelling marks the token cancelled, so a late callback can no longer accept/project into the
    /// in-memory archive; the token itself is released only when the task body really ends. A translation already
    /// accepted and projected before this call stays durable through the authoritative journal and is drained
    /// by the close preflight.
    public func cancelInFlightTranslations() {
        for (key, token) in translationTaskTokens { cancelledTranslationTokens.insert(token) }
        for (_, task) in translationTasks { task.cancel() }
    }
    private let translator = InstalledSystemTranslator()
    private let configURL: URL?
    private let translationOperation: (@MainActor (TranslationJob) async throws -> TranslationOutput)?
    func coordinator(_ session: LocalSession) throws -> TextSessionCoordinator {
        if let cached = coordinators[session.id] { return cached }
        guard let configURL = configURL else {
            throw NSError(domain: "TextMode", code: 1, userInfo: [NSLocalizedDescriptionKey: "CONFIG_REQUIRED：缺少文本模式配置"])
        }
        return try TextSessionCoordinator(session: session, config: TextModeConfig.load(configURL))
    }
    public func editSource(_ segment: LocalSegment) {
        guard segment.channelKind == "typed_text" else { return }
        editingSegmentID = segment.id; inputText = segment.current?.text ?? ""
    }
    public func submitText(translate: Bool) {
        guard loaded, let id = selection, let i = archive.sessions.firstIndex(where: { $0.id == id }) else { return }
        do {
            var c = try coordinator(archive.sessions[i])
            let event = try c.submit(text: inputText, segmentID: editingSegmentID)
            c.project(into: &archive.sessions[i]); coordinators[id] = c; editingSegmentID = event.segmentId
            if incremental != nil {
                // Incremental mode: submit the authoritative wire; "saved" only after its own ack.
                incrementalFlushJournal(session: id)
                translationStatus = "原文已提交 · 等待写入确认 · 文本录入不是语音识别"
            } else {
                guard persist() else { return }
                translationStatus = "原文已保存 · 文本录入不是语音识别"
            }
            if translate, let segmentID = event.segmentId { translateSegment(sessionID: id, segmentID: segmentID) }
        } catch { translationStatus = "文本处理失败：\(error.localizedDescription)" }
    }
    public func translateSegment(sessionID: String, segmentID: String) {
        guard loaded, error == nil, let i = archive.sessions.firstIndex(where: { $0.id == sessionID }),
              let segment = archive.sessions[i].segments.first(where: { $0.id == segmentID }),
              let source = segment.current else { return }
        let activityKey = translationActivityKey(sessionID: sessionID, segment: segment)
        if source.sourceLanguage != nil &&
            TranslationLanguages.sameLanguage(source.sourceLanguage ?? sourceLanguage, targetLanguage, text: source.text) {
            setTranslationStatus("原文已是\(translationTargetName)，无需翻译", sessionID: sessionID)
            return
        }
        do {
            var c = try coordinator(archive.sessions[i])
            let request = try c.request(segmentID: segmentID, targetLanguage: targetLanguage)
            coordinators[sessionID] = c
            let key = "\(sessionID):\(segmentID):\(targetLanguage)"
            translationTasks[key]?.cancel()
            let job = TranslationJob(requestID: request.id, segmentID: request.segmentId, sourceRevision: request.sourceRevision, sourceText: request.sourceText, sourceLanguage: archive.sessions[i].segments.first(where: { $0.id == segmentID })?.current?.sourceLanguage ?? sourceLanguage, targetLanguage: request.targetLanguage)
            let networkSettings = asrSettings?.services
            let networkTranslation = networkSettings?.persisted.translation.location == .network
            setTranslationStatus("正在" + (networkTranslation ? "网络" : "本机") + "翻译成\(translationTargetName)", sessionID: sessionID)
            segmentTranslationActivities[activityKey] = .translating
            let token = UUID()
            translationTaskTokens[key] = token
            translationTasks[key] = Task { [weak self] in
                guard let self else { return }
                // The token is released only when this body actually ends. A cancellation alone is not an end:
                // the await may still be suspended, so the close gate keeps waiting for the real `defer`.
                defer {
                    if self.translationTaskTokens[key] == token {
                        self.translationTaskTokens.removeValue(forKey: key)
                        if self.segmentTranslationActivities[activityKey] == .translating {
                            self.segmentTranslationActivities.removeValue(forKey: activityKey)
                        }
                    }
                    self.cancelledTranslationTokens.remove(token)
                }
                do {
                    let output: TranslationOutput
                    if let operation = self.translationOperation { output = try await operation(job) }
                    else if networkTranslation, let networkSettings { output = try await networkSettings.translate(job) }
                    else { output = try await self.translator.translate(job) }
                    // A cancelled/terminal close must never let a late result mutate the in-memory archive.
                    try Task.checkCancellation()
                    guard self.translationTaskTokens[key] == token, !self.cancelledTranslationTokens.contains(token) else { return }
                    guard var latest = self.coordinators[sessionID], let index = self.archive.sessions.firstIndex(where: { $0.id == sessionID }) else { return }
                    guard try latest.accept(request, translatedText: output.translatedText) != nil else {
                        self.setTranslationStatus("旧请求响应已丢弃，未改变当前译文", sessionID: sessionID); return
                    }
                    latest.project(into: &self.archive.sessions[index]); self.coordinators[sessionID] = latest
                    self.segmentTranslationActivities.removeValue(forKey: activityKey)
                    if self.incremental != nil {
                        // Translation is a typed revision with an exact source binding; submit its real wire.
                        self.incrementalFlushJournal(session: sessionID)
                        self.setTranslationStatus("译文已提交 · 等待写入确认 · 精确绑定源 r\(request.sourceRevision)", sessionID: sessionID)
                    } else if self.persist() {
                        self.setTranslationStatus("译文已保存 · 精确绑定源 r\(request.sourceRevision)", sessionID: sessionID)
                    }
                } catch is CancellationError { /* Superseded request must not overwrite new request state. */ }
                catch {
                    guard self.translationTaskTokens[key] == token, !self.cancelledTranslationTokens.contains(token) else { return }
                    self.segmentTranslationActivities[activityKey] = .failed(error.localizedDescription)
                    self.setTranslationStatus("翻译失败，原文保留：\(error.localizedDescription)", sessionID: sessionID)
                }
            }
        } catch {
            segmentTranslationActivities[activityKey] = .failed(error.localizedDescription)
            setTranslationStatus("无法开始翻译：\(error.localizedDescription)", sessionID: sessionID)
        }
    }
    @Published public var materialFolderConfigurations: [String: MaterialFolderConfiguration] = [:]
    @Published public var materialFolderBusy = false
    @Published public var materialFolderReport: [String] = []
    @Published public var materialFolderReportSessionID: String?
    var materialFolderTask: Task<Void, Never>?
    var materialFolderToken: UUID?
    @Published public var materialStatus = "资料仅本地保存和展示，尚未接入模型上下文"
    public func importMaterial() {
        guard loaded, let id = selection, let index = archive.sessions.firstIndex(where: { $0.id == id }) else { return }
        if let message = incrementalMaterialRefusal(session: id) { materialStatus = message; return }
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.title = "选择 UTF-8 TXT/MD 资料（最多 2 MiB，仅本地）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // Same reader and same 2 MiB input guard on both paths; only the storage path differs.
            let material = try MaterialImport.read(url, maxBytes: 2 * 1024 * 1024)
            guard !archive.sessions[index].materials.contains(where: { $0.sha256 == material.sha256 }) else { materialStatus = "相同内容已导入，本次未重复添加"; return }
            archive.sessions[index].materials.append(material)
            guard let persistence = incremental else {
                if persist() { materialStatus = "已导入并回读：\(material.fileName) · 未发送给模型" }
                return
            }
            let chunks = incrementalMaterialChunks(session: id, material: material)
            materialStatus = incrementalSubmitMaterial(session: id, chunks: chunks)
                ? "已提交分块 \(chunks.count)/\(chunks.count) · 等待写入确认 · \(material.fileName) · 未发送给模型"
                : "资料分块未获接纳（\(persistence.status.failureText ?? "未知原因")），已保留在本地内存，未声称已保存"
            incrementalSavingStatus = persistence.userStatus(head: persistence.lastConfirmedHead)
        } catch { materialStatus = "资料导入失败：\(error.localizedDescription)" }
    }
    @Published public var keyword = ""
    @Published public var exportStatus = ""
    public var visibleSessions: [LocalSession] { NoteOperations.search(archive.activeSessions, keyword: keyword) }
    public var deletedSessions: [LocalSession] { archive.deletedSessions }
    @Published public var deletionStatus = ""
    /// Logical deletion: the session leaves the active list, its content and revisions stay auditable.
    public func deleteSelected(reason: String = "user_requested") {
        guard let id = selection else { return }
        deleteSession(id, reason: reason)
    }
    public func deleteSession(_ id: String, reason: String = "user_requested") {
        guard loaded, !captureActive, !captureStopping, !materialFolderBusy, error == nil,
              let index = archive.sessions.firstIndex(where: { $0.id == id }) else { return }
        let previous = archive
        if archive.sessions[index].isDeleted { deletionStatus = "该会话已有删除记录，本次未重复写入"; return }
        do {
            let record = try LocalDeletion.tombstone(&archive, sessionID: id, reason: reason)
            if let persistence = incremental {
                // Typed logical deletion: the record is real, but "saved" waits for its own acknowledgement.
                guard persistence.submitTombstone(session: id, record: record) else {
                    archive = previous
                    deletionStatus = "删除记录未获接纳（\(persistence.status.failureText ?? "未知原因")），原会话仍在活动列表"
                    return
                }
                submittedTombstones.insert(id)
                if selection == id { selection = archive.activeSessions.first?.id }
                deletionStatus = "已提交删除记录 \(record.id) · 等待写入确认 · 原内容保留在审计档案"
                incrementalSavingStatus = persistence.userStatus(head: persistence.lastConfirmedHead)
                return
            }
            guard persist() else { archive = previous; deletionStatus = "删除记录未保存，原会话仍在"; return }
            if selection == id { selection = archive.activeSessions.first?.id }
            deletionStatus = "已记录删除 · 原内容保留在审计档案 · 记录 \(record.id)"
        } catch { archive = previous; deletionStatus = "删除未执行：\(error.localizedDescription)" }
    }
    public func deletedAuditText() -> String { LocalDeletion.auditLines(archive).joined(separator: "\n") }
    public func exportSelected(_ format: NoteExportFormat) {
        guard let session = selected else { return }
        let panel = NSSavePanel()
        panel.title = "导出当前会话（含修订历史）"
        panel.nameFieldStringValue = "会话-\(session.id).\(format.rawValue)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try NoteOperations.export(session, format: format, to: url); exportStatus = "导出已回读确认：\(url.lastPathComponent)" }
        catch { exportStatus = "导出失败：\(error.localizedDescription)（已有文件不会覆盖）" }
    }
    public let store: ArchiveStore
    public let captureController: DesktopSessionController
    public init(directory overrideDirectory: URL? = nil, configURL: URL? = Bundle.main.url(forResource: "text-mode-config", withExtension: "json"), controller: DesktopSessionController? = nil, translationOperation: (@MainActor (TranslationJob) async throws -> TranslationOutput)? = nil) {
        let env = ProcessInfo.processInfo.environment
        let directory: URL
        if let overrideDirectory { directory = overrideDirectory }
        else if let path = env["MEETING_COPILOT_DATA_DIR"] { directory = URL(fileURLWithPath: path, isDirectory: true) }
        else { directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(ProductIdentity.dataDirectoryName, isDirectory: true) }
        store = ArchiveStore(directory: directory)
        self.configURL = configURL
        self.translationOperation = translationOperation
        captureController = controller ?? DesktopSessionController()
        // Default controller constructs AppleOnDeviceBackend for both finite and rotating paths. Injected
        // controllers may use any backend: leave their identity unknown rather than labelling them Apple.
        if controller == nil {
            captureEngineVersion = "apple.SFSpeechRecognizer/on-device;adapter=1;os=" + ProcessInfo.processInfo.operatingSystemVersionString
        }
        do {
            // Initial selection is a LIVE session only. A tombstoned session stays in `archive.sessions` for
            // audit, so selecting `sessions.first` would render a deleted session as active after a reopen.
            // There is deliberately NO fallback to a deleted session: when every session is deleted the
            // selection is nil and the detail pane shows its empty state.
            archive = try store.load(); loaded = true
            selection = archive.activeSessions.first?.id; saved = "已读取本地文件"
            let folderURL = directory.appendingPathComponent("material-folders.json")
            if FileManager.default.fileExists(atPath: folderURL.path) {
                do { materialFolderConfigurations = try JSONDecoder().decode([String: MaterialFolderConfiguration].self, from: Data(contentsOf: folderURL)) }
                catch { materialStatus = "资料文件夹配置读取失败，原文件保留：\(error.localizedDescription)" }
            }
            // Restoring historical metadata never restores a device/task. Interrupted attempts remain explicit.
            var interrupted = false
            for i in archive.sessions.indices {
                for j in archive.sessions[i].captureAttempts.indices where ["prepared", "requestingPermissions", "capturing", "stopping"].contains(archive.sessions[i].captureAttempts[j].lifecycle) {
                    archive.sessions[i].captureAttempts[j].lifecycle = "incomplete"
                    archive.sessions[i].captureAttempts[j].failure = "application_interrupted"
                    archive.sessions[i].captureAttempts[j].history.append("incomplete:application_interrupted")
                    interrupted = true
                }
            }
            if interrupted { archive = try store.save(archive) }
            // Explicit isolated smoke fixture only; ordinary launch never injects demo content.
            if env["MEETING_COPILOT_UI_EVIDENCE"] != nil, env["MEETING_COPILOT_DATA_DIR"] != nil, env["MEETING_COPILOT_SMOKE_DEMO"] == "1", archive.sessions.isEmpty {
                archive.sessions = [LocalSession.demonstration()]
                archive.sessions[0].editNotes("合成保存验证：示例词；USD 2,450.75。\n😀 无真实音频。")
                archive = try store.save(archive)
                selection = archive.sessions[0].id; saved = "演示已保存并回读确认"
            }
        }
        catch { loaded = false; self.error = "读取失败，写入已禁用：\(error.localizedDescription)" }
    }
    public var selected: LocalSession? { archive.sessions.first { $0.id == selection } }
    @discardableResult public func persist() -> Bool {
        guard loaded else { return false }
        if incremental != nil {
            // Incremental mode: the durable authority is the incremental journal. A whole-archive snapshot here
            // would be exactly the hidden snapshot fallback this wiring must not do, and it would also leave a
            // legacy sessions.json next to the incremental log, which makes the next open refuse to migrate.
            // Any capture-side state that changed is committed through the authoritative journal it produced.
            if let active = activeCapture {
                incrementalFlushCaptureProjection(session: active.session)
                incrementalFlushJournal(session: active.session)
            }
            return incremental?.isAvailable == true && incremental?.isClosing == false && incremental?.status.failureText == nil
        }
        do { archive = try store.save(archive); error = publicationFailureMessage; saved = "已保存并回读确认 · 第 \(archive.generation) 次"; return true }
        catch {
            self.error = "保存失败：\(error.localizedDescription)"; saved = "未保存 · 当前编辑仍在内存，请复制保留"
            if let active = activeCapture { cancelAfterPublicationFailure(attempt: active.attempt) }
            return false
        }
    }
    public func add(demo: Bool) {
        guard loaded, error == nil else { return }
        if incremental != nil && demo { error = "增量模式的新会话不导入静态演示段；本次未创建"; return }
        let session = demo ? LocalSession.demonstration() : LocalSession(title: "新会议")
        archive.sessions.insert(session, at: 0); selection = session.id
        if incremental != nil { incrementalOpenSession(session) } else { persist() }
    }
    public func notes(_ text: String, id: String) {
        guard loaded, let index = archive.sessions.firstIndex(where: { $0.id == id }) else { return }
        guard archive.sessions[index].notes != text else { return }
        archive.sessions[index].editNotes(text); saved = "待保存"
        if incremental != nil {
            // Notes revisions must each be retained; the revision comes from the real noteHistory.
            let revision = archive.sessions[index].noteHistory.last?.revision ?? 0
            incrementalSavingStatus = "正在保存 · 未确认随记 r\(revision)"
            incrementalFlushNotes(session: id)
        } else { persist() }
    }
    public func title(_ text: String, id: String) {
        guard loaded, let index = archive.sessions.firstIndex(where: { $0.id == id }) else { return }
        archive.sessions[index].title = text
        if incremental != nil {
            _ = incremental?.submitMetadata(session: id, title: text, tags: archive.sessions[index].tags)
            incrementalSavingStatus = incremental?.status.failureText ?? "正在保存 · 标题标签等待确认"
        } else { persist() }
    }
    public func tags(_ text: String, id: String) {
        guard loaded, let index = archive.sessions.firstIndex(where: { $0.id == id }) else { return }
        let tags = text.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        archive.sessions[index].tags = tags
        if incremental != nil {
            // Values are the actual user tags, in order, unfiltered beyond the legacy comma split.
            _ = incremental?.submitMetadata(session: id, title: archive.sessions[index].title, tags: tags)
            incrementalSavingStatus = incremental?.status.failureText ?? "正在保存 · 标题标签等待确认"
        } else { persist() }
    }
    public func retry() {
        let previous = publicationFailureMessage
        publicationFailureMessage = captureIngestionFailed ? previous : nil
        if persist(), !captureIngestionFailed { unsavedCaptureText = nil }
        else { publicationFailureMessage = previous ?? error }
    }

    // Explicit incremental persistence, opt-in per instance. nil keeps the existing ArchiveStore path.
    @Published public private(set) var incremental: IncrementalPersistence? = nil
    @Published public private(set) var incrementalSavingStatus = "未启用增量存储"
    /// Item-by-item account of a read-only legacy migration that really ran. It is the caller's record of what
    /// was migrated and, explicitly, what stayed in the untouched original ("未迁移该项").
    @Published public private(set) var incrementalMigrationReport: LegacyMigrationReport?
    /// Non-nil when a legacy archive could not be migrated. The incremental store is then NOT enabled and the
    /// original file is left exactly as it was; no partial migration ever becomes ready.
    @Published public private(set) var incrementalMigrationBlock: String?
    /// Per-session count of authoritative journal wires already handed to the incremental writer.
    var submittedJournalCount: [String: Int] = [:]
    var submittedNotesRevision: [String: Int] = [:]
    var submittedCaptureProjection: [String: LocalCaptureAttempt] = [:]
    var submittedCaptureRevision: [String: UInt64] = [:]
    var submittedPresentations: [String: String] = [:]
    /// Sessions whose typed tombstone record was handed to the incremental ledger.
    var submittedTombstones: Set<String> = []
    /// Attempts whose completed record is durably acknowledged. A controller "completed" is not one of these.
    var incrementalCommittedAttempts: Set<String> = []
    @Published public var rotatingEnabled = true
    @Published public var microphoneEnabled = false
    @Published public var audioInput = "microphone" {
        didSet {
            if oldValue != audioInput, !captureActive { captureStatus = "\(audioInputName)未启动 · 点击开始才采集" }
        }
    }
    @Published public var systemDisplayID: UInt32 = 0
    @Published public var captureStopping = false
    /// No public preflight exists for Core Audio Tap. This is only set after a
    /// minimal tap succeeds; false means "not proven", not necessarily denied.
    @Published public var systemAudioAuthorization = false
    var systemAudioPermissionWatch: Task<Void, Never>?
    var systemAudioCapture: SystemAudioCapture?
    public var audioInputName: String { audioInput == "dual" ? "电脑声音＋麦克风" : (audioInput == "system" ? "电脑声音" : "麦克风") }
    var qwenSecondaryController: QwenSegmentController?
    var dualAudioBackend: SerialQwenBackend?
    var dualFailureHandling = false

    @Published public var recognizerLocale = "zh-CN"
    /// The recogniser the capture path actually runs, recorded into every capture attempt so a session can
    /// explain which engine produced its transcript. It is deliberately **nil by default**: nothing here claims
    /// an engine unless the owner that wires the real backend declares one. A nil value is recorded as
    /// "unrecorded" rather than guessed, so an unknown engine is visible instead of silently assumed.
    @Published public var captureEngineVersion: String?
    @Published public var captureEngineModelVersion: String?
    @Published public var translateFinal = false
    @Published public internal(set) var captureActive = false {
        didSet {
            if captureActive && !oldValue { quickNoteCaptureStartedAt = Date() }
            if !captureActive && oldValue, let start = quickNoteCaptureStartedAt {
                quickNoteLastCaptureDuration = max(0, Date().timeIntervalSince(start))
                quickNoteCaptureStartedAt = nil
            }
        }
    }
    public internal(set) var quickNoteCaptureStartedAt: Date?
    public internal(set) var quickNoteLastCaptureDuration: TimeInterval = 0
    @Published public internal(set) var captureStatus = "麦克风未启动 · 点击开始才请求权限"
    public weak var asrSettings: ASRSettingsModel?
    public let fileBatch = FileBatchModel()
    var qwenController: QwenSegmentController?
    var qwenClientToken = UUID()
    var qwenAttemptIDs: Set<String> = []
    var qwenBinding: QwenSessionBinding?
    var qwenBatchActive = false
    private var publicationFailureMessage: String?
    private var captureIngestionFailed = false
    @Published public internal(set) var unsavedCaptureText: String?
    private var cancellationScheduledForAttempt: String?
    private var activeCapture: (session: String, attempt: String, segment: String)?
    private var outputGeneration: UUID?
    private var activeMode = "finite"
    public let maximumInputFrames = 1_440_000
    public func startCapture() async {
        if let settings = asrSettings, settings.services.usesNetworkASR {
            guard settings.services.contentSendingEnabled else { captureStatus = "请先勾选允许向已配置服务发送声音 / 原文。"; return }
            if audioInput == "dual" { await startQwenDualAudio(settings: settings) }
            else if audioInput == "system" { await startQwenSystemAudio(settings: settings) }
            else { await startQwenMicrophone(settings: settings) }
            return
        }
        if audioInput != "microphone", asrSettings?.loadedProvider?.providerID != .qwen3ASR {
            captureStatus = "电脑声音采集目前需在设置中加载 Qwen 引擎。"; return
        }
        if let settings = asrSettings {
            guard let provider = settings.loadedProvider, let active = settings.activeSelection,
                  let engine = provider.activeEngine else {
                captureStatus = "所选引擎尚未真实加载，无法开始；请在设置中加载。"; return
            }
            if engine.providerID == .qwen3ASR { if audioInput == "dual" { await startQwenDualAudio(settings: settings) }
                else if audioInput == "system" { await startQwenSystemAudio(settings: settings) }
                else { await startQwenMicrophone(settings: settings) }; return }
            guard active.providerID == "apple-speech-on-device" else { return }
            qwenController = nil
            recognizerLocale = active.locale
            captureEngineVersion = engine.engineVersion; captureEngineModelVersion = engine.modelVersion
        }
        guard let id = selection else { return }
        if rotatingEnabled {
            await startCapture(configuration: RotatingSpeechConfiguration(sessionId: id, channelId: "mic", source: .microphone,
                locale: OfflineSpeechLocale(rawValue: recognizerLocale) ?? .simplifiedChinese,
                maximumInputFrames: maximumInputFrames))
            return
        }
        let token = UUID().uuidString
        let c = LiveSpeechConfiguration(sessionId: id, channelId: "mic", streamId: "mic-" + token,
            segmentId: "segment-" + token, source: .microphone,
            locale: OfflineSpeechLocale(rawValue: recognizerLocale) ?? .simplifiedChinese,
            maximumInputFrames: maximumInputFrames)
        await startCapture(configuration: c)
    }
    /// Also used by synthetic QA with injected controller ports; the UI uses the same lifecycle.
    public func startCapture(configuration c: LiveSpeechConfiguration) async {
        guard incremental == nil else {
            captureStatus = "增量接线仅支持 rotating；有限模式未开始"; return
        }
        guard loaded, error == nil, microphoneEnabled, !captureActive, activeCapture == nil, selection == c.sessionId,
              let index = archive.sessions.firstIndex(where: { $0.id == c.sessionId }) else { return }
        let attempt = UUID().uuidString
        activeCapture = (c.sessionId, attempt, c.segmentId); captureActive = true
        installCaptureCallbacks(attempt: attempt, mode: "finite")
        archive.sessions[index].captureAttempts.append(LocalCaptureAttempt(id: attempt, channelID: c.channelId,
            streamID: c.streamId, segmentID: c.segmentId, locale: c.locale.rawValue,
            engineVersion: captureEngineVersion, modelVersion: captureEngineModelVersion))
        guard persist() else { captureActive = false; activeCapture = nil; return }
        do {
            try await captureController.userPressedStart(intent: DesktopStartIntent(userInitiated: true,
                microphoneEnabled: microphoneEnabled, speechEnabled: true, onDeviceProcessingAuthorized: true), configuration: c)
        } catch {
            captureStatus = "采集无法开始：\(error)"
            // A pre-generation abort emits no raw terminal. Legacy state was synchronously saved by the callback.
            // Keep the incremental durability gate; only the default path releases this non-started attempt here.
            if incremental == nil, activeCapture?.attempt == attempt, !captureActive, outputGeneration == nil { activeCapture = nil }
            // The controller status callback persists the exact failure before throwing.
        }
    }
    public func startCapture(configuration c: RotatingSpeechConfiguration) async {
        guard loaded, error == nil, microphoneEnabled, !captureActive, activeCapture == nil, selection == c.sessionId,
              let index = archive.sessions.firstIndex(where: { $0.id == c.sessionId }) else { return }
        let attempt = UUID().uuidString
        activeCapture = (c.sessionId, attempt, ""); captureActive = true
        installCaptureCallbacks(attempt: attempt, mode: "rotating")
        var metadata = LocalCaptureAttempt(id: attempt, channelID: c.channelId, streamID: "", segmentID: "", locale: c.locale.rawValue,
                                           engineVersion: captureEngineVersion, modelVersion: captureEngineModelVersion)
        metadata.mode = "rotating"; metadata.tasks = []
        archive.sessions[index].captureAttempts.append(metadata)
        guard persist() else { captureActive = false; activeCapture = nil; return }
        do {
            try await captureController.userPressedStart(intent: DesktopStartIntent(userInitiated: true,
                microphoneEnabled: microphoneEnabled, speechEnabled: true, onDeviceProcessingAuthorized: true), configuration: c)
        } catch {
            captureStatus = "采集无法开始：\(error)"
            if incremental == nil, activeCapture?.attempt == attempt, !captureActive, outputGeneration == nil { activeCapture = nil }
        }
    }
    private func installCaptureCallbacks(attempt: String, mode: String) {
        activeMode = mode; outputGeneration = nil
        captureController.onStateChange = { [weak self] snapshot in
            guard let self, self.activeCapture?.attempt == attempt else { return }
            self.captureStateChanged(snapshot)
        }
        captureController.onLiveOutput = { [weak self] output in
            guard let self, self.activeCapture?.attempt == attempt, self.activeMode == "finite" else { return }
            self.captureOutput(output)
        }
        captureController.onCanonicalOutput = { [weak self] output in
            guard let self, self.activeCapture?.attempt == attempt, self.activeMode == "rotating" else { return }
            self.canonicalOutput(output)
        }
        captureController.onRotatingOutput = { [weak self] output in
            guard let self, self.activeCapture?.attempt == attempt, self.activeMode == "rotating" else { return }
            self.rotatingOutput(output)
        }
    }
    public func stopCapture() {
        if qwenSecondaryController != nil, captureActive { stopDualAudio(); return }
        if let qwenController, captureActive {
            guard !captureStopping else { return }
            captureStopping = true
            let stopToken = qwenClientToken
            Task {
                defer { if self.qwenClientToken == stopToken { self.captureStopping = false } }

                do {
                    if let system = self.systemAudioCapture {
                        system.onStateChange = nil
                        try await system.stop()
                        guard self.qwenClientToken == stopToken else { return }
                        self.systemAudioCapture = nil
                    }
                    try await qwenController.stopAndDrain()
                    guard self.qwenClientToken == stopToken else { return }
                    try await self.finishQwenAttempts(lifecycle: "completed", failure: nil)
                    self.captureActive = false; self.asrSettings?.captureActive = false
                    self.captureStatus = qwenController.deliveredSegments == 0
                        ? "Qwen 已结束 · 未识别到语音，未新增原文；终态已保存确认"
                        : "Qwen 已结束 · final 与终态已保存确认"
                } catch {
                    // The failure callback owns its durable terminal and reload guidance.
                    if case .failed = qwenController.state { return }
                    if qwenController.state == .cancelled { return }
                    self.captureStatus = "Qwen 停止失败：\(error)"
                }
            }
            return
        }
        do { try captureController.userPressedStop() } catch { captureStatus = "停止失败：\(error)" }
    }
    public func cancelCapture() {
        if qwenSecondaryController != nil, captureActive { cancelDualAudio(); return }
        if (qwenController != nil || qwenBatchActive) && captureActive { cancelQwen(); return }
        do { try captureController.userPressedCancel() } catch { captureStatus = "取消失败：\(error)" }
    }
    private func cancelAfterPublicationFailure(attempt: String) {
        publicationFailureMessage = publicationFailureMessage ?? error
        guard cancellationScheduledForAttempt != attempt else { return }
        cancellationScheduledForAttempt = attempt
        // Controller callbacks reject reentrant lifecycle calls. A queued MainActor task runs after delivery returns.
        Task { @MainActor [weak self] in
            guard let self, self.activeCapture?.attempt == attempt else { return }
            self.cancelCapture()
            if self.cancellationScheduledForAttempt == attempt { self.cancellationScheduledForAttempt = nil }
        }
    }
    private func captureStateChanged(_ snapshot: DesktopSessionSnapshot) {
        guard let active = activeCapture,
              let index = archive.sessions.firstIndex(where: { $0.id == active.session }),
              let attemptIndex = archive.sessions[index].captureAttempts.firstIndex(where: { $0.id == active.attempt }) else { return }
        var attempt = archive.sessions[index].captureAttempts[attemptIndex]
        let lifecycle: String, failure: String?, pipeline: String
        switch snapshot.state {
        case .idle: lifecycle = "idle"; failure = nil; pipeline = "stopped"
        case .requestingPermissions: lifecycle = "requestingPermissions"; failure = nil; pipeline = "recovering"
        case .capturing: lifecycle = "capturing"; failure = nil; pipeline = "recovering"
        case .stopping: lifecycle = "stopping"; failure = nil; pipeline = "recovering"
        case .terminal(let state):
            switch state {
            case .completed: lifecycle = "completed"; failure = nil
            case .cancelled: lifecycle = "cancelled"; failure = nil
            case .incomplete(let reason): lifecycle = "incomplete"; failure = String(describing: reason)
            default: lifecycle = "incomplete"; failure = String(describing: state)
            }
            pipeline = lifecycle == "incomplete" ? "interrupted" : "stopped"
            captureActive = false
        case .failed(let reason): lifecycle = "incomplete"; failure = String(describing: reason); pipeline = "interrupted"; captureActive = false
        }
        // Incremental mode: a controller terminal is not a successful save. Only an actual failure marks capture
        // failed here; the rotating raw terminal and terminalCoverage arrive through their own callbacks, and
        // activeCapture stays held until the completed barrier confirms text + associations + coverage + completed.
        // A controller "completed" therefore stays presented as "stopping" until the durable completed is acked.
        let durablePending = incremental != nil && lifecycle == "completed" && !incrementalCommittedAttempts.contains(active.attempt)
        let actualLifecycle = durablePending ? "stopping" : lifecycle
        let actualFailure = durablePending ? nil : failure
        if incremental != nil, let active = activeCapture,
           lifecycle == "incomplete" { incrementalCaptureFailed(attempt: active.attempt, reason: failure ?? "controller_incomplete") }
        // A queued publication failure cancellation must remain incomplete, even if raw owner says cancelled.
        if publicationFailureMessage != nil {
            attempt.lifecycle = "incomplete"; attempt.failure = "publication_failure"
            attempt.history.append("incomplete:publication_failure")
            archive.sessions[index].captureAttempts[attemptIndex] = attempt
            captureStatus = "incomplete · publication_failure · 原文保留"
            if !persist() { cancelAfterPublicationFailure(attempt: active.attempt) }
            return
        }
        let changed = attempt.lifecycle != actualLifecycle || attempt.failure != actualFailure
        attempt.lifecycle = actualLifecycle; attempt.failure = actualFailure
        attempt.deviceStarted = snapshot.deviceStarted; attempt.audioObserved = snapshot.audioObserved; attempt.asrObserved = snapshot.asrObserved
        if changed { attempt.history.append(actualLifecycle + (actualFailure.map { ":" + $0 } ?? "")) }
        archive.sessions[index].captureAttempts[attemptIndex] = attempt
        do {
            if changed {
                var c = try coordinator(archive.sessions[index])
                try c.captureLifecycle(channelID: attempt.channelID, state: pipeline, failure: actualFailure)
                c.project(into: &archive.sessions[index]); coordinators[active.session] = c
            }
            captureStatus = "\(actualLifecycle) · 设备启动 \(snapshot.deviceStarted) · 音频观察 \(snapshot.audioObserved) · ASR观察 \(snapshot.asrObserved)" + (actualFailure.map { " · " + $0 } ?? "")
            if !persist() { cancelAfterPublicationFailure(attempt: active.attempt) }
        } catch { self.error = "采集状态保存失败：\(error)"; cancelAfterPublicationFailure(attempt: active.attempt) }
    }
    private func acceptGeneration(_ id: UUID) -> Bool {
        if let outputGeneration { return outputGeneration == id }
        outputGeneration = id
        // The attempt fence uses the rotating session's real generation id; nothing is invented here.
        // Incremental mode begins the attempt before any canonical/transcript revision is submitted.
        if incremental != nil, activeMode == "rotating", let active = activeCapture {
            incrementalBeginAttempt(session: active.session, attempt: active.attempt, generation: id,
                                    requiresTerminalCoverage: true)
        }
        return true
    }
    private func captureOutput(_ output: LiveSpeechOutput) {
        guard let active = activeCapture else { return }
        switch output {
        case .transcript(let generation, let update):
            guard acceptGeneration(generation.id), update.segmentId == active.segment else { return }
            ingestCapture(update, generation: generation.id)
        case .terminal(let generation, _):
            guard acceptGeneration(generation.id) else { return }
            activeCapture = nil
        }
    }
    private func registerTask(stream: String, segment: String, generation: UUID, observedBy: String, final: Bool = false) throws {
        guard let active = activeCapture,
              let i = archive.sessions.firstIndex(where: { $0.id == active.session }),
              let j = archive.sessions[i].captureAttempts.firstIndex(where: { $0.id == active.attempt }) else { return }
        var attempt = archive.sessions[i].captureAttempts[j]
        if let previous = attempt.generationID, previous != generation.uuidString {
            throw NSError(domain: "Capture", code: 2, userInfo: [NSLocalizedDescriptionKey: "GENERATION_MISMATCH"])
        }
        attempt.generationID = generation.uuidString; attempt.mode = activeMode
        var tasks = attempt.tasks ?? []
        if let k = tasks.firstIndex(where: { $0.streamID == stream || $0.segmentID == segment }) {
            guard tasks[k].streamID == stream, tasks[k].segmentID == segment else {
                throw NSError(domain: "Capture", code: 3, userInfo: [NSLocalizedDescriptionKey: "TASK_IDENTITY_MISMATCH"])
            }
            if final { tasks[k].finalObserved = true }
        } else {
            var task = LocalCaptureTask(streamID: stream, segmentID: segment, firstObservedBy: observedBy)
            task.finalObserved = final; tasks.append(task)
        }
        // Legacy fields remain the first actual identity, never an invented task.
        if attempt.streamID.isEmpty { attempt.streamID = stream; attempt.segmentID = segment }
        attempt.tasks = tasks
        archive.sessions[i].captureAttempts[j] = attempt
    }
    private func ingestCapture(_ update: OfflineTranscriptUpdate, generation: UUID) {
        guard let active = activeCapture, update.sessionId == active.session,
              let index = archive.sessions.firstIndex(where: { $0.id == active.session }),
              archive.sessions[index].captureAttempts.last?.channelID == update.channelId else { return }
        do {
            var c = try coordinator(archive.sessions[index])
            guard try c.ingest(update) != nil else { return }
            try registerTask(stream: update.streamId, segment: update.segmentId, generation: generation,
                             observedBy: "transcript", final: update.status == "final")
            c.project(into: &archive.sessions[index]); coordinators[active.session] = c
            // Incremental mode never falls back to a whole-archive save; the durable record is the incremental one.
            guard incrementalCaptureCommit(session: active.session) else {
                unsavedCaptureText = update.text; cancelAfterPublicationFailure(attempt: active.attempt); return
            }
            if update.status == "final", translateFinal { translateSegment(sessionID: active.session, segmentID: update.segmentId) }
        } catch {
            captureIngestionFailed = true; unsavedCaptureText = update.text
            self.error = "转写保存失败：\(error)"; cancelAfterPublicationFailure(attempt: active.attempt)
        }
    }
    private func canonicalOutput(_ output: RotatingCanonicalOutput) {
        guard let active = activeCapture,
              let i = archive.sessions.firstIndex(where: { $0.id == active.session }),
              let j = archive.sessions[i].captureAttempts.firstIndex(where: { $0.id == active.attempt }) else { return }
        let generation: RotatingSpeechGeneration
        switch output {
        case .mapped(let g, _, _), .associated(let g, _), .settled(let g, _, _, _, _, _, _, _), .terminalCoverage(let g, _): generation = g
        }
        guard acceptGeneration(generation.id) else { return }
        var attempt = archive.sessions[i].captureAttempts[j]
        guard attempt.generationID == nil || attempt.generationID == generation.id.uuidString else { return }
        attempt.generationID = generation.id.uuidString
        var metadata = attempt.canonicalMetadata ?? LocalCanonicalMetadata()
        switch output {
        case .mapped(_, let id, let block):
            let value = LocalCanonicalBlock(id: id, block: block)
            if !metadata.blocks.contains(value) { metadata.blocks.append(value) }
        case .associated(_, let span):
            // Identity association is available before synchronous ASR; no transcript or seq is invented.
            let value = LocalTaskCanonicalSpan(span)
            if !metadata.associations.contains(value) { metadata.associations.append(value) }
        case .settled(_, let id, let disposition, let timestamp, let range, let accepted, let returned, let failure):
            let value = LocalCanonicalSettlement(id: id, disposition: disposition, timestamp: timestamp, range: range,
                backendAccepted: accepted, ownerReturned: returned, failure: failure)
            if !metadata.settlements.contains(value) { metadata.settlements.append(value) }
        case .terminalCoverage(_, let coverage): metadata.terminalCoverage = LocalCanonicalCoverage(coverage)
        }
        guard attempt.canonicalMetadata != metadata else { return }
        attempt.canonicalMetadata = metadata
        archive.sessions[i].captureAttempts[j] = attempt
        if incremental != nil {
            // The real canonical observation is submitted with the attempt's actual generation fence.
            // terminalCoverage in particular is durable before the controller's raw terminal delivery.
            incrementalFlushCaptureProjection(session: active.session)
            incrementalSubmitCanonical(session: active.session, attempt: active.attempt,
                                       generation: generation.id, output: output)
            if let failure = incremental?.status.failureText { incrementalSavingStatus = failure }
        } else if !persist() { cancelAfterPublicationFailure(attempt: active.attempt) }
    }
    private func rotatingOutput(_ output: RotatingSpeechOutput) {
        guard let active = activeCapture else { return }
        switch output {
        case .transcript(let generation, let update):
            guard acceptGeneration(generation.id) else { return }
            ingestCapture(update, generation: generation.id)
        case .dispatched(let generation, let task, let timestamp, let range):
            guard acceptGeneration(generation.id),
                  let index = archive.sessions.firstIndex(where: { $0.id == active.session }),
                  let attempt = archive.sessions[index].captureAttempts.first(where: { $0.id == active.attempt }) else { return }
            do {
                try registerTask(stream: task.streamId, segment: task.segmentId, generation: generation.id, observedBy: "dispatched")
                if let j = archive.sessions[index].captureAttempts.firstIndex(where: { $0.id == active.attempt }),
                   let k = archive.sessions[index].captureAttempts[j].tasks?.firstIndex(where: { $0.segmentID == task.segmentId }) {
                    let block = LocalCaptureBlock(frameStart: range.frameStart, frameEnd: range.frameEnd, mappingRevision: range.mappingRevision,
                        startNS: String(range.startNs), endNS: String(range.endNs), hostSeconds: timestamp.hostSeconds,
                        samplePosition: timestamp.samplePosition, sampleRate: timestamp.sampleRate,
                        presentationSeconds: timestamp.presentationSeconds, receivedUptime: timestamp.receivedUptime)
                    var blocks = archive.sessions[index].captureAttempts[j].tasks![k].sourceBlocks ?? []
                    if !blocks.contains(block) { blocks.append(block) }
                    archive.sessions[index].captureAttempts[j].tasks![k].sourceBlocks = blocks
                }
                var c = try coordinator(archive.sessions[index])
                try c.registerStream(channelID: attempt.channelID, streamID: task.streamId)
                c.project(into: &archive.sessions[index]); coordinators[active.session] = c
                if incremental != nil {
                    // The task-to-canonical binding itself is local state; its durable form arrives through the
                    // canonical `.associated` observation. Here only the pending authoritative journal is flushed.
                    if !incrementalCaptureCommit(session: active.session) { cancelAfterPublicationFailure(attempt: active.attempt) }
                } else if !persist() { cancelAfterPublicationFailure(attempt: active.attempt) }
            } catch { self.error = "流注册失败：\(error)"; cancelAfterPublicationFailure(attempt: active.attempt) }
        case .terminal(let generation, _):
            guard acceptGeneration(generation.id) else { return }
            // Snapshot already persisted the real drained/all-finals terminal; task finals never complete an attempt.
            if incremental != nil {
                // Raw terminal only enters "saving": the attempt is released by the completed barrier callback,
                // after text + associations + terminalCoverage + completed are all acknowledged.
                incrementalRawTerminal(attempt: active.attempt)
            } else {
                activeCapture = nil
            }
        }
    }
}

// Explicit incremental persistence wiring. Legacy ArchiveStore remains the default path; enabling this does
// not silently fall back to a whole-archive save and never migrates a legacy file.
@MainActor public extension ClientModel {
    /// Incremental records live in their own directory next to the legacy file. They must not share the directory
    /// that holds sessions.json: the incremental writer refuses to bootstrap when a legacy archive sits beside it,
    /// and a legacy save would otherwise sit next to (and be mistaken for) the durable incremental log.
    var incrementalDataDirectory: URL {
        store.fileURL.deletingLastPathComponent().appendingPathComponent("incremental", isDirectory: true)
    }
    var incrementalReady: Bool { incremental?.canSubmit == true && incremental?.status.failureText == nil }
    var hasUnconfirmedIncrementalWork: Bool { incremental?.hasUnconfirmedWork == true }

    /// Explicit opt-in used by the App when `MEETING_COPILOT_INCREMENTAL=1` is set. It reads the real text-mode
    /// config when present, and never silently enables the incremental store on a legacy archive.
    public func enableIncrementalOnLaunch() async {
        guard incremental == nil else { return }
        let limits: CoreLimits
        if let configURL, let config = try? TextModeConfig.load(configURL), let core = try? config.coreLimits() { limits = core }
        else { do { limits = try CoreLimits(maxBufferedEvents: 32, maxBufferedBytes: 262_144, reorderTimeoutMs: 2000, recoveryTimeoutMs: 5000) } catch { return } }
        _ = await enableIncrementalPersistence(limits: limits)
    }

    func enableIncrementalPersistence(limits: CoreLimits, budget: BridgeLimits = BridgeLimits(),
                                      fault: (@Sendable (ArchiveFaultPoint) throws -> Void)? = nil) async -> Bool {
        guard incremental == nil else { return incrementalReady }
        let legacyURL = store.fileURL
        let legacyExists = await Task.detached { FileManager.default.fileExists(atPath: legacyURL.path) }.value
        // A legacy `sessions.json` is migrated into the incremental store READ-ONLY: the original is never
        // written, renamed or removed, and a refusal or a partial migration never becomes ready.
        var legacySetup: LegacyMigrationSetup?
        if legacyExists {
            let setup = await incrementalLegacySetup(legacyURL: legacyURL, limits: limits)
            if let refusal = setup.refusal {
                incrementalMigrationBlock = refusal
                incrementalSavingStatus = "旧档未迁移 · 未启用增量存储 · 原档未改动：\(refusal)"
                return false
            }
            legacySetup = setup
        } else {
            guard archive.sessions.allSatisfy({ $0.speechJournal.isEmpty && $0.segments.isEmpty
                && $0.noteHistory.isEmpty && $0.materials.isEmpty && $0.captureAttempts.isEmpty }) else {
                incrementalSavingStatus = "已有数据缺完整 typed bootstrap；增量子集未启用"
                return false
            }
        }
        let persistence = IncrementalPersistence(directory: incrementalDataDirectory, limits: limits, budget: budget, fault: fault)
        // The close gate needs the caller's real held-back content: counts, unresolved caller failure and a
        // bounded drain that re-submits every session before the closing gate is set.
        persistence.callerPendingProvider = { [weak self] in self?.incrementalCloseReadiness() ?? IncrementalPersistence.CallerPending() }
        persistence.callerDrainForClose = { [weak self] in await self?.incrementalDrainCallerForClose() }
        persistence.onFailure = { [weak self] reason in
            guard let self else { return }
            self.incrementalSavingStatus = "未保存 · \(reason)（全部未确认修订保留）"
            self.error = "增量保存失败，写入已停止，编辑仍在内存：\(reason)"
            if let active = self.activeCapture { self.cancelAfterPublicationFailure(attempt: active.attempt) }
        }
        persistence.onAcknowledged = { [weak self] head in
            guard let self, let p = self.incremental else { return }
            self.incrementalSavingStatus = p.userStatus(head: head)
        }
        persistence.onAttemptTerminalCommitted = { [weak self] attempt in            guard let self else { return }
            let completed = self.incremental?.projection?.sessions.values.contains { session in
                session.attempts.contains { $0.key.attemptID == attempt && $0.value.outcome == .completed }
            } == true
            if completed { self.incrementalCommittedAttempts.insert(attempt) }
            if completed, let i = self.archive.sessions.firstIndex(where: { $0.captureAttempts.contains { $0.id == attempt } }),
               let j = self.archive.sessions[i].captureAttempts.firstIndex(where: { $0.id == attempt }) {
                self.archive.sessions[i].captureAttempts[j].lifecycle = "completed"
                self.archive.sessions[i].captureAttempts[j].failure = nil
                self.archive.sessions[i].captureAttempts[j].history.append("completed:incremental_confirmed")
                self.submittedCaptureProjection[attempt] = self.archive.sessions[i].captureAttempts[j]
                self.submittedCaptureRevision[attempt] = (self.submittedCaptureRevision[attempt] ?? 0) + 1
            }
            if self.activeCapture?.attempt == attempt {
                self.activeCapture = nil; self.captureActive = false
                self.unsavedCaptureText = nil
                self.captureStatus = completed ? "已保存并确认完成 · 采集已结束" : "终态记录已保存 · 原取消/失败状态保留"
            }
        }
        await persistence.start()
        guard persistence.isAvailable else {
            incrementalSavingStatus = "增量存储不可用"
            return false
        }
        if let setup = legacySetup {
            if setup.needsSubmission, let plan = setup.plan {
                do {
                    // Real writer/ledger submissions, a real durability barrier, a re-read of the original's
                    // bytes+mtime+inode and an item-by-item readback against the acknowledged projection.
                    // Sessions already durable and verified are passed as `skipping`, never re-submitted.
                    let report = try await incrementalRunLegacyMigration(setup, plan: plan, persistence: persistence,
                                                                        skipping: setup.alreadyDurable)
                    incrementalMigrationReport = report
                    incrementalSavingStatus = legacyMigrationStatusText(report, alreadyVerified: !setup.isFresh)
                } catch {
                    // Not ready on a partial migration and never ready on a mismatch. The keys already written
                    // stay on disk; a retry re-plans, verifies what exists and completes only what is missing.
                    incrementalMigrationBlock = String(describing: error)
                    incrementalSavingStatus = "旧档迁移未完成 · 未启用增量存储 · 原档未改动：\(error)"
                    return false
                }
            } else if let plan = setup.plan {
                var report = plan.report
                report.alreadyMigratedSessions = plan.expectedOrder
                incrementalMigrationReport = report
                incrementalSavingStatus = legacyMigrationStatusText(report, alreadyVerified: true)
            }
        }
        incremental = persistence
        if legacySetup == nil { incrementalSavingStatus = "增量存储就绪 · 等待首次写入" }
        // Every already-loaded session must have its real sessionOpened record before any scoped revision.
        if let projection = persistence.projection, !projection.sessions.isEmpty {
            do {
                let restored = try await Task.detached { try LocalArchiveProjection.archive(projection) }.value
                // Same rule as the whole-archive reopen above: selection is a LIVE session only, with no
                // fallback to a deleted one, since a tombstoned session is still present in `restored.sessions`.
                archive = restored; selection = restored.activeSessions.first?.id; coordinators.removeAll()
                for session in restored.sessions {
                    submittedJournalCount[session.id] = session.speechJournal.count
                    submittedNotesRevision[session.id] = session.noteHistory.last?.revision ?? 0
                    for attempt in session.captureAttempts {
                        submittedCaptureProjection[attempt.id] = attempt
                        submittedCaptureRevision[attempt.id] = projection.sessions[session.id]?.captures[attempt.id]?.stateRevision
                    }
                    for segment in session.segments {
                        submittedPresentations["\(session.id):\(segment.id)"] = segment.current?.sourceLanguage.map { "value:\($0)" } ?? "nil"
                    }
                }
            } catch {
                persistence.markLocalFailure("完整typed投影重开失败：\(error)")
                return false
            }
        } else if legacySetup == nil {
            for session in archive.sessions.reversed() { incrementalOpenSession(session) }
        }
        return incrementalReady
    }
    /// Caller-side readiness for a real close. Counts what this model still holds back from the writer and
    /// reports an unresolved caller-side failure. It is a report, not a durability proof: only ledger ack/fsync is.
    public func incrementalCloseReadiness() -> IncrementalPersistence.CallerPending {
        var pending = IncrementalPersistence.CallerPending()
        guard incremental != nil else { return pending }
        // Only a LIVE translation can still produce a result whose durability is outstanding. A cancelled one is
        // already decided (its output can no longer be accepted), so it is reported but never blocks a close.
        pending.activeTranslations = pendingTranslationCount
        pending.cancelledTranslations = cancelledTranslationCount
        for session in archive.sessions {
            // A session with no durable opening record at all is caller-side pending even if it currently holds
            // no notes/wires: nothing about it can be reopened yet.
            if incremental?.projection?.sessions[session.id] == nil { pending.unopenedSessions += 1 }
            var row = IncrementalPersistence.CallerPending.Session()
            let submittedNotes = submittedNotesRevision[session.id] ?? Int(incremental?.projection?.sessions[session.id]?.notes.last?.revision ?? 0)
            row.notesVersions = session.noteHistory.filter { $0.revision > submittedNotes }.count
            let submittedJournal = submittedJournalCount[session.id] ?? 0
            row.journalWires = max(0, session.speechJournal.count - submittedJournal)
            for attempt in session.captureAttempts where submittedCaptureProjection[attempt.id] != attempt { row.captureStates += 1 }
            // A tombstone that is only in memory (or whose ack has not landed) is still caller-side pending.
            let durableTombstone = incremental?.projection?.sessions[session.id]?.tombstone
            if session.isDeleted && durableTombstone == nil { row.tombstones += 1 }
            for segment in session.segments {
                let language = segment.current?.sourceLanguage
                let signature = language.map { "value:\($0)" } ?? "nil"
                if submittedPresentations["\(session.id):\(segment.id)"] != signature { row.presentations += 1 }
            }
            // A material whose chunks are not all durable yet is caller-side pending: partial text in memory is
            // never reported as a saved material.
            for material in session.materials {
                let durable = incremental?.projection?.sessions[session.id]?.materials[material.id]
                if durable?.complete != true { row.materials += 1 }
            }
            // Title/tags are real user revisions too: a rejected metadata submission stays caller-side pending.
            if let durable = incremental?.projection?.sessions[session.id] {
                if durable.title != session.title || durable.tags != session.tags { row.metadataVersions += 1 }
            }
            if row.total > 0 { pending.sessions[session.id] = row }
        }
        // An unretired capture is caller-side pending work: its transcript/coverage/terminal is not yet durable.
        pending.capturePending = incremental?.openAttemptCount != 0
        pending.unresolvedFailure = incremental?.callerBlockingFailure
        return pending
    }
    /// Re-submits every session's held-back notes/journal/capture/presentation so the close preflight can reach
    /// a real zero. Only enqueues; acks still arrive through the normal ledger.
    func incrementalDrainCallerForClose() async {
        for session in archive.sessions { incrementalOpenSession(session) }
        for session in archive.sessions { incrementalFlushNotes(session: session.id) }
        for session in archive.sessions { incrementalFlushTombstone(session: session.id) }
        for session in archive.sessions { incrementalFlushMaterials(session: session.id) }
        for session in archive.sessions {
            incrementalFlushCaptureProjection(session: session.id)
            incrementalFlushJournal(session: session.id)
        }
    }
    /// Re-submits a held-back deletion record. A session that already has a durable tombstone is skipped, so the
    /// retry is idempotent instead of being refused as a duplicate.
    func incrementalFlushTombstone(session: String) {
        guard let persistence = incremental, let local = archive.sessions.first(where: { $0.id == session }),
              let record = local.tombstone else { return }
        guard persistence.projection?.sessions[session]?.tombstone == nil else { return }
        if persistence.submitTombstone(session: session, record: record) { submittedTombstones.insert(session) }
    }
    /// Termination-barrier close. Returns false (and keeps the window) unless the store really reached zero
    /// unconfirmed revisions, zero caller-held content, no unresolved caller failure and no open capture.
    func closeIncrementalPersistence() async -> (closed: Bool, reason: String?) {
        guard let persistence = incremental else { return (true, nil) }
        // Product semantics for termination: a translation that has not produced a result yet is cancelled; a
        // result already accepted and projected stays durable through its authoritative journal and is drained below.
        cancelInFlightTranslations()
        let result = await persistence.close()
        incrementalSavingStatus = result.closed
            ? "增量存储已关闭 · 全部修订已确认"
            : "未关闭 · \(result.unconfirmed) 项未确认（\(result.reason ?? "未知")），窗口保留，可重试"
        return (result.closed, result.reason)
    }
    /// App termination barrier. If a capture is still live, it is really cancelled first and the gate waits for
    /// the acknowledged cancel/failure terminal record; it never treats `captureActive == false` as terminal
    /// evidence and it never closes the store before every caller-side revision is drained or explicitly refused.
    public func prepareForTermination() async -> (ready: Bool, reason: String?) {
        guard let persistence = incremental else { return (true, nil) }
        if activeCapture != nil || captureActive { cancelCapture() }
        // Wait for the real terminal record to be acknowledged (bounded); a timeout stays an explicit failure.
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while activeCapture != nil {
            if ProcessInfo.processInfo.systemUptime >= deadline {
                return (false, "采集终态未在限期内确认，未关闭存储；窗口保留，可重试")
            }
            _ = try? await persistence.awaitQuiescence()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let result = await closeIncrementalPersistence()
        return (result.closed, result.reason)
    }
    /// Retry uses the same stable IDs and content; a conflict stays visible and is never silently skipped.
    func retryIncrementalPersistence() {
        incremental?.retryUnconfirmed()
        for session in archive.sessions {
            incrementalFlushNotes(session: session.id)
            incrementalFlushJournal(session: session.id)
        }
        incrementalSavingStatus = incremental.map { $0.userStatus(head: $0.lastConfirmedHead) } ?? incrementalSavingStatus
    }
    /// A capture-side commit that never falls back to a whole-archive snapshot in incremental mode.
    /// Returns false only when a real, already-visible failure means capture must stop.
    func incrementalCaptureCommit(session: String) -> Bool {
        guard incremental != nil else { return persist() }
        guard incremental?.isAvailable == true, incremental?.isClosing == false else { return false }
        // The controller/coordinator state itself stays in memory; only the authoritative journal wire is durable.
        incrementalFlushCaptureProjection(session: session)
        incrementalFlushJournal(session: session)
        return incremental?.status.failureText == nil
    }
    func incrementalFlushNotes(session: String) {
        guard let p = incremental, let local = archive.sessions.first(where: { $0.id == session }) else { return }
        let submitted = submittedNotesRevision[session] ?? Int(p.projection?.sessions[session]?.notes.last?.revision ?? 0)
        for note in local.noteHistory where note.revision > submitted {
            guard p.submitNoteVersion(session: session, note: note) else { return }
            submittedNotesRevision[session] = note.revision
        }
    }
    /// Hands every authoritative journal wire not yet submitted to the incremental writer, in real order.
    func incrementalFlushJournal(session: String) {
        guard let persistence = incremental,
              let index = archive.sessions.firstIndex(where: { $0.id == session }) else { return }
        let journal = archive.sessions[index].speechJournal
        let submitted = submittedJournalCount[session] ?? 0
        if journal.count > submitted {
            for offset in submitted..<journal.count {
                let data = journal[offset]
                let fence: ArchiveFence
                if let active = activeCapture, active.session == session, let generation = outputGeneration {
                    fence = ArchiveFence(sessionID: session, attemptID: active.attempt, generationID: generation)
                } else { fence = ArchiveFence(sessionID: session) }
                guard persistence.submitWire(session: session, fence: fence, wire: data, sequence: offset + 1) else {
                    persistence.noteJournalBacklog(session: session, remaining: journal.count - offset)
                    return
                }
                submittedJournalCount[session] = offset + 1
            }
        }
        // Completion waits until this is zero, so an attempt is never declared complete with wires still held back.
        persistence.noteJournalBacklog(session: session, remaining: max(0, journal.count - (submittedJournalCount[session] ?? 0)))
        incrementalFlushPresentations(session: session)
        incrementalSavingStatus = persistence.userStatus(head: persistence.lastConfirmedHead)
    }
    /// Material chunks are only split when the incremental store is really the durable path. The default path
    /// keeps its existing single-file behaviour; nothing about `importMaterial()`'s reader or 2 MiB cap changes.
    func incrementalMaterialChunks(session: String, material: LocalMaterial) -> [IncrementalPersistence.MaterialChunk] {
        IncrementalPersistence.materialChunks(id: material.id, fileName: material.fileName, text: material.text,
            sha256: material.sha256, importedAtReferenceBits: material.importedAt.timeIntervalSinceReferenceDate.bitPattern)
    }
    /// Submits the material's chunks in order. Only a fully admitted material reports success; a chunk the
    /// ledger or bridge refuses stops the rest and keeps the remaining chunks caller-side pending.
    func incrementalSubmitMaterial(session: String, chunks: [IncrementalPersistence.MaterialChunk]) -> Bool {
        guard let persistence = incremental, !chunks.isEmpty else { return false }
        let submittedBefore = persistence.submittedMaterialChunks["\(session):\(chunks[0].materialID)"] ?? []
        for chunk in chunks where !submittedBefore.contains(chunk.chunkIndex) {
            guard persistence.submitMaterialChunk(session: session, chunk: chunk) else { return false }
        }
        return true
    }
    /// Re-submits a held-back material whose chunks never all landed. A chunk already handed to the ledger is
    /// never submitted twice (the writer would refuse a duplicate index anyway); a material already complete
    /// durably is skipped, so the retry is idempotent instead of a spurious duplicate.
    func incrementalFlushMaterials(session: String) {
        guard let persistence = incremental,
              let local = archive.sessions.first(where: { $0.id == session }) else { return }
        for material in local.materials {
            if let durable = persistence.durableMaterialChunks(session: session, materialID: material.id),
               durable.received == durable.total { continue }
            _ = incrementalSubmitMaterial(session: session, chunks: incrementalMaterialChunks(session: session, material: material))
        }
    }
    /// An incremental store can only refuse a material for a real reason (unavailable store, or a chunk that
    /// the ledger could never admit). Silence is never a refusal: the message always names the reason.
    func incrementalMaterialRefusal(session: String) -> String? {
        guard let persistence = incremental else { return nil }
        if !persistence.isAvailable { return "增量存储不可用（\(persistence.status.failureText ?? "未知原因")），本次未导入，未声称已保存" }
        if persistence.isClosing || persistence.isClosed { return "增量存储正在关闭或已关闭，本次未导入，未声称已保存" }
        return nil
    }
    /// Honest per-material progress for the UI: how many chunks of each local material are really durable.
    /// A material that is not complete yet is shown as such instead of looking like a saved file.
    public func materialChunkStatus(session: String) -> [String] {
        guard let local = archive.sessions.first(where: { $0.id == session }) else { return [] }
        return local.materials.map { material in
            guard let durable = incremental?.durableMaterialChunks(session: session, materialID: material.id) else {
                return "\(material.fileName) · 尚未持久化（仅本地内存）"
            }
            return durable.received == durable.total
                ? "\(material.fileName) · 已持久化分块 \(durable.received)/\(durable.total)"
                : "\(material.fileName) · 分块仅确认 \(durable.received)/\(durable.total)（未完成，导出不含该资料）"
        }
    }
    func incrementalOpenSession(_ session: LocalSession) {
        guard let persistence = incremental else { return }
        _ = persistence.bootstrapSession(session)
    }

    func incrementalBeginAttempt(session: String, attempt: String, generation: UUID, requiresTerminalCoverage: Bool) {
        incremental?.beginAttempt(fence: ArchiveFence(sessionID: session, attemptID: attempt, generationID: generation),
                                  requiresTerminalCoverage: requiresTerminalCoverage)
        if let text = incremental?.status.failureText { incrementalSavingStatus = text }
    }
    func incrementalSubmitCanonical(session: String, attempt: String, generation: UUID, output: RotatingCanonicalOutput) {
        guard let persistence = incremental else { return }
        persistence.submitCanonical(fence: ArchiveFence(sessionID: session, attemptID: attempt, generationID: generation),
                                    observations: CanonicalWire.observations(output))
    }
    /// Raw terminal enters "saving"; activeCapture is released only by the completed barrier callback.
    func incrementalRawTerminal(attempt: String) {
        guard let persistence = incremental else { return }
        if let session = archive.sessions.first(where: { $0.captureAttempts.contains(where: { $0.id == attempt }) }),
           var final = session.captureAttempts.first(where: { $0.id == attempt }) {
            incrementalFlushCaptureProjection(session: session.id)
            let outcome: ArchiveAttemptOutcome
            if final.lifecycle == "cancelled" { outcome = .cancelled }
            else if final.lifecycle == "incomplete" { outcome = .incomplete(final.failure ?? "controller_incomplete") }
            else { outcome = .completed }
            persistence.setTerminalOutcome(attempt: attempt, outcome: outcome)
            final.lifecycle = "completed"; final.failure = nil
            persistence.setCompletionProjection(attempt: attempt, deltas: [.captureState(attemptID: attempt,
                revision: (submittedCaptureRevision[attempt] ?? 0) + 1,
                state: Self.archiveCaptureState(final, history: ["completed:incremental_confirmed"]))])
        }
        persistence.markRawTerminal(attempt: attempt)
        incrementalSavingStatus = persistence.userStatus(head: persistence.lastConfirmedHead)
    }
    func incrementalCaptureFailed(attempt: String, reason: String) {
        incremental?.markCaptureFailed(attempt: attempt, reason: reason)
        incrementalSavingStatus = incremental?.status.failureText ?? "采集失败，未确认修订保留"
    }
}
extension IncrementalPersistence {
    func userStatus(head: UInt64) -> String {
        switch status {
        case .saving(let count): return "正在保存 · 未确认 \(count) 项"
        case .saved: return "已保存并回读确认 · 增量 head \(head)"
        case .blocked(let reason, let count): return "未保存 · \(reason) · 未确认 \(count) 项"
        case .closing(let count): return "正在关闭 · 等待 \(count) 项确认"
        case .closed: return "增量存储已关闭"
        case .unavailable(let reason): return "增量存储不可用 · \(reason)"
        case .opening, .ready: return "增量存储就绪"
        }
    }
}
extension IncrementalPersistence.Status {
    var failureText: String? {
        switch self {
        case .blocked(let reason, _): return "未保存 · \(reason)（全部未确认修订保留）"
        case .unavailable(let reason): return "增量存储不可用 · \(reason)"
        default: return nil
        }
    }
}

