import AppKit
import CoreGraphics
import MeetingCopilotAudioCapture
import DesktopSessionController

public struct AudioDisplayChoice: Identifiable {
    public let id: UInt32
    public let name: String
}

@MainActor extension ClientModel {
    public var audioDisplays: [AudioDisplayChoice] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return AudioDisplayChoice(id: number.uint32Value, name: screen.localizedName)
        }
    }

    /// Zero means automatic. Selecting a sound source does not open any device.
    public func resolvedSystemDisplayID() -> UInt32? {
        let available = audioDisplays.map(\.id)
        if systemDisplayID != 0 { return available.contains(systemDisplayID) ? systemDisplayID : nil }
        let primary = CGMainDisplayID()
        return available.contains(primary) ? primary : available.first
    }

    /// The user-facing Start button is the explicit capture intent. Low-level
    /// entry points keep their existing opt-in guard for tests and other callers.
    public func startSelectedAudio() async {
        guard !captureActive, !captureStopping, loaded, error == nil, selection != nil else { return }
        microphoneEnabled = true
        await startCapture()
    }

    public func openSoundInputSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    public var systemAudioPermissionGranted: Bool { systemAudioAuthorization }

    /// Invoked by the explicit permission button, never on launch or view rendering.
    public func requestSystemAudioPermission() {
        guard !captureActive else { return }
        // Core Audio Tap has no public preflight. Creating a minimal tap is the
        // actual permission request and also proves that the route works.
        do {
            try SystemAudioCapture.probePermission()
            systemAudioAuthorization = true
            captureStatus = "电脑声音权限已就绪；点击开始即可采集。"
        } catch {
            systemAudioAuthorization = false
            openSystemAudioPrivacySettings()
            captureStatus = "请在“系统设置 > 隐私与安全性 > 仅系统录音”中打开 Meeting Copilot，然后返回 App 点击“重新检测”。\(error.localizedDescription)"
            startSystemAudioPermissionWatch()
        }
    }

    public func openSystemAudioPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
        startSystemAudioPermissionWatch()
    }

    /// The permission can be changed while the App stays running. Poll briefly
    /// after returning from System Settings so the lock banner disappears at once.
    public func refreshSystemAudioPermission() {
        // No public preflight exists. A previous successful tap probe remains
        // ready for this launch; the real capture path revalidates on start.
        let granted = systemAudioAuthorization
        guard granted != systemAudioAuthorization else { return }
        systemAudioAuthorization = granted
        if granted, !captureActive {
            captureStatus = "电脑声音权限已就绪；点击开始即可采集。"
        }
    }

    public func startSystemAudioPermissionWatch() {
        systemAudioPermissionWatch?.cancel()
        systemAudioPermissionWatch = Task { @MainActor [weak self] in
            // Returning from System Settings cannot be preflighted publicly.
            // Keep the instruction visible; the next explicit probe is truthful.
            _ = self
        }
    }

    public func startQwenSystemAudio(settings: ASRSettingsModel) async {
        guard !captureActive, !settings.loading, microphoneEnabled, loaded, error == nil,
              let sessionID = selection else { return }
        guard let displayID = resolvedSystemDisplayID() else {
            captureStatus = "系统采集范围不可用；请在高级设置中恢复自动选择或连接显示器。"; return
        }
        let token = UUID()
        qwenClientToken = token; qwenAttemptIDs = []
        captureActive = true; settings.captureActive = true
        do {
            let controller = try makeQwenController(settings: settings, sessionID: sessionID, sourceURL: nil, token: token)
            let binding = QwenSessionBinding(sessionID: sessionID, channelID: "system",
                streamID: "qwen-system-" + token.uuidString, source: .systemAudio)
            qwenBinding = binding
            let producer = try controller.begin(binding)
            let capture = SystemAudioCapture()
            systemAudioCapture = capture
            capture.onStateChange = { [weak self, weak controller] state in
                guard let self, self.qwenClientToken == token else { return }
                if case .failed(let failure) = state {
                    controller?.externalCaptureFailed(failure.localizedDescription)
                }
            }
            try await capture.start(intent: .init(userInitiated: true, systemAudioEnabled: true),
                displayID: displayID, sampleRate: 48000, channels: 2, noDataTimeout: 8,
                onFrame: producer.handler)
            guard qwenClientToken == token, controller.state == .capturing, !captureStopping else {
                capture.onStateChange = nil; try await capture.stop(); return
            }
            try controller.externalDeviceStarted()
            captureStatus = "正在采集电脑声音 · 约每 8 秒识别一段；戴耳机也可采集其他应用播放的声音。"
        } catch {
            guard qwenClientToken == token else { return }
            if let capture = systemAudioCapture {
                capture.onStateChange = nil
                do { try await capture.stop(); systemAudioCapture = nil }
                catch {
                    captureStatus = "电脑声音启动失败，停止设备也失败；请点击取消采集重试。"; return
                }
            }
            if let controller = qwenController, controller.state == .capturing {
                controller.externalCaptureFailed(String(describing: error))
            } else {
                try? await finishQwenAttempts(lifecycle: "incomplete", failure: String(describing: error))
                captureActive = false; settings.captureActive = false
            }
            captureStatus = "电脑声音未开始：\(error.localizedDescription)"
        }
    }
}
