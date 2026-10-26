import Foundation
import Darwin

/// Pinned development runtime, separate from the Swift app's macOS deployment target.
public struct QwenRuntimeConfiguration: Equatable, Sendable {
    public let pythonExecutableURL: URL
    public let modelManifestURL: URL
    public let referenceDirectoryURL: URL
    public let timeoutSeconds: Double
    public init(pythonExecutableURL: URL, modelManifestURL: URL, referenceDirectoryURL: URL, timeoutSeconds: Double = 600) {
        self.pythonExecutableURL = pythonExecutableURL; self.modelManifestURL = modelManifestURL
        self.referenceDirectoryURL = referenceDirectoryURL; self.timeoutSeconds = timeoutSeconds
    }
    public static func adjacent(toModelDirectory path: String) -> Self {
        let root = URL(fileURLWithPath: path).deletingLastPathComponent()
        return .init(pythonExecutableURL: root.appendingPathComponent(".venv-local/bin/python"),
                     modelManifestURL: root.appendingPathComponent("model-assets.json"), referenceDirectoryURL: root.appendingPathComponent("reference"))
    }
}
public enum QwenBridgeError: Error, Equatable, Sendable {
    case unavailable(String), protocolFailure(String), workerExited(Int32), timeout, cancelled, invalidInput(String)
}
public struct QwenGeneration: Codable, Equatable, Sendable {
    public let tokenIDs: [Int]
    public let endedWithEOS: Bool
    public let rawDecoded: String
    public init(tokenIDs: [Int], endedWithEOS: Bool, rawDecoded: String) { self.tokenIDs = tokenIDs; self.endedWithEOS = endedWithEOS; self.rawDecoded = rawDecoded }
}
public struct QwenLoadAcknowledgement: Codable, Sendable {
    public fileprivate(set) var rawResponseJSON: String?
    public let engineVersion: String, modelVersion: String
    public let loadSeconds: Double
    public let workerPID: Int
    public init(engineVersion: String, modelVersion: String, loadSeconds: Double, workerPID: Int) {
        self.engineVersion = engineVersion; self.modelVersion = modelVersion; self.loadSeconds = loadSeconds; self.workerPID = workerPID
    }
}
public struct QwenTranscriptAcknowledgement: Codable, Sendable {
    public fileprivate(set) var rawResponseJSON: String?
    public let text: String, language: String, audioSHA256: String, engineVersion: String, modelVersion: String
    public let duration: Double, elapsedSeconds: Double
    public let workerPID: Int
    public let generations: [QwenGeneration]
    public let noSpeech: Bool?
    public init(text: String, language: String, audioSHA256: String, engineVersion: String, modelVersion: String,
                duration: Double, elapsedSeconds: Double, workerPID: Int, generations: [QwenGeneration], noSpeech: Bool? = nil) {
        self.text = text; self.language = language; self.audioSHA256 = audioSHA256; self.engineVersion = engineVersion; self.modelVersion = modelVersion
        self.duration = duration; self.elapsedSeconds = elapsedSeconds; self.workerPID = workerPID; self.generations = generations
        self.noSpeech = noSpeech
    }
}
/// Only a complete batch final. Source ranges/session event sequences are owned by the caller.
public struct QwenSegmentResult: Sendable {
    public let text: String, language: String, audioSHA256: String, requestID: String
    public let duration: Double, elapsedSeconds: Double
    public let engine: ASREngineIdentity
    public let rawResponseJSON: String
    public let noSpeech: Bool
    public init(text: String, language: String, audioSHA256: String, requestID: String, duration: Double, elapsedSeconds: Double, engine: ASREngineIdentity, rawResponseJSON: String, noSpeech: Bool = false) {
        self.text = text; self.language = language; self.audioSHA256 = audioSHA256; self.requestID = requestID
        self.duration = duration; self.elapsedSeconds = elapsedSeconds; self.engine = engine; self.rawResponseJSON = rawResponseJSON
        self.noSpeech = noSpeech
    }
}
/// Injection boundary for lifecycle checks; only the process implementation is selectable in production.
public protocol QwenWorkerTransport: AnyObject, Sendable {
    func setExitHandler(_ handler: @escaping @Sendable (Int32) -> Void)
    func load(runtime: QwenRuntimeConfiguration, modelPath: String, context: String?) async throws -> QwenLoadAcknowledgement
    func transcribe(fileURL: URL, requestID: String, context: String?, expectedAudioSHA256: String?) async throws -> QwenTranscriptAcknowledgement
    func stop()
}

