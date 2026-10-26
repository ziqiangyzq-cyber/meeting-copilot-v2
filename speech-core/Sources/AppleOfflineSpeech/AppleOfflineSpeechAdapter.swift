import Foundation
import AVFoundation
import SpeechCore

public enum OfflineSpeechLocale: String, Sendable { case simplifiedChinese = "zh-CN", englishUS = "en-US" }
public struct SpeechStartIntent: Sendable {
    public let userInitiated: Bool, speechEnabled: Bool, onDeviceProcessingAuthorized: Bool
    public init(userInitiated: Bool = false, speechEnabled: Bool = false, onDeviceProcessingAuthorized: Bool = false) {
        self.userInitiated = userInitiated; self.speechEnabled = speechEnabled
        self.onDeviceProcessingAuthorized = onDeviceProcessingAuthorized
    }
}
public enum OfflineSpeechFailure: Error, Equatable, Sendable {
    case userStartRequired, speechDisabled, explicitAuthorizationRequired, osAuthorizationMissing
    case localeUnsupported, onDeviceUnavailable, recognizerUnavailable, alreadyActive, notAcceptingPCM
    case invalidIdentity, invalidPCM, inputLimitExceeded, nonContiguousInput, formatChanged, noSourceAudio
    case invalidClock, finalResultTimeout
    case backend(String)
}
public enum SpeechStartGate {
    /// Intent is a caller assertion; UI action authenticity must be enforced by the client.
    public static func validate(_ intent: SpeechStartIntent, osAuthorized: Bool) throws {
        guard intent.userInitiated else { throw OfflineSpeechFailure.userStartRequired }
        guard intent.speechEnabled else { throw OfflineSpeechFailure.speechDisabled }
        guard intent.onDeviceProcessingAuthorized else { throw OfflineSpeechFailure.explicitAuthorizationRequired }
        guard osAuthorized else { throw OfflineSpeechFailure.osAuthorizationMissing }
    }
}
public struct PCMSourceRange: Equatable, Sendable {
    public let frameStart: Int, frameEnd: Int, mappingRevision: Int
    public let startNs: UInt64, endNs: UInt64
    public init(frameStart: Int, frameEnd: Int, mappingRevision: Int, startNs: UInt64, endNs: UInt64) {
        self.frameStart = frameStart; self.frameEnd = frameEnd; self.mappingRevision = mappingRevision
        self.startNs = startNs; self.endNs = endNs
    }
}
public struct OfflineTranscriptUpdate: Equatable, Sendable {
    public let sessionId: String, channelId: String, streamId: String, segmentId: String
    public let locale: OfflineSpeechLocale, revision: Int, replacesRevision: Int?
    public let status: String, text: String, source: PCMSourceRange
    /// Caller owns the one session-wide event sequence. This engine never allocates it.
    public func event(id: String, sequence: Int, emittedAtNs: UInt64) -> SpeechEvent {
        var event = SpeechEvent(id: id, session: sessionId, sequence: sequence, type: "asr.segment", timeNs: String(emittedAtNs))
        event.segmentId = segmentId; event.channelId = channelId; event.streamId = streamId
        event.revision = revision; event.replacesRevision = replacesRevision; event.status = status; event.text = text
        event.startNs = String(source.startNs); event.endNs = String(source.endNs); event.speakerId = nil
        event.sourceSpans = [SourceAudioSpan(channelId: channelId, streamId: streamId, frameStart: source.frameStart, frameEnd: source.frameEnd, mappingRevision: source.mappingRevision)]
        return event
    }
}
public enum SpeechBackendObservation: Sendable {
    case hypothesis(text: String, isFinal: Bool)
    case failure(String)
}
public enum OfflineSpeechOutput: Equatable, Sendable {
    case transcript(OfflineTranscriptUpdate)
    case failed(OfflineSpeechFailure)
}
/// Replaceable backend boundary. Concrete Apple backend is always on-device-only.
@MainActor public protocol OfflinePCMRecognitionBackend: AnyObject {
    var osAuthorized: Bool { get }
    func begin(locale: OfflineSpeechLocale, deliver: @escaping @MainActor @Sendable (SpeechBackendObservation) -> Void) throws
    func append(_ buffer: AVAudioPCMBuffer) throws
    func finishAudio()
    func cancel()
}
public enum OfflineSpeechState: String, Sendable { case idle, listening, finishing, finalized, cancelled, failed }

