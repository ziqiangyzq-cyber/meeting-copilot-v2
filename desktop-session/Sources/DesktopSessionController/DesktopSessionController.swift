import Foundation
import AVFoundation
@preconcurrency import Speech
import MeetingCopilotAudioCapture
import MeetingCopilotPCMBridge
import AppleOfflineSpeech
import LiveSpeechSession
import RotatingSpeechSession

public struct DesktopStartIntent: Sendable {
    public let userInitiated: Bool, microphoneEnabled: Bool, speechEnabled: Bool, onDeviceProcessingAuthorized: Bool
    public init(userInitiated: Bool = false, microphoneEnabled: Bool = false,
                speechEnabled: Bool = false, onDeviceProcessingAuthorized: Bool = false) {
        self.userInitiated = userInitiated; self.microphoneEnabled = microphoneEnabled
        self.speechEnabled = speechEnabled; self.onDeviceProcessingAuthorized = onDeviceProcessingAuthorized
    }
}
public enum DesktopSessionFailure: Error, Equatable, Sendable {
    case permissionsMicrophone, permissionsSpeech, invalidConfiguration, alreadyActive, startCancelled, reentrantCall
    case capture(CaptureFailure), live(LiveSpeechFailure), speech(OfflineSpeechFailure), rotating(RotatingSpeechFailure)
}
public enum DesktopSessionState: Equatable, Sendable {
    case idle, requestingPermissions, capturing, stopping
    case terminal(LiveSpeechState), failed(DesktopSessionFailure)
}
public enum DesktopRecognitionMode: Sendable { case finite, rotating }
public struct DesktopSessionSnapshot: Equatable, Sendable {
    public let state: DesktopSessionState
    /// Historical evidence for this attempt, not a claim that the device is still running.
    public let deviceStarted: Bool, audioObserved: Bool, asrObserved: Bool
}
@MainActor public protocol DesktopPermissionGateway: AnyObject {
    func requestMicrophone() async -> Bool
    func requestSpeech() async -> Bool
}
@MainActor public final class SystemDesktopPermissions: DesktopPermissionGateway {
    public init() {}
    public func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
        default: return false
        }
    }
    public func requestSpeech() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }
}
/// Stop removes the device callback; late borrowed frames are rejected by the sealed producer.
@MainActor public protocol DesktopCapturePort: AnyObject {
    var state: CaptureState { get }
    var onStateChange: (@MainActor @Sendable (CaptureState) -> Void)? { get set }
    func start(intent: CaptureIntent, onFrame: @escaping AudioFrameHandler) throws
    func stop()
}
@MainActor public final class SystemMicrophonePort: DesktopCapturePort {
    private let microphone = MicrophoneCapture()
    public init() {}
    public var state: CaptureState { microphone.state }
    public var onStateChange: (@MainActor @Sendable (CaptureState) -> Void)? {
        get { microphone.onStateChange }
        set { microphone.onStateChange = newValue }
    }
    public func start(intent: CaptureIntent, onFrame: @escaping AudioFrameHandler) throws {
        try microphone.start(intent: intent, onFrame: onFrame)
    }
    public func stop() { microphone.stop() }
}

/// One microphone and one poll task for either owner mode. No work at construction or seq allocation.
@MainActor public final class DesktopSessionController {
    public var onLiveOutput: (@MainActor @Sendable (LiveSpeechOutput) -> Void)?
    public var onRotatingOutput: (@MainActor @Sendable (RotatingSpeechOutput) -> Void)?
    public var onCanonicalOutput: (@MainActor @Sendable (RotatingCanonicalOutput) -> Void)?
    public var canonicalCoverage: RotatingCanonicalCoverage? { mode == .rotating ? rotating.canonicalCoverage : nil }
    public var onStateChange: (@MainActor @Sendable (DesktopSessionSnapshot) -> Void)?
    public private(set) var snapshot = DesktopSessionSnapshot(state: .idle, deviceStarted: false, audioObserved: false, asrObserved: false)
    public private(set) var mode: DesktopRecognitionMode = .finite
    public var queueSnapshot: PCMQueueSnapshot? { mode == .finite ? session.queueSnapshot : rotating.queueSnapshot }
    public var lastMappedRange: PCMSourceRange? { mode == .finite ? session.lastMappedRange : rotatingLastRange }
    public var rotatingStartedTasks: UInt64 { rotating.startedTasks }
    public var rotatingFinalizedTasks: UInt64 { rotating.finalizedTasks }
    public var rotatingRetainedOwnerCount: Int { rotating.retainedOwnerCount }
    private let permissions: any DesktopPermissionGateway
    private let capture: any DesktopCapturePort
    private let session: LiveSpeechSession
    private let rotating: RotatingSpeechSession
    private let interval: Int
    private var pollTask: Task<Void, Never>?
    private var attempt: UUID?
    private var generation: LiveSpeechGeneration?
    private var rotatingGeneration: RotatingSpeechGeneration?
    private var rotatingLastRange: PCMSourceRange?
    private var delivering = false
    private var deferredFailure: DesktopSessionFailure?
    private var hasGeneration: Bool { generation != nil || rotatingGeneration != nil }
    private enum Configuration { case finite(LiveSpeechConfiguration), rotating(RotatingSpeechConfiguration) }