/// One private process per provider; one global GPU lease is acquired by the worker at load.
/// Blocking pipe I/O, hashing, loading and Python work all run off MainActor.
public final class QwenProcessBridge: QwenWorkerTransport, @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.github.ziqiangyzq-cyber.meeting-copilot.qwen.worker")
    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?, output: FileHandle?
    private var stopped = false
    private var timedOut = false
    private var timeoutSeconds: Double = 600
    private var exitHandler: (@Sendable (Int32) -> Void)?
    private var stderrTail = Data()
    public init() {}
    public func setExitHandler(_ handler: @escaping @Sendable (Int32) -> Void) { lock.withLock { exitHandler = handler } }
    public func stop() {
        let p = lock.withLock { () -> Process? in stopped = true; return process }
        if let p, p.isRunning {
            // SIGKILL is intentional: Metal decode cannot consume a cooperative stdin cancel.
            Darwin.kill(p.processIdentifier, SIGKILL)
        }
    }
    deinit { stop() }
    public func load(runtime: QwenRuntimeConfiguration, modelPath: String, context: String?) async throws -> QwenLoadAcknowledgement {
        lock.withLock { timeoutSeconds = runtime.timeoutSeconds }
        let data = try await operation { [self] in
            guard !self.lock.withLock({ self.stopped }) else { throw QwenBridgeError.cancelled }
            let p = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            guard let script = Bundle.module.url(forResource: "qwen_worker_v2", withExtension: "py", subdirectory: "Resources") else { throw QwenBridgeError.unavailable("WORKER_RESOURCE_MISSING") }
            p.executableURL = runtime.pythonExecutableURL
            let contextJSON = String(data: try JSONSerialization.data(withJSONObject: context.map { $0 as Any } ?? NSNull(), options: [.fragmentsAllowed]), encoding: .utf8)!
            p.arguments = ["-B", "-u", script.path, modelPath, runtime.modelManifestURL.path, runtime.referenceDirectoryURL.path, contextJSON]
            p.currentDirectoryURL = FileManager.default.temporaryDirectory
            var env = ProcessInfo.processInfo.environment
            env.removeValue(forKey: "PYTHONPATH"); env.removeValue(forKey: "PYTHONHOME")
            env["PYTHONDONTWRITEBYTECODE"] = "1"; env["HF_HUB_OFFLINE"] = "1"
            p.environment = env; p.standardInput = stdin; p.standardOutput = stdout; p.standardError = stderr
            stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let bytes = handle.availableData
                guard let self else { return }
                self.lock.withLock {
                    self.stderrTail.append(bytes)
                    if self.stderrTail.count > 8192 { self.stderrTail = Data(self.stderrTail.suffix(8192)) }
                }
            }
            p.terminationHandler = { [weak self] ended in
                stderr.fileHandleForReading.readabilityHandler = nil
                guard let self else { return }
                let handler = self.lock.withLock { self.exitHandler }
                handler?(ended.terminationStatus)
            }
            self.lock.withLock { self.process = p; self.input = stdin.fileHandleForWriting; self.output = stdout.fileHandleForReading; self.timeoutSeconds = runtime.timeoutSeconds }
            try p.run()
            // A cancel can race Process.run; check after launch as well.
            guard !self.lock.withLock({ self.stopped }) else { self.stop(); throw QwenBridgeError.cancelled }
            return try self.readReply(id: "load", expectedType: "loaded")
        }
        var ack = try JSONDecoder().decode(QwenLoadAcknowledgement.self, from: data)
        ack.rawResponseJSON = String(data: data, encoding: .utf8)
        return ack
    }
    public func transcribe(fileURL: URL, requestID: String, context: String?, expectedAudioSHA256: String?) async throws -> QwenTranscriptAcknowledgement {
        let data = try await operation { [self] in
            guard !self.lock.withLock({ self.stopped }), let input = self.input else { throw QwenBridgeError.cancelled }
            var request: [String: Any] = ["protocol": 1, "command": "transcribe", "id": requestID, "filePath": fileURL.path]
            request["context"] = context.map { $0 as Any } ?? NSNull()
            if let expectedAudioSHA256 { request["expectedAudioSHA256"] = expectedAudioSHA256 }
            var bytes = try JSONSerialization.data(withJSONObject: request); bytes.append(10)
            guard bytes.count <= 16384 else { throw QwenBridgeError.invalidInput("REQUEST_TOO_LARGE") }
            try input.write(contentsOf: bytes)
            return try self.readReply(id: requestID, expectedType: "final")
        }
        var ack = try JSONDecoder().decode(QwenTranscriptAcknowledgement.self, from: data)
        ack.rawResponseJSON = String(data: data, encoding: .utf8)
        return ack
    }
    private func operation(_ work: @escaping @Sendable () throws -> Data) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    let deadline = DispatchWorkItem { [weak self] in
                        self?.lock.withLock { self?.timedOut = true }
                        self?.stop()
                    }
                    let limit = self.lock.withLock { self.timeoutSeconds }
                    DispatchQueue.global().asyncAfter(deadline: .now() + limit, execute: deadline)
                    defer { deadline.cancel() }
                    do { continuation.resume(returning: try work()) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { self.stop() }
    }
    private func readReply(id: String, expectedType: String) throws -> Data {
        guard let output else { throw QwenBridgeError.protocolFailure("NO_STDOUT") }
        var line = Data()
        while line.count < 131072 {
            guard let byte = try output.read(upToCount: 1), !byte.isEmpty else {
                if lock.withLock({ timedOut }) { throw QwenBridgeError.timeout }
                if lock.withLock({ stopped }) { throw QwenBridgeError.cancelled }
                let tail = lock.withLock { String(data: stderrTail, encoding: .utf8) ?? "" }
                throw QwenBridgeError.protocolFailure("WORKER_EOF:" + tail)
            }
            if byte[0] == 10 { break }; line.append(byte)
        }
        guard line.count < 131072,
              let reply = try JSONSerialization.jsonObject(with: line) as? [String: Any],
              reply["protocol"] as? Int == 1, reply["id"] as? String == id else { stop(); throw QwenBridgeError.protocolFailure("INVALID_REPLY") }
        if reply["type"] as? String == "error" { throw QwenBridgeError.protocolFailure(reply["error"] as? String ?? "WORKER_ERROR") }
        guard reply["type"] as? String == expectedType else { stop(); throw QwenBridgeError.protocolFailure("UNEXPECTED_REPLY") }
        return line
    }
}
