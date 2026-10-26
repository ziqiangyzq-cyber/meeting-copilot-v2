import Foundation
import MeetingCopilotCore
import DesktopSessionController
import LocalASRProviders
import SpeechCore
import AppleOfflineSpeech

@MainActor extension ClientModel {
    func makeQwenController(settings: ASRSettingsModel, sessionID: String, sourceURL: URL?, token: UUID, backend: (any QwenSegmentBackend)? = nil, secondary: Bool = false) throws -> QwenSegmentController {
        let selectedBackend: any QwenSegmentBackend
        let config: ASRConfiguration
        if settings.services.usesNetworkASR {
            if let network = backend { selectedBackend = network
                config = ASRConfiguration(providerID: .networkAPI, locale: OfflineSpeechLocale(rawValue: settings.persisted.locale) ?? .simplifiedChinese, terminologyContext: nil)
            } else { let network = try settings.services.makeASRBackend(locale: settings.persisted.locale)
                selectedBackend = network; config = network.captureConfiguration }
        } else {
            guard let provider = settings.loadedProvider, let loaded = provider.activeConfiguration,
                  loaded.providerID == .qwen3ASR else { throw QwenClientError.unavailable("Qwen 尚未真实加载；未回退 Apple。") }
            config = loaded; selectedBackend = backend ?? ProductionQwenSegmentBackend(provider: provider)
        }
        let controller = QwenSegmentController(backend: selectedBackend)
        _ = try controller.adoptPreparedConfiguration(config)
        if secondary { qwenSecondaryController = controller } else { qwenController = controller }
        let engineName = settings.services.usesNetworkASR ? "网络转写" : "Qwen"
        controller.onNoSpeech = { [weak self, weak controller] in
            guard let self, self.qwenClientToken == token, self.captureActive else { return }
            self.captureStatus = controller?.state == .draining
                ? "\(engineName) 正在结束采集 · 当前音频段未识别到语音；不会写入空原文。"
                : "\(engineName) 正在监听 · 当前音频段未识别到语音，继续等待\(self.audioInput == "microphone" ? "说话" : "播放声音或讲话")；不会写入空原文。"
        }
        controller.commitFinal = { [weak self, weak controller] final in
            guard let self, let controller, self.qwenClientToken == token,
                  self.selection == sessionID, final.binding.sessionID == sessionID,
                  controller.isCurrent(final) else { throw CancellationError() }
            try await self.commitQwenFinal(final, sourceURL: sourceURL)
            guard self.qwenClientToken == token, controller.isCurrent(final) else { throw CancellationError() }
        }
        controller.onObservationChange = { [weak self] observation in
            guard let self, self.qwenClientToken == token, self.selection == sessionID,
                  observation.binding.sessionID == sessionID else { return }
            self.recordQwenAttempt(observation)
        }
        controller.onStateChange = { [weak self, weak controller] state in
            guard let self, self.qwenClientToken == token else { return }
            if let observation = controller?.attemptObservation { self.recordQwenAttempt(observation) }
            switch state {
            case .loading: self.captureStatus = "\(engineName) 正在加载"
            case .ready: self.captureStatus = "\(engineName) 已采用实际加载配置"
            case .requestingMicrophone: self.captureStatus = "正在请求麦克风权限"
            case .capturing: self.captureStatus = "\(engineName) 正在采集 · 约每 8 秒处理一段，短句可点击停止；不会逐字实时显示。"
            case .importing: self.captureStatus = "正在导入音频并分段识别"
            case .draining: self.captureStatus = "排空中 · 等待 final 与生产存储确认"
            case .completed:
                self.captureStatus = self.qwenSecondaryController == nil
                    ? "所有分段 final 已写回 · 等待终态写回确认"
                    : "一路分段 final 已写回 · 等待两路全部完成及终态保存"
            case .failed(let reason):
                if self.qwenSecondaryController != nil {
                    self.handleDualAudioFailure(String(describing: reason), token: token)
                    return
                }
                let attempts = self.qwenAttemptIDs
                let failureToken = self.qwenClientToken
                let detail = controller?.continuityFailureDescription ?? String(describing: reason)
                self.captureStatus = "\(engineName) 采集失败：\(detail) · 正在保存终态"
                settings.refresh()
                Task {
                    guard self.qwenClientToken == failureToken else { return }
                    if let system = self.systemAudioCapture {
                        system.onStateChange = nil
                        do { try await system.stop(); self.systemAudioCapture = nil }
                        catch { self.captureStatus = "电脑声音停止失败，请重试停止：\(error)"; return }
                    }
                    do {
                        try await self.finishQwenAttempts(lifecycle: "incomplete", failure: String(describing: reason), attemptIDs: attempts)
                        guard self.qwenClientToken == failureToken else { return }
                        self.captureStatus = "\(engineName) 采集失败：\(detail) · 已保存的原文保留。请打开设置，点击“测试配置”重新加载后再开始。"
                    }
                    catch { self.error = "\(engineName) 失败终态未保存：\(error)" }
                    guard self.qwenClientToken == failureToken else { return }
                    if !self.qwenBatchActive { self.captureActive = false; settings.captureActive = false }
                    settings.refresh()
                }
            case .cancelled: self.captureStatus = "\(engineName) 已取消"
            case .idle: break
            }
        }
        return controller
    }

