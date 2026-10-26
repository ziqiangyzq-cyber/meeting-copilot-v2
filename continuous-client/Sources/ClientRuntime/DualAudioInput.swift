import Foundation
import MeetingCopilotAudioCapture
import DesktopSessionController

@MainActor extension ClientModel {
    public func startQwenDualAudio(settings: ASRSettingsModel) async {
        guard !captureActive, !settings.loading, microphoneEnabled, loaded, error == nil,
              let sessionID = selection else { return }
        guard let displayID = resolvedSystemDisplayID() else {
            captureStatus = "系统采集范围不可用；请在高级设置中恢复自动选择或连接显示器。"; return
        }
        let token = UUID()
        qwenClientToken = token; qwenAttemptIDs = []; dualFailureHandling = false
        captureActive = true; settings.captureActive = true
        do {
            let underlying: any QwenSegmentBackend
            if settings.services.usesNetworkASR { underlying = try settings.services.makeASRBackend(locale: settings.persisted.locale) }
            else { guard let provider = settings.loadedProvider else { throw QwenClientError.unavailable("本机引擎未加载") }; underlying = ProductionQwenSegmentBackend(provider: provider) }
            let shared = SerialQwenBackend(underlying: underlying)
            dualAudioBackend = shared
            let mic = try makeQwenController(settings: settings, sessionID: sessionID,
                sourceURL: nil, token: token, backend: shared)
            let system = try makeQwenController(settings: settings, sessionID: sessionID,
                sourceURL: nil, token: token, backend: shared, secondary: true)
            let micBinding = QwenSessionBinding(sessionID: sessionID, channelID: "mic",
                streamID: "qwen-dual-mic-" + token.uuidString, source: .microphone)
            let systemBinding = QwenSessionBinding(sessionID: sessionID, channelID: "system",
                streamID: "qwen-dual-system-" + token.uuidString, source: .systemAudio)
            qwenBinding = micBinding
            // Prepare both controllers before any native PCM can schedule inference.
            let producer = try system.begin(systemBinding)
            try await mic.userPressedStartMicrophone(userInitiated: true, binding: micBinding)
            guard qwenClientToken == token, !captureStopping, !dualFailureHandling else { return }
            let capture = SystemAudioCapture()
            systemAudioCapture = capture
            capture.onStateChange = { [weak self, weak system] state in
                guard let self, self.qwenClientToken == token else { return }
                if case .failed(let failure) = state {
                    system?.externalCaptureFailed(failure.localizedDescription)
                }
            }
            try await capture.start(intent: .init(userInitiated: true, systemAudioEnabled: true),
                displayID: displayID, sampleRate: 48000, channels: 2, noDataTimeout: 8,
                onFrame: producer.handler)
            guard qwenClientToken == token, system.state == .capturing,
                  !captureStopping, !dualFailureHandling else {
                capture.onStateChange = nil
                try await capture.stop()
                return
            }
            try system.externalDeviceStarted()
            captureStatus = "正在同时采集电脑声音＋麦克风 · 两路分别保存和翻译，约每 8 秒处理；建议使用耳机。"
        } catch {
            guard qwenClientToken == token else { return }
            handleDualAudioFailure(error.localizedDescription, token: token)
        }
    }

    func stopDualAudio() {
        guard !captureStopping, !dualFailureHandling,
              let mic = qwenController, let system = qwenSecondaryController else { return }
        captureStopping = true
        let token = qwenClientToken
        captureStatus = "正在停止两路采集 · 等待最后原文与终态保存"
        Task {
            defer { if self.qwenClientToken == token { self.captureStopping = false } }
            do {
                if let capture = self.systemAudioCapture {
                    capture.onStateChange = nil
                    try await capture.stop()
                    guard self.qwenClientToken == token, !self.dualFailureHandling else { return }
                    self.systemAudioCapture = nil
                }
                // Both pumps seal and drain concurrently; inference still uses the FIFO.
                async let micDrain: Void = mic.stopAndDrain()
                async let systemDrain: Void = system.stopAndDrain()
                _ = try await (micDrain, systemDrain)
                guard self.qwenClientToken == token, !self.dualFailureHandling else { return }
                try await self.finishQwenAttempts(lifecycle: "completed", failure: nil)
                guard self.qwenClientToken == token, !self.dualFailureHandling else { return }
                self.captureActive = false; self.asrSettings?.captureActive = false
                self.qwenSecondaryController = nil; self.dualAudioBackend = nil
                self.captureStatus = mic.deliveredSegments + system.deliveredSegments == 0
                    ? "两路采集已结束 · 未识别到语音；终态已保存确认"
                    : "两路采集已结束 · final 与终态已保存确认"
            } catch {
                guard self.qwenClientToken == token else { return }
                self.handleDualAudioFailure(String(describing: error), token: token)
            }
        }
    }

    func handleDualAudioFailure(_ reason: String, token: UUID) {
        guard qwenClientToken == token, !dualFailureHandling else { return }
        dualFailureHandling = true; captureStopping = true
        captureStatus = "双路采集失败：\(reason) · 正在停止两路并保存终态"
        finishDualAudioCancellation(reason: reason, token: token)
    }

    func cancelDualAudio() {
        guard !captureStopping, !dualFailureHandling else { return }
        captureStopping = true; dualFailureHandling = true
        finishDualAudioCancellation(reason: "user_cancelled", token: qwenClientToken)
    }

    private func finishDualAudioCancellation(reason: String, token: UUID) {
        // Immediately seal microphone PCM and invalidate both inferences. Preserve
        // all finals already acknowledged by the archive, then await native SCK stop.
        for controller in [qwenController, qwenSecondaryController].compactMap({ $0 }) {
            if let observation = controller.attemptObservation { recordQwenAttempt(observation) }
            controller.cancel()
        }
        Task {
            guard self.qwenClientToken == token else { return }
            if let capture = self.systemAudioCapture {
                capture.onStateChange = nil
                do {
                    try await capture.stop()
                    guard self.qwenClientToken == token else { return }
                    self.systemAudioCapture = nil
                } catch {
                    self.captureStopping = false; self.dualFailureHandling = false
                    self.captureStatus = "双路采集设备停止失败，请重试取消：\(error)"
                    return
                }
            }
            do {
                try await self.finishQwenAttempts(lifecycle: "incomplete", failure: reason)
            } catch { self.error = "双路采集终态未保存：\(error)" }
            guard self.qwenClientToken == token else { return }
            self.qwenClientToken = UUID()
            self.qwenController = nil; self.qwenSecondaryController = nil; self.dualAudioBackend = nil
            self.captureActive = false; self.asrSettings?.captureActive = false
            self.captureStopping = false; self.dualFailureHandling = false
            self.asrSettings?.refresh()
            self.captureStatus = reason == "user_cancelled"
                ? "双路采集已取消 · 已保存原文保留；再次开始前需重新加载 Qwen"
                : "双路采集失败：\(reason) · 已保存原文保留；请在设置中重新测试加载 Qwen"
        }
    }
}
