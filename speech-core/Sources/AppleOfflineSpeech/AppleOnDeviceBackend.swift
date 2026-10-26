import Foundation
import AVFoundation
@preconcurrency import Speech

/// Real Apple backend. Only start creates a recognizer/task, after adapter intent gating.
/// Never requests permission, starts a microphone, prepares/downloads assets or enables server fallback.
@MainActor public final class AppleOnDeviceBackend: OfflinePCMRecognitionBackend {
    public var osAuthorized: Bool { SFSpeechRecognizer.authorizationStatus() == .authorized }
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation: UInt64 = 0
    public init() {}
    public func begin(locale: OfflineSpeechLocale, deliver: @escaping @MainActor @Sendable (SpeechBackendObservation) -> Void) throws {
        guard osAuthorized else { throw OfflineSpeechFailure.osAuthorizationMissing }
        guard task == nil else { throw OfflineSpeechFailure.alreadyActive }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale.rawValue)) else { throw OfflineSpeechFailure.localeUnsupported }
        guard recognizer.supportsOnDeviceRecognition else { throw OfflineSpeechFailure.onDeviceUnavailable }
        guard recognizer.isAvailable else { throw OfflineSpeechFailure.recognizerUnavailable }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        self.recognizer = recognizer; self.request = request
        generation &+= 1; let token = generation
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // Transfer plain Sendable values only. Never send framework result objects across actors.
            let observation: SpeechBackendObservation?
            if let result { observation = .hypothesis(text: result.bestTranscription.formattedString, isFinal: result.isFinal) }
            else { observation = nil }
            let errorCode: String?
            if let error { let native = error as NSError; errorCode = "\(native.domain):\(native.code)" }
            else { errorCode = nil }
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                if let observation { deliver(observation) }
                // A final result ends the task; cancellation callbacks cannot become new transcripts.
                if let errorCode, self.generation == token { deliver(.failure(errorCode)) }
            }
        }
    }
    public func append(_ buffer: AVAudioPCMBuffer) throws {
        guard osAuthorized else { throw OfflineSpeechFailure.osAuthorizationMissing }
        guard let request, task != nil else { throw OfflineSpeechFailure.notAcceptingPCM }
        request.append(buffer)
    }
    public func finishAudio() { request?.endAudio() }
    public func cancel() {
        generation &+= 1; task?.cancel(); task = nil; request = nil; recognizer = nil
    }
}