    /// Historical observation is independent of the currently loaded engine.
    public func recordQwenAttempt(_ observation: QwenAttemptObservation) {
        let binding = observation.binding
        let id = observation.attemptID
        guard loaded, error == nil,
              let index = archive.sessions.firstIndex(where: { $0.id == binding.sessionID && !$0.isDeleted }) else { return }
        let key = id.uuidString
        if !archive.sessions[index].captureAttempts.contains(where: { $0.id == key }) {
            let engine = observation.engineAtStart
            var attempt = LocalCaptureAttempt(id: key, channelID: binding.channelID,
                streamID: binding.streamID, segmentID: "", locale: engine.locale,
                engineVersion: engine.engineVersion, modelVersion: engine.modelVersion)
            attempt.sourceKind = binding.source == .file ? "audio_file" : (binding.source == .systemAudio ? "system" : "mic")
            attempt.sourceURL = binding.sourceURL?.absoluteString
            attempt.mode = binding.source == .file ? "qwen-file-batch" : (binding.source == .systemAudio ? "qwen-system-segmented" : "qwen-microphone-segmented")
            attempt.generationID = key; attempt.tasks = []
            attempt.lifecycle = "prepared"
            archive.sessions[index].captureAttempts.append(attempt)
            if incremental != nil { incrementalBeginAttempt(session: binding.sessionID, attempt: key, generation: id, requiresTerminalCoverage: false) }
        }
        guard let ai = archive.sessions[index].captureAttempts.firstIndex(where: {
            $0.id == key && $0.channelID == binding.channelID && $0.streamID == binding.streamID
                && $0.sourceURL == binding.sourceURL?.absoluteString
        }) else { return }
        qwenAttemptIDs.insert(key)
        if observation.engineAtStart.providerID == .networkAPI {
            archive.sessions[index].captureAttempts[ai].mode = "network-api-" + (binding.source == .file ? "file" : binding.source == .systemAudio ? "system" : "microphone") + "-segmented"
        }
        // Observations are facts that must survive failure/cancel and cannot regress.
        archive.sessions[index].captureAttempts[ai].deviceStarted = archive.sessions[index].captureAttempts[ai].deviceStarted || observation.deviceStarted
        archive.sessions[index].captureAttempts[ai].audioObserved = archive.sessions[index].captureAttempts[ai].audioObserved || observation.audioObserved
        archive.sessions[index].captureAttempts[ai].asrObserved = archive.sessions[index].captureAttempts[ai].asrObserved || observation.asrObserved
        if incremental != nil { incrementalFlushCaptureProjection(session: binding.sessionID) }
        else { _ = persist() }
    }