    public init(permissions: (any DesktopPermissionGateway)? = nil, capture: (any DesktopCapturePort)? = nil,
                backend: (any OfflinePCMRecognitionBackend)? = nil, pollIntervalMilliseconds: Int = 10,
                backendFactory: RotatingSpeechSession.BackendFactory? = nil) {
        self.permissions = permissions ?? SystemDesktopPermissions()
        self.capture = capture ?? SystemMicrophonePort()
        session = LiveSpeechSession(backend: backend ?? AppleOnDeviceBackend())
        rotating = RotatingSpeechSession(backendFactory: backendFactory ?? { _ in AppleOnDeviceBackend() })
        interval = pollIntervalMilliseconds
    }
    /// Existing finite API and raw callback retain their behavior.
    public func userPressedStart(intent: DesktopStartIntent, configuration: LiveSpeechConfiguration) async throws {
        try await start(intent: intent, configuration: .finite(configuration))
    }
    /// Rotating mode reuses one capture ingress; task identities and revisions are supplied by the owner.
    public func userPressedStart(intent: DesktopStartIntent, configuration: RotatingSpeechConfiguration) async throws {
        try await start(intent: intent, configuration: .rotating(configuration))
    }
    private func start(intent: DesktopStartIntent, configuration: Configuration) async throws {
        guard !delivering else { throw DesktopSessionFailure.reentrantCall }
        guard attempt == nil && !hasGeneration else { throw DesktopSessionFailure.alreadyActive }
        do {
            try CaptureGate.microphone(CaptureIntent(userInitiated: intent.userInitiated, microphoneEnabled: intent.microphoneEnabled), permissionGranted: true)
            try SpeechStartGate.validate(SpeechStartIntent(userInitiated: intent.userInitiated, speechEnabled: intent.speechEnabled,
                onDeviceProcessingAuthorized: intent.onDeviceProcessingAuthorized), osAuthorized: true)
            guard (10...20).contains(interval) else { throw DesktopSessionFailure.invalidConfiguration }
            try validate(configuration)
        } catch {
            let failure = Self.failure(error); publish(.failed(failure), reset: true); throw failure
        }
        let id = UUID(); attempt = id; deferredFailure = nil; rotatingLastRange = nil
        switch configuration { case .finite: mode = .finite; case .rotating: mode = .rotating }
        publish(.requestingPermissions, reset: true)
        do {
            let microphoneGranted = await permissions.requestMicrophone()
            try checkAttempt(id)
            guard microphoneGranted else { throw DesktopSessionFailure.permissionsMicrophone }
            let speechGranted = await permissions.requestSpeech()
            try checkAttempt(id)
            guard speechGranted else { throw DesktopSessionFailure.permissionsSpeech }
            let speechIntent = SpeechStartIntent(userInitiated: intent.userInitiated, speechEnabled: intent.speechEnabled,
                onDeviceProcessingAuthorized: intent.onDeviceProcessingAuthorized)
            let handler: AudioFrameHandler
            switch configuration {
            case .finite(let c):
                let producer = try session.begin(intent: speechIntent, configuration: c) { [weak self] in self?.observe($0, attempt: id) }
                generation = producer.generation; handler = producer.handler
            case .rotating(let c):
                rotating.onCanonicalOutput = { [weak self] output in self?.observeCanonical(output, attempt: id) }
                let producer = try rotating.begin(intent: speechIntent, configuration: c) { [weak self] in self?.observeRotating($0, attempt: id) }
                rotatingGeneration = producer.generation; handler = producer.handler
            }
            capture.onStateChange = { [weak self] state in
                guard let self, self.attempt == id, self.capture.state == state,
                      case .failed(let error) = state, self.hasGeneration else { return }
                self.abort(.capture(error))
            }
            try capture.start(intent: CaptureIntent(userInitiated: intent.userInitiated, microphoneEnabled: intent.microphoneEnabled), onFrame: handler)
            guard case .running = capture.state else { throw DesktopSessionFailure.capture(.nativeError("DEVICE_DID_NOT_START")) }
            publish(.capturing, deviceStarted: true)
            startPolling(attempt: id)
        } catch {
            if attempt != id { throw DesktopSessionFailure.startCancelled }
            let failure = Self.failure(error); abort(failure); throw failure
        }
    }
    private func validate(_ configuration: Configuration) throws {
        switch configuration {
        case .finite(let c):
            guard c.source == .microphone,
                  [c.sessionId, c.channelId, c.streamId, c.segmentId].allSatisfy({ !$0.isEmpty }),
                  c.maximumInputFrames > 0, (1...65536).contains(c.maximumBlocksPerPoll),
                  c.mappingRevision > 0, c.finishDeadlineSeconds.isFinite, c.finishDeadlineSeconds > 0 else {
                throw DesktopSessionFailure.invalidConfiguration
            }
            try validateQueue(c.queueCapacityBlocks, c.maximumFramesPerBlock, c.maximumBytesPerBlock)
        case .rotating(let c):
            guard c.source == .microphone, !c.sessionId.isEmpty, !c.channelId.isEmpty,
                  c.maximumInputFrames > 0, c.maximumFramesPerBlock > 0,
                  Int(c.maximumFramesPerBlock) <= c.maximumInputFrames,
                  (1...65536).contains(c.maximumBlocksPerPoll), c.maximumFramesPerPoll >= Int(c.maximumFramesPerBlock),
                  (1...64).contains(c.maxRetiringTasks), c.mappingRevision > 0,
                  c.finishDeadlineSeconds.isFinite, c.finishDeadlineSeconds > 0 else {
                throw DesktopSessionFailure.invalidConfiguration
            }
            try validateQueue(c.queueCapacityBlocks, c.maximumFramesPerBlock, c.maximumBytesPerBlock)
        }
    }
    private func validateQueue(_ capacity: Int, _ frames: UInt32, _ bytes: Int) throws {
        guard (1...65536).contains(capacity), frames > 0, bytes > 0, bytes <= Int.max / capacity else {
            throw DesktopSessionFailure.invalidConfiguration
        }
    }
    public func userPressedStop() throws {
        guard !delivering else { throw DesktopSessionFailure.reentrantCall }
        guard hasGeneration else { cancelPermissionWait(); return }
        guard snapshot.state == .capturing else { return }
        capture.onStateChange = nil; capture.stop()
        // Producer sealing serializes with any enqueue in flight; all accepted PCM is drained.
        if let generation { try session.closeInput(generation: generation) }
        if let rotatingGeneration { try rotating.closeInput(generation: rotatingGeneration) }
        publish(.stopping)
    }
    public func userPressedCancel() throws {
        guard !delivering else { throw DesktopSessionFailure.reentrantCall }
        guard hasGeneration else { cancelPermissionWait(); return }
        capture.onStateChange = nil; capture.stop()
        if let generation { try session.cancel(generation: generation) }
        if let rotatingGeneration { try rotating.cancel(generation: rotatingGeneration) }
    }
    private func cancelPermissionWait() {
        if attempt != nil { attempt = nil; publish(.failed(.startCancelled)) }
    }
    private func checkAttempt(_ id: UUID) throws {
        guard attempt == id, !Task.isCancelled else { throw DesktopSessionFailure.startCancelled }
    }
    private func startPolling(attempt id: UUID) {
        pollTask?.cancel()
        let nanoseconds = UInt64(interval) * 1_000_000
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: nanoseconds) } catch { return }
                guard let self, self.attempt == id, self.hasGeneration else { return }
                if case .failed(let failure) = self.capture.state, self.snapshot.state == .capturing {
                    self.abort(.capture(failure)); return
                }
                do {
                    if let token = self.generation { try self.session.poll(generation: token) }
                    if let token = self.rotatingGeneration { try self.rotating.poll(generation: token) }
                    if self.lastMappedRange != nil && !self.snapshot.audioObserved { self.publish(self.snapshot.state, audioObserved: true) }
                } catch { self.abort(Self.failure(error)); return }
            }
        }
    }
    private func observe(_ output: LiveSpeechOutput, attempt id: UUID) {
        guard attempt == id else { return }
        switch output {
        case .transcript:
            publish(snapshot.state, audioObserved: session.lastMappedRange != nil || snapshot.audioObserved, asrObserved: true)
        case .terminal(_, let state): terminal(deferredFailure.map { .failed($0) } ?? .terminal(state))
        }
        delivering = true; onLiveOutput?(output); delivering = false
    }
    private func observeRotating(_ output: RotatingSpeechOutput, attempt id: UUID) {
        guard attempt == id else { return }
        switch output {
        case .transcript(_, let update):
            publish(snapshot.state, audioObserved: update.source.frameEnd > update.source.frameStart || snapshot.audioObserved, asrObserved: true)
        case .dispatched(_, _, _, let range):
            rotatingLastRange = range
            if !snapshot.audioObserved { publish(snapshot.state, audioObserved: true) }
        case .terminal(_, let state):
            let next: DesktopSessionState
            if let deferredFailure { next = .failed(deferredFailure) }
            else {
                switch state {
                case .completed: next = .terminal(.completed)
                case .cancelled: next = .terminal(.cancelled)
                case .incomplete(let failure): next = .failed(.rotating(failure))
                default: next = .failed(.rotating(.invalidConfiguration))
                }
            }
            terminal(next)
        }
        // Pass exact generation / task IDs / raw revisions; no event_seq and no synthetic Live output.
        delivering = true; onRotatingOutput?(output); delivering = false
    }
    private func observeCanonical(_ output: RotatingCanonicalOutput, attempt id: UUID) {
        guard attempt == id else { return }
        switch output {
        case .mapped:
            if !snapshot.audioObserved { publish(snapshot.state, audioObserved: true) }
        case .terminalCoverage:
            // Stable poll-boundary metadata precedes raw terminal. Stop hardware immediately here.
            capture.onStateChange = nil; capture.stop()
        default: break
        }
        delivering = true; onCanonicalOutput?(output); delivering = false
    }
    private func terminal(_ state: DesktopSessionState) {
        // Hardware only; either owner is still in output delivery and rejects lifecycle reentry.
        capture.onStateChange = nil; capture.stop()
        pollTask?.cancel(); pollTask = nil; generation = nil; rotatingGeneration = nil; attempt = nil
        publish(state)
    }
    private func abort(_ failure: DesktopSessionFailure) {
        deferredFailure = failure
        capture.onStateChange = nil; capture.stop()
        if let generation { try? session.cancel(generation: generation) }
        if let rotatingGeneration { try? rotating.cancel(generation: rotatingGeneration) }
        pollTask?.cancel(); pollTask = nil; generation = nil; rotatingGeneration = nil; attempt = nil
        publish(.failed(failure))
    }
    private func publish(_ state: DesktopSessionState, reset: Bool = false, deviceStarted: Bool? = nil,
                         audioObserved: Bool? = nil, asrObserved: Bool? = nil) {
        snapshot = DesktopSessionSnapshot(state: state,
            deviceStarted: deviceStarted ?? (reset ? false : snapshot.deviceStarted),
            audioObserved: audioObserved ?? (reset ? false : snapshot.audioObserved),
            asrObserved: asrObserved ?? (reset ? false : snapshot.asrObserved))
        delivering = true; onStateChange?(snapshot); delivering = false
    }
    private static func failure(_ error: any Error) -> DesktopSessionFailure {
        if let error = error as? DesktopSessionFailure { return error }
        if let error = error as? CaptureFailure { return .capture(error) }
        if let error = error as? LiveSpeechFailure { return .live(error) }
        if let error = error as? RotatingSpeechFailure { return .rotating(error) }
        if let error = error as? OfflineSpeechFailure { return .speech(error) }
        return .capture(.nativeError(error.localizedDescription))
    }
    deinit { pollTask?.cancel() }
}