@MainActor public final class AppleOfflineSpeechAdapter {
    public private(set) var state: OfflineSpeechState = .idle
    public private(set) var failure: OfflineSpeechFailure?
    private let backend: any OfflinePCMRecognitionBackend
    private let maxInputFrames: Int
    private let finalResultTimeoutSeconds: Double
    private var finishBeganAt: Double?
    private var generation: UInt64 = 0
    private var identity: (session: String, channel: String, stream: String, segment: String, locale: OfflineSpeechLocale)?
    private var source: PCMSourceRange?, inputFrames = 0, revision = 0
    private var lastText: String?
    private var usedSegments: Set<[String]> = []
    private var sampleRate: Double?, channels: AVAudioChannelCount?, commonFormat: AVAudioCommonFormat?, interleaved: Bool?
    private var sink: (@MainActor @Sendable (OfflineSpeechOutput) -> Void)?
    public init(maxInputFrames: Int, finalResultTimeoutSeconds: Double, backend: (any OfflinePCMRecognitionBackend)? = nil) throws {
        guard maxInputFrames > 0 else { throw OfflineSpeechFailure.inputLimitExceeded }
        guard finalResultTimeoutSeconds.isFinite, finalResultTimeoutSeconds > 0 else { throw OfflineSpeechFailure.invalidClock }
        self.maxInputFrames = maxInputFrames; self.finalResultTimeoutSeconds = finalResultTimeoutSeconds
        self.backend = backend ?? AppleOnDeviceBackend()
    }
    public func start(intent: SpeechStartIntent, locale: OfflineSpeechLocale, sessionId: String, channelId: String, streamId: String, segmentId: String,
                      deliver: @escaping @MainActor @Sendable (OfflineSpeechOutput) -> Void) throws {
        try SpeechStartGate.validate(intent, osAuthorized: backend.osAuthorized)
        guard state != .listening && state != .finishing else { throw OfflineSpeechFailure.alreadyActive }
        guard [sessionId, channelId, streamId, segmentId].allSatisfy({ !$0.isEmpty }), !usedSegments.contains([sessionId, segmentId]) else { throw OfflineSpeechFailure.invalidIdentity }
        usedSegments.insert([sessionId, segmentId])
        generation &+= 1; let token = generation
        identity = (sessionId, channelId, streamId, segmentId, locale)
        source = nil; inputFrames = 0; revision = 0; lastText = nil; finishBeganAt = nil
        sampleRate = nil; channels = nil; commonFormat = nil; interleaved = nil; failure = nil; sink = deliver
        state = .listening
        do {
            try backend.begin(locale: locale) { [weak self] observation in
                guard let self, self.generation == token else { return }
                self.observe(observation)
            }
        } catch {
            let failure = error as? OfflineSpeechFailure ?? .backend("START_FAILED")
            fail(failure); throw failure
        }
    }
    /// Call on MainActor using an owned copy, never send borrowed capture buffers across executors.
    public func append(_ buffer: AVAudioPCMBuffer, source range: PCMSourceRange) throws {
        guard state == .listening else { throw OfflineSpeechFailure.notAcceptingPCM }
        do {
            guard backend.osAuthorized else { throw OfflineSpeechFailure.osAuthorizationMissing }
            let frames = Int(buffer.frameLength)
            guard frames > 0, buffer.frameLength <= buffer.frameCapacity,
                  buffer.format.sampleRate.isFinite, buffer.format.sampleRate > 0, buffer.format.channelCount > 0,
                  range.frameStart >= 0, range.frameEnd > range.frameStart,
                  range.frameEnd - range.frameStart == frames, range.mappingRevision > 0, range.startNs < range.endNs else { throw OfflineSpeechFailure.invalidPCM }
            guard frames <= maxInputFrames - inputFrames else { throw OfflineSpeechFailure.inputLimitExceeded }
            if let source {
                guard range.frameStart == source.frameEnd, range.startNs >= source.endNs,
                      range.mappingRevision == source.mappingRevision else { throw OfflineSpeechFailure.nonContiguousInput }
            }
            if let sampleRate {
                guard sampleRate == buffer.format.sampleRate, channels == buffer.format.channelCount,
                      commonFormat == buffer.format.commonFormat, interleaved == buffer.format.isInterleaved else { throw OfflineSpeechFailure.formatChanged }
            }
            // The capture callback is never retained. This is memory-only copying, not capture/resampling.
            let owned = try Self.copyPCM(buffer)
            let previous = source
            source = PCMSourceRange(frameStart: previous?.frameStart ?? range.frameStart, frameEnd: range.frameEnd,
                                    mappingRevision: range.mappingRevision, startNs: previous?.startNs ?? range.startNs, endNs: range.endNs)
            inputFrames += frames; sampleRate = buffer.format.sampleRate; channels = buffer.format.channelCount
            commonFormat = buffer.format.commonFormat; interleaved = buffer.format.isInterleaved
            try backend.append(owned)
        } catch {
            let failure = error as? OfflineSpeechFailure ?? .backend("APPEND_FAILED")
            fail(failure); throw failure
        }
    }
    public func finishAudio(atUptime now: Double = ProcessInfo.processInfo.systemUptime) throws {
        guard state == .listening else { throw OfflineSpeechFailure.notAcceptingPCM }
        guard source != nil else { fail(.noSourceAudio); throw OfflineSpeechFailure.noSourceAudio }
        guard now.isFinite, now >= 0 else { fail(.invalidClock); throw OfflineSpeechFailure.invalidClock }
        finishBeganAt = now; state = .finishing; backend.finishAudio() // No fabricated final transcript.
    }
    /// Caller must schedule this poll on a bounded timer while finishing. Uses wait-clock only, never source audio time.
    public func pollFinalDeadline(atUptime now: Double = ProcessInfo.processInfo.systemUptime) {
        guard state == .finishing, let began = finishBeganAt else { return }
        guard now.isFinite, now >= began else { fail(.invalidClock); return }
        if now - began >= finalResultTimeoutSeconds { fail(.finalResultTimeout) }
    }
    public func cancel() {
        generation &+= 1; backend.cancel(); sink = nil; state = .cancelled
    }
    /// Capture discontinuity requires a new stream/task; never silently join missing audio.
    public func interrupt() { fail(.nonContiguousInput) }
    private func fail(_ reason: OfflineSpeechFailure) {
        generation &+= 1; backend.cancel(); state = .failed; failure = reason
        let callback = sink; sink = nil; callback?(.failed(reason))
    }
    private func observe(_ observation: SpeechBackendObservation) {
        guard state == .listening || state == .finishing else { return }
        switch observation {
        case .failure(let code): fail(.backend(code))
        case .hypothesis(let text, let isFinal):
            guard let source, let identity else { fail(.noSourceAudio); return }
            if !isFinal && text == lastText { return }
            revision += 1
            let update = OfflineTranscriptUpdate(sessionId: identity.session, channelId: identity.channel, streamId: identity.stream, segmentId: identity.segment,
                locale: identity.locale, revision: revision, replacesRevision: revision == 1 ? nil : revision - 1, status: isFinal ? "final" : "partial", text: text, source: source)
            lastText = text
            let callback = sink
            if isFinal { state = .finalized; generation &+= 1; backend.cancel(); sink = nil }
            callback?(.transcript(update))
        }
    }
    private static func copyPCM(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { throw OfflineSpeechFailure.invalidPCM }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == target.count else { throw OfflineSpeechFailure.invalidPCM }
        for i in source.indices {
            guard let src = source[i].mData, let dst = target[i].mData,
                  source[i].mDataByteSize > 0, source[i].mDataByteSize <= target[i].mDataByteSize else { throw OfflineSpeechFailure.invalidPCM }
            memcpy(dst, src, Int(source[i].mDataByteSize))
        }
        return copy
    }
}