    /// Default production archive path: save() acknowledges only after exact disk readback.
    /// Incremental mode waits for the real writer acknowledgement and fsync barrier.
    public func commitQwenFinal(_ final: QwenSegmentFinal, sourceURL: URL?) async throws {
        guard loaded, error == nil,
              let index = archive.sessions.firstIndex(where: { $0.id == final.binding.sessionID && !$0.isDeleted }),
              final.sourceRange.endNs > final.sourceRange.startNs,
              (final.engine.providerID == .qwen3ASR || final.engine.providerID == .networkAPI),
              (sourceURL == nil ? final.binding.source != .file : final.binding.source == .file),
              final.binding.sourceURL == sourceURL else { throw QwenClientError.unavailable("目标会话或写入状态无效") }
        let attemptID = final.attemptID.uuidString
        let segmentID = "qwen-\(attemptID)-\(final.sequence)"
        guard !archive.sessions[index].segments.contains(where: { $0.id == segmentID }) else {
            throw QwenClientError.unavailable("重复 final 未写入")
        }
        if !qwenAttemptIDs.contains(attemptID) {
            var attempt = LocalCaptureAttempt(id: attemptID, channelID: final.binding.channelID,
                streamID: final.binding.streamID, segmentID: segmentID, locale: final.engine.locale,
                engineVersion: final.engine.engineVersion, modelVersion: final.engine.modelVersion)
            attempt.mode = sourceURL == nil ? (final.binding.source == .systemAudio ? "qwen-system-segmented" : "qwen-microphone-segmented") : "qwen-file-batch"; attempt.generationID = attemptID
            attempt.sourceKind = sourceURL == nil ? (final.binding.source == .systemAudio ? "system" : "mic") : "audio_file"; attempt.sourceURL = sourceURL?.absoluteString
            attempt.lifecycle = "capturing"; attempt.tasks = []
            archive.sessions[index].captureAttempts.append(attempt)
            qwenAttemptIDs.insert(attemptID)
            if incremental != nil { incrementalBeginAttempt(session: final.binding.sessionID, attempt: attemptID, generation: final.attemptID, requiresTerminalCoverage: false) }
        }
        guard let ai = archive.sessions[index].captureAttempts.firstIndex(where: { $0.id == attemptID }) else { throw CancellationError() }
        var coordinator = try coordinator(archive.sessions[index])
        _ = try coordinator.ingestAudioFinal(segmentID: segmentID, channelID: final.binding.channelID,
            streamID: final.recognitionStreamID, channelKind: sourceURL == nil ? (final.binding.source == .systemAudio ? "system" : "mic") : "audio_file",
            text: final.text, language: final.language, source: final.sourceRange)
        coordinator.project(into: &archive.sessions[index]); coordinators[final.binding.sessionID] = coordinator
        if final.engine.providerID == .networkAPI {
            archive.sessions[index].captureAttempts[ai].mode = "network-api-segmented"
        }
        archive.sessions[index].captureAttempts[ai].segmentID = segmentID
        archive.sessions[index].captureAttempts[ai].audioObserved = true
        archive.sessions[index].captureAttempts[ai].asrObserved = true
        archive.sessions[index].captureAttempts[ai].history.append("final:\(final.sequence):\(final.timingBasis)")
        var task = LocalCaptureTask(streamID: final.recognitionStreamID, segmentID: segmentID, firstObservedBy: "qwen-final")
        task.finalObserved = true
        archive.sessions[index].captureAttempts[ai].tasks?.append(task)
        do {
            if let persistence = incremental {
                incrementalFlushCaptureProjection(session: final.binding.sessionID)
                incrementalFlushJournal(session: final.binding.sessionID)
                if let failure = persistence.status.failureText { throw QwenClientError.unavailable(failure) }
                _ = try await persistence.awaitQuiescence()
                guard persistence.dirtyRevisions(session: final.binding.sessionID).isEmpty else { throw QwenClientError.unavailable("final 尚未确认") }
            } else if !persist() { throw QwenClientError.unavailable(error ?? "final 写回失败") }
        } catch {
            unsavedCaptureText = final.text
            throw error
        }
        // Start only after the original has a durable acknowledgement, for mic and files.
        if translateFinal {
            translateSegment(sessionID: final.binding.sessionID, segmentID: segmentID)
        }
    }

    public func finishQwenAttempts(lifecycle: String, failure: String?, attemptIDs: Set<String>? = nil) async throws {
        let attempts = attemptIDs ?? qwenAttemptIDs
        for i in archive.sessions.indices {
            for j in archive.sessions[i].captureAttempts.indices where attempts.contains(archive.sessions[i].captureAttempts[j].id) {
                let id = archive.sessions[i].captureAttempts[j].id
                archive.sessions[i].captureAttempts[j].lifecycle = incremental != nil && lifecycle == "completed" ? "stopping" : lifecycle
                archive.sessions[i].captureAttempts[j].failure = failure
                archive.sessions[i].captureAttempts[j].history.append(lifecycle + ":qwen-controller")
                if incremental != nil { incrementalRawTerminal(attempt: id) }
            }
        }
        if let persistence = incremental {
            if let reason = persistence.status.failureText { throw QwenClientError.unavailable(reason) }
            _ = try await persistence.awaitQuiescence()
        } else if !attempts.isEmpty && !persist() { throw QwenClientError.unavailable(error ?? "终态未保存") }
    }

