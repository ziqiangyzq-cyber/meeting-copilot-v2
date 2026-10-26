import Foundation
import CryptoKit
import AVFoundation
import AppleOfflineSpeech
import LocalASRProviders
import MeetingCopilotAudioCapture
import MeetingCopilotPCMBridge

public struct QwenBatchResult: Sendable {
    public let text: String, language: String
    public let engine: ASREngineIdentity
    public let noSpeech: Bool
    public init(text: String, language: String, engine: ASREngineIdentity, noSpeech: Bool = false) {
        self.text = text; self.language = language; self.engine = engine
        self.noSpeech = noSpeech
    }
}
@MainActor public protocol QwenSegmentBackend: AnyObject {
    func preparedEngine(for configuration: ASRConfiguration) -> ASREngineIdentity?
    func load(_ configuration: ASRConfiguration) async throws -> ASREngineIdentity
    func transcribe(fileURL: URL, context: String?) async throws -> QwenBatchResult
    func cancel()
    func unload()
}

@MainActor public final class ProductionQwenSegmentBackend: QwenSegmentBackend {
    public let provider: LocalASRProvider
    public private(set) var lastResult: QwenSegmentResult?
    public init(provider: LocalASRProvider? = nil) { self.provider = provider ?? LocalASRProvider(providerID: .qwen3ASR) }
    public func preparedEngine(for configuration: ASRConfiguration) -> ASREngineIdentity? {
        guard provider.activeConfiguration == configuration, provider.state == .prepared || provider.state == .finalized else { return nil }
        return provider.activeEngine
    }
    public func load(_ configuration: ASRConfiguration) async throws -> ASREngineIdentity {
        try await provider.loadAsync(configuration)
    }
    public func transcribe(fileURL: URL, context: String?) async throws -> QwenBatchResult {
        guard provider.activeConfiguration?.terminologyContext == context else { throw QwenControllerError.invalidConfiguration }
        let sha = try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: fileURL); defer { try? handle.close() }
            var hash = SHA256()
            while let bytes = try handle.read(upToCount: 65536), !bytes.isEmpty { hash.update(data: bytes) }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
        try Task.checkCancellation()
        let r = try await provider.transcribeSegment(fileURL: fileURL, expectedAudioSHA256: sha)
        lastResult = r
        return QwenBatchResult(text: r.text, language: r.language, engine: r.engine, noSpeech: r.noSpeech)
    }
    public func cancel() { provider.cancel() }
    public func unload() { provider.unload() }
}

/// Borrowed device PCM is copied synchronously. Sealing serializes with enqueue.
public final class QwenPCMIngress: @unchecked Sendable {
    let queue: BoundedPCMQueue
    let generation: PCMGeneration
    private let lock = NSLock()
    private var open = true
    private var violation: PCMQueueFailure?
    var failure: PCMQueueFailure? { lock.lock(); defer { lock.unlock() }; return violation }
    init(queue: BoundedPCMQueue, generation: PCMGeneration) {
        self.queue = queue; self.generation = generation
    }
    @discardableResult public func enqueue(_ frame: AudioFrame) -> PCMEnqueueResult {
        lock.lock(); defer { lock.unlock() }
        guard open else { return .rejectedInactive }
        if let violation { return .failed(violation) }
        let format = frame.buffer.format
        guard format.channelCount >= 1, format.channelCount <= 8, format.commonFormat == .pcmFormatFloat32,
              format.sampleRate.isFinite, (16000...192000).contains(format.sampleRate) else {
            let error = PCMQueueFailure.invalidPCM("QWEN_NATIVE_FORMAT_LIMIT")
            violation = error; return .failed(error)
        }
        return queue.enqueue(frame, generation: generation)
    }
    public var handler: AudioFrameHandler { { [self] in _ = enqueue($0) } }
    func seal() { lock.lock(); open = false; lock.unlock() }
}

struct QwenNativePCM: Sendable {
    let samples: [Float]
    let rate: Double
}
/// Owns a unique queue-drained buffer until its off-main conversion completes.
struct QwenOwnedBuffer: @unchecked Sendable { let buffer: AVAudioPCMBuffer }
actor QwenFileIO {
    private var input: AVAudioFile?
    func open(_ url: URL) throws {
        input = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    }
    func read(maximumFrames: UInt32) throws -> QwenNativePCM? {
        guard let input else { throw QwenControllerError.invalidPCM }
        guard input.framePosition < input.length else { return nil }
        let n = AVAudioFrameCount(min(Int64(maximumFrames), input.length - input.framePosition))
        guard let b = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: n) else { throw QwenControllerError.invalidPCM }
        try input.read(into: b, frameCount: n)
        return try Self.extract(b)
    }
    func close() { input = nil }
    nonisolated static func extract(_ b: AVAudioPCMBuffer) throws -> QwenNativePCM {
        guard b.frameLength > 0, b.format.sampleRate.isFinite, b.format.sampleRate >= 16000,
              b.format.sampleRate <= 192000, b.format.channelCount > 0, b.format.channelCount <= 8,
              !b.format.isInterleaved, let channels = b.floatChannelData else { throw QwenControllerError.invalidPCM }
        let count = Int(b.frameLength), c = Int(b.format.channelCount)
        var samples = [Float](repeating: 0, count: count)
        for i in 0..<count {
            var v: Float = 0
            for channel in 0..<c { v += channels[channel][i] / Float(c) }
            guard v.isFinite else { throw QwenControllerError.invalidPCM }
            samples[i] = v
        }
        return QwenNativePCM(samples: samples, rate: b.format.sampleRate)
    }
    func write(_ pcm: QwenNativePCM, directory: URL, sequence: Int) throws -> URL {
        guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: pcm.rate, channels: 1, interleaved: false),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let b = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: UInt32(pcm.samples.count)),
              let converter = AVAudioConverter(from: source, to: target) else { throw QwenControllerError.invalidPCM }
        b.frameLength = UInt32(pcm.samples.count)
        pcm.samples.withUnsafeBufferPointer { ptr in b.floatChannelData![0].update(from: ptr.baseAddress!, count: ptr.count) }
        let url = directory.appendingPathComponent("segment-\(sequence).wav")
        let file = try AVAudioFile(forWriting: url, settings: target.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        var supplied = false
        while true {
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 16384) else { throw QwenControllerError.invalidPCM }
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, state in
                if supplied { state.pointee = .endOfStream; return nil }
                supplied = true; state.pointee = .haveData; return b
            }
            if let error { throw error }
            if out.frameLength > 0 { try file.write(from: out) }
            if status == .endOfStream { break }
            if status == .error || out.frameLength == 0 { throw QwenControllerError.invalidPCM }
        }
        return url
    }
    func removeSegment(_ url: URL, directory: URL) throws {
        guard url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
              url.lastPathComponent.hasPrefix("segment-"), url.pathExtension == "wav" else { throw QwenControllerError.invalidConfiguration }
        try FileManager.default.removeItem(at: url)
    }
    func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-copilot-qwen-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    func removeDirectory(_ url: URL) throws {
        let parent = url.deletingLastPathComponent().standardizedFileURL
        guard parent == FileManager.default.temporaryDirectory.standardizedFileURL,
              url.lastPathComponent.hasPrefix("meeting-copilot-qwen-") else { throw QwenControllerError.invalidConfiguration }
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
