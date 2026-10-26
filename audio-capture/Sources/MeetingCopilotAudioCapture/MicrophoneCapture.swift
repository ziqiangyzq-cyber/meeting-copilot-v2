import Foundation
import AVFoundation

/// Constructing this object does not initialize AVAudioEngine or open a device.
/// Control methods and state are MainActor isolated. PCM callbacks are not.
@MainActor
public final class MicrophoneCapture {
    public private(set) var state: CaptureState = .idle
    public var onStateChange: (@MainActor @Sendable (CaptureState) -> Void)?
    private var engine: AVAudioEngine?
    private var input: AVAudioInputNode?
    private var observer: NSObjectProtocol?
    private var watchdog: Task<Void, Never>?
    private var sessionID: UUID?
    private let heartbeat = Heartbeat()
    private let permissionProbe: @Sendable () -> Bool
    private var timeout: Double = 5
    /// An injected false probe tests refusal without querying permission or touching devices.
    /// A true probe NEVER bypasses the subsequent real OS permission check.
    public init(permissionProbe: @escaping @Sendable () -> Bool = { ExistingPermissions.microphone() }) {
        self.permissionProbe = permissionProbe
    }
    public func start(intent: CaptureIntent, bufferFrames: AVAudioFrameCount = 1024,
                      noDataTimeout: Double = 5, onFrame: @escaping AudioFrameHandler) throws {
        do {
            // Consent/channel checks precede the injected permission query.
            try CaptureGate.microphone(intent, permissionGranted: true)
            try CaptureGate.microphone(intent, permissionGranted: permissionProbe())
            try CaptureGate.microphone(intent, permissionGranted: ExistingPermissions.microphone())
            guard state != .running && state != .starting && state != .stopping else { throw CaptureFailure.alreadyActive }
            guard bufferFrames > 0, bufferFrames <= 65536, noDataTimeout.isFinite, noDataTimeout >= 1 else {
                throw CaptureFailure.invalidConfiguration
            }
        } catch {
            if engine == nil { setState(.failed(asFailure(error))) }
            throw error
        }
        setState(.starting)
        let id = UUID()
        sessionID = id
        let audioEngine = AVAudioEngine() // First possible device interaction; all gates passed.
        let node = audioEngine.inputNode
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            audioEngine.stop()
            sessionID = nil
            setState(.failed(.invalidConfiguration))
            throw CaptureFailure.invalidConfiguration
        }
        self.engine = audioEngine
        self.input = node
        timeout = noDataTimeout
        heartbeat.update(ProcessInfo.processInfo.systemUptime)
        let heartbeat = self.heartbeat
        node.installTap(onBus: 0, bufferSize: bufferFrames, format: format) { [weak self] buffer, time in
            let now = ProcessInfo.processInfo.systemUptime
            heartbeat.update(now)
            do {
                try PCMUtilities.validate(buffer)
                onFrame(AudioFrame(buffer: buffer,
                    timestamp: .microphone(time, sampleRate: buffer.format.sampleRate, receivedUptime: now)))
            } catch {
                Task { @MainActor [weak self] in
                    guard let self, self.sessionID == id else { return }
                    self.fail(.invalidBuffer)
                }
            }
        }
        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            let failure = asFailure(error)
            cleanup()
            setState(.failed(failure))
            throw failure
        }
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
            object: audioEngine, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.sessionID == id else { return }
                // No automatic restart or fallback to another input device.
                self.fail(.deviceInterrupted)
            }
        }
        setState(.running)
        watchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
                self?.checkHeartbeat(session: id)
            }
        }
    }
    /// Idempotent; removes tap, stops/resets engine and releases references/observer.
    /// A callback already in progress may finish; consumers must not block this callback.
    public func stop() {
        guard engine != nil else {
            if state != .stopped { setState(.stopped) }
            return
        }
        setState(.stopping)
        cleanup()
        setState(.stopped)
    }
    private func checkHeartbeat(session: UUID) {
        guard sessionID == session, state == .running else { return }
        if heartbeat.age(at: ProcessInfo.processInfo.systemUptime) > timeout { fail(.noDataTimeout) }
    }
    private func fail(_ error: CaptureFailure) { cleanup(); setState(.failed(error)) }
    private func cleanup() {
        sessionID = nil
        watchdog?.cancel(); watchdog = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        input?.removeTap(onBus: 0)
        engine?.stop(); engine?.reset()
        input = nil; engine = nil
    }
    private func setState(_ next: CaptureState) {
        state = next
        if let handler = onStateChange { Task { @MainActor in handler(next) } }
    }
    private func asFailure(_ error: Error) -> CaptureFailure {
        (error as? CaptureFailure) ?? .nativeError(error.localizedDescription)
    }
    deinit {
        watchdog?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        input?.removeTap(onBus: 0)
        engine?.stop()
    }
}