    public func startQwenMicrophone(settings: ASRSettingsModel) async {
        guard !captureActive, !settings.loading, microphoneEnabled, loaded, error == nil,
              let sessionID = selection else { return }
        let token = UUID(); qwenClientToken = token; qwenAttemptIDs = []
        captureActive = true; settings.captureActive = true
        do {
            let controller = try makeQwenController(settings: settings, sessionID: sessionID, sourceURL: nil, token: token)
            let binding = QwenSessionBinding(sessionID: sessionID, channelID: "mic", streamID: "qwen-mic-" + token.uuidString, source: .microphone)
            qwenBinding = binding
            try await controller.userPressedStartMicrophone(userInitiated: true, binding: binding)
        } catch {
            guard qwenClientToken == token else { return }
            captureStatus = "Qwen 未开始：\(error)"; captureActive = false; settings.captureActive = false
        }
    }

    public func importQwenFiles(_ urls: [URL], settings: ASRSettingsModel) {
        guard !captureActive, !settings.loading, (!settings.services.usesNetworkASR || settings.services.contentSendingEnabled), (settings.services.usesNetworkASR || settings.loadedProvider?.providerID == .qwen3ASR),
              loaded, error == nil, let sessionID = selection else { return }
        let token = UUID(); qwenClientToken = token; qwenAttemptIDs = []
        captureActive = true; qwenBatchActive = true; settings.captureActive = true
        let started = fileBatch.start(files: urls, perform: { [weak self] url in
            guard let self, self.qwenClientToken == token else { throw CancellationError() }
            self.qwenAttemptIDs = []
            let controller = try self.makeQwenController(settings: settings, sessionID: sessionID, sourceURL: url, token: token)
            let binding = QwenSessionBinding(sessionID: sessionID, channelID: "audio-file",
                streamID: "qwen-file-" + UUID().uuidString, source: .file, sourceURL: url)
            self.qwenBinding = binding
            try await controller.transcribeFile(url, binding: binding)
            try await self.finishQwenAttempts(lifecycle: "completed", failure: nil)
            guard self.error == nil else { throw QwenClientError.unavailable(self.error ?? "终态写回未确认") }
        })
        if !started { captureActive = false; qwenBatchActive = false; settings.captureActive = false; return }
        Task { [weak self] in
            guard let self else { return }
            while self.fileBatch.busy && self.qwenClientToken == token { try? await Task.sleep(nanoseconds: 100_000_000) }
            guard self.qwenClientToken == token else { return }
            self.captureActive = false; self.qwenBatchActive = false; settings.captureActive = false
            if case .completed = self.fileBatch.state { self.captureStatus = "音频导入已结束 · 原文与终态已保存确认" }
        }
    }

    public func cancelQwen() {
        if let system = systemAudioCapture {
            guard !captureStopping else { return }
            captureStopping = true
            Task {
                defer { self.captureStopping = false }
                system.onStateChange = nil
                do {
                    try await system.stop(); self.systemAudioCapture = nil
                    self.cancelQwenAfterDeviceStopped()
                } catch { self.captureStatus = "电脑声音取消失败，请重试停止：\(error)" }
            }
            return
        }
        cancelQwenAfterDeviceStopped()
    }
    private func cancelQwenAfterDeviceStopped() {
        if let observation = qwenController?.attemptObservation { recordQwenAttempt(observation) }
        let attempts = qwenAttemptIDs
        qwenClientToken = UUID(); fileBatch.cancel(); qwenController?.cancel(); qwenController = nil
        Task {
            do { try await self.finishQwenAttempts(lifecycle: "incomplete", failure: "user_cancelled", attemptIDs: attempts) }
            catch { self.error = "取消终态未保存：\(error)" }
        }
        captureActive = false; qwenBatchActive = false; asrSettings?.captureActive = false
        asrSettings?.refresh()
        captureStatus = "Qwen 已取消 · 已合法写回的原文保留；需要重新加载引擎"
    }
}
public enum QwenClientError: Error, LocalizedError {
    case unavailable(String)
    public var errorDescription: String? { switch self { case .unavailable(let reason): return reason } }
}
