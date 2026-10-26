import Foundation
import AVFoundation
@preconcurrency import Speech
import AppleOfflineSpeech

public enum ASRProviderID: String, Codable, Sendable, CaseIterable {
    case appleSpeech = "apple-speech-on-device"
    case qwen3ASR = "qwen3-asr"
    case networkAPI = "network-audio-api"
}
public enum ASRPathKind: String, Codable, Sendable { case systemManaged, directory }
public struct ASRProviderDescriptor: Equatable, Sendable {
    public let id: ASRProviderID
    public let displayName: String
    public let pathKind: ASRPathKind
    public let implemented: Bool
    public let mixedLanguageEvidence: String
}
public enum LocalASRRegistry {
    public static let catalog: [ASRProviderDescriptor] = [
        .init(id: .appleSpeech, displayName: "Apple Speech（本机离线）", pathKind: .systemManaged, implemented: true,
              mixedLanguageEvidence: "既有Tingting合成中英混语样本不合格；真人混语未验证"),
        .init(id: .qwen3ASR, displayName: "Qwen3-ASR-1.7B（本地分段批处理）", pathKind: .directory, implemented: true,
              mixedLanguageEvidence: "Tingting/Samantha四条合成文件已测；community+术语context，金额句有中文改写；真人/实时未验证")
    ]
    @MainActor public static func make(_ id: ASRProviderID) -> LocalASRProvider { LocalASRProvider(providerID: id) }
}
public struct ASRConfiguration: Equatable, Sendable {
    public let providerID: ASRProviderID
    public let locale: OfflineSpeechLocale
    /// Qwen uses a verified local model directory; loading is async and never downloads.
    public let modelPath: String?
    public let qwenRuntime: QwenRuntimeConfiguration?
    public let terminologyContext: String?
    public static let defaultTerminologyContext: String? = nil
    public init(providerID: ASRProviderID, locale: OfflineSpeechLocale, modelPath: String? = nil,
                qwenRuntime: QwenRuntimeConfiguration? = nil, terminologyContext: String? = ASRConfiguration.defaultTerminologyContext) {
        self.providerID = providerID; self.locale = locale; self.modelPath = modelPath
        self.qwenRuntime = qwenRuntime; self.terminologyContext = terminologyContext
    }
}
public enum ASRReadinessState: String, Sendable { case unsupported, invalidConfiguration, permissionRequired, unavailable, readyToPrepare, prepared }
public struct ASRReadiness: Equatable, Sendable {
    public let state: ASRReadinessState
    public let reason: String?
    public init(_ state: ASRReadinessState, reason: String? = nil) { self.state = state; self.reason = reason }
}
public struct ASREngineIdentity: Equatable, Sendable {
    public let providerID: ASRProviderID
    public let engineVersion: String
    public let modelVersion: String?
    public let locale: String
    public let generation: UInt64
    public init(providerID: ASRProviderID, engineVersion: String, modelVersion: String?, locale: String, generation: UInt64) {
        self.providerID = providerID; self.engineVersion = engineVersion; self.modelVersion = modelVersion; self.locale = locale; self.generation = generation
    }
}
public enum ASRProviderState: String, Sendable { case idle, loading, prepared, listening, finishing, finalized, cancelled, failed }
public enum ASRProviderError: Error, Equatable, Sendable {
    case providerMismatch, invalidConfiguration(String), unsupportedProvider, notPrepared, activeRecognition
    case readiness(ASRReadiness), speech(OfflineSpeechFailure), qwen(String)
}
public struct ASRProviderEvent: Sendable {
    public let engine: ASREngineIdentity
    public let output: OfflineSpeechOutput
}
/// No microphone/authorization/download calls. load prepares a backend; Apple model weights are OS-managed.
@MainActor public protocol LocalASRProviding: AnyObject {
    var providerID: ASRProviderID { get }
    var state: ASRProviderState { get }
    var activeEngine: ASREngineIdentity? { get }
    var lastFailure: ASRProviderError? { get }
    func inspect(_ configuration: ASRConfiguration) -> ASRReadiness
    @discardableResult func load(_ configuration: ASRConfiguration) throws -> ASREngineIdentity
    @discardableResult func loadAsync(_ configuration: ASRConfiguration) async throws -> ASREngineIdentity
    func transcribeSegment(fileURL: URL, expectedAudioSHA256: String?) async throws -> QwenSegmentResult
    func start(intent: SpeechStartIntent, sessionID: String, channelID: String, streamID: String, segmentID: String,
               deliver: @escaping @MainActor @Sendable (ASRProviderEvent) -> Void) throws
    func append(_ buffer: AVAudioPCMBuffer, source: PCMSourceRange) throws
    func finishAudio(atUptime: Double) throws
    func pollFinalDeadline(atUptime: Double)
    func cancel()
    func unload()
}
/// Only for dependency injection and independent fake checks; not a selectable product provider.
@MainActor public struct ASRBackendFactory {
    public let inspect: @MainActor (OfflineSpeechLocale) -> ASRReadiness
    public let make: @MainActor () -> any OfflinePCMRecognitionBackend
    public let engineVersion: String
    public init(engineVersion: String, inspect: @escaping @MainActor (OfflineSpeechLocale) -> ASRReadiness,
                make: @escaping @MainActor () -> any OfflinePCMRecognitionBackend) {
        self.engineVersion = engineVersion; self.inspect = inspect; self.make = make
    }
    public static var apple: ASRBackendFactory {
        .init(engineVersion: "apple.SFSpeechRecognizer/on-device;adapter=1;os=" + ProcessInfo.processInfo.operatingSystemVersionString,
              inspect: { locale in
            guard SFSpeechRecognizer.authorizationStatus() == .authorized else { return .init(.permissionRequired, reason: "OS_SPEECH_AUTHORIZATION_MISSING") }
            guard let r = SFSpeechRecognizer(locale: Locale(identifier: locale.rawValue)) else { return .init(.unavailable, reason: "LOCALE_UNSUPPORTED") }
            guard r.supportsOnDeviceRecognition else { return .init(.unavailable, reason: "ON_DEVICE_UNAVAILABLE") }
            guard r.isAvailable else { return .init(.unavailable, reason: "RECOGNIZER_UNAVAILABLE") }
            return .init(.readyToPrepare)
        }, make: { AppleOnDeviceBackend() })
    }
}
@MainActor public final class LocalASRProvider: LocalASRProviding {
    public let providerID: ASRProviderID
    public private(set) var state: ASRProviderState = .idle
    public private(set) var activeEngine: ASREngineIdentity?
    public private(set) var lastFailure: ASRProviderError?
    public private(set) var activeConfiguration: ASRConfiguration?
    private let factory: ASRBackendFactory
    private let maxInputFrames: Int
    private let finalTimeout: Double
    private var adapter: AppleOfflineSpeechAdapter?
    private var generation: UInt64 = 0
    private var qwenSession: (any QwenWorkerTransport)?
    private let qwenFactory: @Sendable () -> any QwenWorkerTransport
    public private(set) var qwenLoadAcknowledgement: QwenLoadAcknowledgement?
    public init(providerID: ASRProviderID, maxInputFrames: Int = 16_000 * 120, finalResultTimeoutSeconds: Double = 10,
                factory: ASRBackendFactory? = nil, qwenFactory: @escaping @Sendable () -> any QwenWorkerTransport = { QwenProcessBridge() }) {
        self.providerID = providerID; self.factory = factory ?? .apple
        self.qwenFactory = qwenFactory
        self.maxInputFrames = maxInputFrames; finalTimeout = finalResultTimeoutSeconds
    }
    private func validate(_ config: ASRConfiguration) throws {
        guard config.providerID == providerID else { throw ASRProviderError.providerMismatch }
        guard providerID == .appleSpeech || providerID == .qwen3ASR else { throw ASRProviderError.unsupportedProvider }
        guard maxInputFrames > 0, finalTimeout.isFinite, finalTimeout > 0 else { throw ASRProviderError.invalidConfiguration("INVALID_LIMITS") }
        if providerID == .appleSpeech {
            guard config.modelPath == nil else { throw ASRProviderError.invalidConfiguration("APPLE_MODEL_IS_SYSTEM_MANAGED") }
        } else {
            guard let path = config.modelPath, path.hasPrefix("/"), !path.contains("\0") else { throw ASRProviderError.invalidConfiguration("ABSOLUTE_MODEL_DIRECTORY_REQUIRED") }
            guard (config.terminologyContext?.utf8.count ?? 0) <= 4096 else { throw ASRProviderError.invalidConfiguration("CONTEXT_TOO_LARGE") }
            let runtime = config.qwenRuntime ?? .adjacent(toModelDirectory: path)
            guard runtime.timeoutSeconds.isFinite, runtime.timeoutSeconds > 0, runtime.timeoutSeconds <= 600 else { throw ASRProviderError.invalidConfiguration("INVALID_QWEN_TIMEOUT") }
            guard [runtime.pythonExecutableURL, runtime.modelManifestURL, runtime.referenceDirectoryURL].allSatisfy({ $0.isFileURL && $0.path.hasPrefix("/") && !$0.path.contains("\0") }) else { throw ASRProviderError.invalidConfiguration("ABSOLUTE_RUNTIME_PATH_REQUIRED") }
        }
    }
    public func inspect(_ config: ASRConfiguration) -> ASRReadiness {
        do { try validate(config) } catch { return .init(.invalidConfiguration, reason: String(describing: error)) }
        if providerID == .qwen3ASR {
            #if !arch(arm64)
            return .init(.unavailable, reason: "MAC_ARM64_REQUIRED")
            #else
            guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 else { return .init(.unavailable, reason: "MACOS_26_REQUIRED_FOR_PINNED_RUNTIME") }
            let path = config.modelPath!
            let runtime = config.qwenRuntime ?? .adjacent(toModelDirectory: path)
            guard FileManager.default.isExecutableFile(atPath: runtime.pythonExecutableURL.path) else { return .init(.unavailable, reason: "QWEN_PYTHON_MISSING") }
            guard FileManager.default.fileExists(atPath: runtime.modelManifestURL.path),
                  FileManager.default.fileExists(atPath: runtime.referenceDirectoryURL.appendingPathComponent("src/qwen3_asr_mlx/model.py").path),
                  FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).appendingPathComponent("model.safetensors").path) else { return .init(.unavailable, reason: "QWEN_ASSETS_MISSING") }
            if activeConfiguration == config, activeEngine != nil, qwenSession != nil { return .init(.prepared) }
            return .init(.readyToPrepare, reason: "PATHS_PRESENT_NOT_YET_HASHED_OR_LOADED")
            #endif
        }
        let probe = factory.inspect(config.locale)
        if probe.state == .readyToPrepare, activeEngine != nil, activeConfiguration == config { return .init(.prepared) }
        return probe
    }
    @discardableResult public func load(_ config: ASRConfiguration) throws -> ASREngineIdentity {
        do {
            guard state != .listening && state != .finishing && state != .loading else { throw ASRProviderError.activeRecognition }
            try validate(config)
            guard providerID == .appleSpeech else { throw ASRProviderError.qwen("ASYNC_LOAD_REQUIRED") }
            let probe = factory.inspect(config.locale)
            guard probe.state == .readyToPrepare || probe.state == .prepared else { throw ASRProviderError.readiness(probe) }
            // Create candidate before replacing active backend; failures preserve the previous active configuration.
            let candidate = try AppleOfflineSpeechAdapter(maxInputFrames: maxInputFrames, finalResultTimeoutSeconds: finalTimeout, backend: factory.make())
            adapter?.cancel(); generation &+= 1
            let identity = ASREngineIdentity(providerID: providerID, engineVersion: factory.engineVersion,
                                             modelVersion: nil, locale: config.locale.rawValue, generation: generation)
            adapter = candidate; activeConfiguration = config; activeEngine = identity; state = .prepared; lastFailure = nil
            return identity
        } catch {
            let failure = error as? ASRProviderError ?? .invalidConfiguration("PREPARE_FAILED")
            lastFailure = failure; throw failure
        }
    }
    /// Qwen changes replace the old process after validation; failure then requires reload.
    /// Apple retains its existing synchronous preparation behavior.
    @discardableResult public func loadAsync(_ config: ASRConfiguration) async throws -> ASREngineIdentity {
        if providerID == .appleSpeech { return try load(config) }
        guard state != .loading && state != .listening && state != .finishing else { throw ASRProviderError.activeRecognition }
        try validate(config)
        let readiness = inspect(config)
        guard readiness.state == .readyToPrepare || readiness.state == .prepared else {
            let error = ASRProviderError.readiness(readiness); lastFailure = error; throw error
        }
        if readiness.state == .prepared, let activeEngine { return activeEngine }
        generation &+= 1; let token = generation
        qwenSession?.stop(); qwenSession = nil; activeEngine = nil; activeConfiguration = nil; qwenLoadAcknowledgement = nil
        let session = qwenFactory(); qwenSession = session; state = .loading; lastFailure = nil
        session.setExitHandler { [weak self] status in
            Task { @MainActor in
                guard let self, token == self.generation, self.qwenSession != nil else { return }
                self.generation &+= 1; self.qwenSession = nil; self.activeEngine = nil; self.activeConfiguration = nil
                self.qwenLoadAcknowledgement = nil; self.state = .failed; self.lastFailure = .qwen("WORKER_EXITED_\(status)")
            }
        }
        do {
            let ack = try await session.load(runtime: config.qwenRuntime ?? .adjacent(toModelDirectory: config.modelPath!), modelPath: config.modelPath!, context: config.terminologyContext)
            guard token == generation, !Task.isCancelled else { throw QwenBridgeError.cancelled }
            guard ack.loadSeconds.isFinite, ack.loadSeconds >= 0, ack.workerPID > 0,
                  !ack.engineVersion.isEmpty, ack.modelVersion == "mlx-community/Qwen3-ASR-1.7B-bf16@e1f6c266914abc5a46e8756e02580f834a6cf8a7" else { throw QwenBridgeError.protocolFailure("INVALID_LOAD_ACK") }
            let identity = ASREngineIdentity(providerID: .qwen3ASR, engineVersion: ack.engineVersion, modelVersion: ack.modelVersion, locale: "auto", generation: token)
            activeConfiguration = config; activeEngine = identity; qwenLoadAcknowledgement = ack; state = .prepared
            return identity
        } catch {
            session.stop()
            if token == generation {
                generation &+= 1; qwenSession = nil; activeEngine = nil; activeConfiguration = nil
                state = .failed; lastFailure = .qwen(String(describing: error))
            }
            throw ASRProviderError.qwen(String(describing: error))
        }
    }
    /// Whole, closed mono16k audio segment only. max8s/40MB, no partials or word timestamps.
    /// The caller freezes context at load; concurrent calls are rejected, never queued silently.
    public func transcribeSegment(fileURL: URL, expectedAudioSHA256: String? = nil) async throws -> QwenSegmentResult {
        guard providerID == .qwen3ASR else { throw ASRProviderError.unsupportedProvider }
        guard state != .loading && state != .finishing && state != .listening else { throw ASRProviderError.activeRecognition }
        guard let session = qwenSession, let identity = activeEngine, let config = activeConfiguration else { throw ASRProviderError.notPrepared }
        guard fileURL.isFileURL, fileURL.path.hasPrefix("/"), !fileURL.path.contains("\0") else { throw ASRProviderError.invalidConfiguration("ABSOLUTE_AUDIO_FILE_REQUIRED") }
        if let sha = expectedAudioSHA256, sha.count != 64 || !sha.allSatisfy({ $0.isHexDigit }) { throw ASRProviderError.invalidConfiguration("INVALID_AUDIO_SHA256") }
        let token = generation, requestID = UUID().uuidString
        state = .finishing; lastFailure = nil
        do {
            let ack = try await session.transcribe(fileURL: fileURL, requestID: requestID, context: config.terminologyContext, expectedAudioSHA256: expectedAudioSHA256)
            guard token == generation, !Task.isCancelled else { throw QwenBridgeError.cancelled }
            let empty = ack.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard !empty || ack.noSpeech == true else { throw QwenBridgeError.protocolFailure("EMPTY_TRANSCRIPT") }
            guard ack.noSpeech != true || empty else { throw QwenBridgeError.protocolFailure("INVALID_NO_SPEECH_RESULT") }
            guard !ack.generations.isEmpty, ack.generations.allSatisfy({ $0.endedWithEOS && [151643,151645].contains($0.tokenIDs.last ?? -1) }) else { throw QwenBridgeError.protocolFailure("DECODE_NOT_TERMINATED_WITH_EOS") }
            guard ack.engineVersion == identity.engineVersion, ack.modelVersion == identity.modelVersion,
                  ack.workerPID == qwenLoadAcknowledgement?.workerPID,
                  ack.duration.isFinite, ack.duration > 0, ack.duration <= 8,
                  ack.elapsedSeconds.isFinite, ack.elapsedSeconds >= 0,
                  ack.audioSHA256.count == 64,
                  expectedAudioSHA256 == nil || expectedAudioSHA256 == ack.audioSHA256 else { throw QwenBridgeError.protocolFailure("RESULT_IDENTITY_OR_AUDIO_MISMATCH") }
            let raw = try ack.rawResponseJSON ?? String(data: JSONEncoder().encode(ack), encoding: .utf8)!
            state = .finalized
            return QwenSegmentResult(text: ack.text, language: ack.language, audioSHA256: ack.audioSHA256, requestID: requestID,
                                     duration: ack.duration, elapsedSeconds: ack.elapsedSeconds, engine: identity, rawResponseJSON: raw, noSpeech: ack.noSpeech == true)
        } catch {
            session.stop()
            if token == generation {
                generation &+= 1; qwenSession = nil; activeEngine = nil; activeConfiguration = nil; qwenLoadAcknowledgement = nil
                state = .failed; lastFailure = .qwen(String(describing: error))
            }
            throw ASRProviderError.qwen(String(describing: error))
        }
    }
    public func start(intent: SpeechStartIntent, sessionID: String, channelID: String, streamID: String, segmentID: String,
                      deliver: @escaping @MainActor @Sendable (ASRProviderEvent) -> Void) throws {
        guard let adapter, let config = activeConfiguration, let identity = activeEngine else { throw ASRProviderError.notPrepared }
        guard state != .listening && state != .finishing else { throw ASRProviderError.activeRecognition }
        let token = generation
        do {
            try adapter.start(intent: intent, locale: config.locale, sessionId: sessionID, channelId: channelID, streamId: streamID, segmentId: segmentID) { [weak self] output in
                guard let self, token == self.generation else { return }
                switch output {
                case .transcript(let update): if update.status == "final" { self.state = .finalized }
                case .failed(let failure): self.state = .failed; self.lastFailure = .speech(failure)
                }
                deliver(ASRProviderEvent(engine: identity, output: output))
            }
            state = ASRProviderState(rawValue: adapter.state.rawValue) ?? .failed
            if state == .listening { lastFailure = nil }
        } catch { let e = ASRProviderError.speech(error as? OfflineSpeechFailure ?? .backend("START_FAILED")); lastFailure = e; throw e }
    }
    public func append(_ buffer: AVAudioPCMBuffer, source: PCMSourceRange) throws {
        guard let adapter else { throw ASRProviderError.notPrepared }
        do { try adapter.append(buffer, source: source) }
        catch { let e = ASRProviderError.speech(error as? OfflineSpeechFailure ?? .backend("APPEND_FAILED")); lastFailure = e; throw e }
    }
    public func finishAudio(atUptime: Double = ProcessInfo.processInfo.systemUptime) throws {
        guard let adapter else { throw ASRProviderError.notPrepared }
        do { try adapter.finishAudio(atUptime: atUptime); state = ASRProviderState(rawValue: adapter.state.rawValue) ?? .failed }
        catch { let e = ASRProviderError.speech(error as? OfflineSpeechFailure ?? .backend("FINISH_FAILED")); lastFailure = e; throw e }
    }
    public func pollFinalDeadline(atUptime: Double = ProcessInfo.processInfo.systemUptime) { adapter?.pollFinalDeadline(atUptime: atUptime) }
    public func cancel() {
        generation &+= 1; adapter?.cancel()
        if providerID == .qwen3ASR {
            qwenSession?.stop(); qwenSession = nil; activeEngine = nil; activeConfiguration = nil; qwenLoadAcknowledgement = nil; state = .cancelled
        } else { state = activeEngine == nil ? .idle : .cancelled }
    }
    public func unload() {
        generation &+= 1; adapter?.cancel(); adapter = nil; qwenSession?.stop(); qwenSession = nil
        activeEngine = nil; activeConfiguration = nil; qwenLoadAcknowledgement = nil; state = .idle
    }
}
