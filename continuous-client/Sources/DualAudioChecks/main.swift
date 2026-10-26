import Foundation
import AVFoundation
import ClientRuntime
import MeetingCopilotCore
import DesktopSessionController
import LocalASRProviders
import AppleOfflineSpeech
import MeetingCopilotAudioCapture

@MainActor func check(_ condition: Bool, _ reason: String) throws {
    if !condition { throw QwenControllerError.backend("CHECK_FAILED: " + reason) }
}
@MainActor final class TestBackend: QwenSegmentBackend {
    let identity = ASREngineIdentity(providerID: .qwen3ASR, engineVersion: "dual-fixture",
        modelVersion: "fixture", locale: "auto", generation: 1)
    var config: ASRConfiguration?
    var active = 0, highWater = 0, calls = 0, cancels = 0
    var hold = false, fail = false, cancelled = false
    var order: [String] = []
    func preparedEngine(for configuration: ASRConfiguration) -> ASREngineIdentity? {
        config == configuration && !cancelled ? identity : nil
    }
    func load(_ configuration: ASRConfiguration) async throws -> ASREngineIdentity {
        config = configuration; return identity
    }
    func transcribe(fileURL: URL, context: String?) async throws -> QwenBatchResult {
        active += 1; highWater = max(highWater, active); calls += 1
        order.append(fileURL.lastPathComponent)
        defer { active -= 1 }
        while hold && !cancelled { try await Task.sleep(nanoseconds: 1_000_000) }
        if cancelled { throw CancellationError() }
        if fail { throw QwenControllerError.backend("injected-inference-failure") }
        return .init(text: "Captured " + fileURL.lastPathComponent, language: "English", engine: identity)
    }
    func cancel() { cancelled = true; cancels += 1 }
    func unload() { cancel() }
}
@MainActor final class TestPermissions: DesktopPermissionGateway {
    func requestMicrophone() async -> Bool { true }
    func requestSpeech() async -> Bool { false }
}
@MainActor final class TestCapture: DesktopCapturePort {
    var state: CaptureState = .idle
    var onStateChange: (@MainActor @Sendable (CaptureState) -> Void)?
    var handler: AudioFrameHandler?
    func start(intent: CaptureIntent, onFrame: @escaping AudioFrameHandler) throws {
        handler = onFrame; state = .running
    }
    func stop() { state = .stopped; handler = nil }
}
@MainActor func until(_ condition: () -> Bool) async throws {
    for _ in 0..<2000 {
        if condition() { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    throw QwenControllerError.backend("test-timeout")
}
func buffer(_ frames: Int) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(frames))!
    b.frameLength = UInt32(frames)
    for i in 0..<frames { b.floatChannelData![0][i] = Float(sin(Double(i) * 0.02)) * 0.1 }
    return b
}
func interleavedStereoBuffer(_ frames: Int) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000,
                               channels: 2, interleaved: true)!
    let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(frames))!
    b.frameLength = UInt32(frames)
    for frame in 0..<frames {
        b.floatChannelData![0][frame * 2] = Float(sin(Double(frame) * 0.02)) * 0.1
        b.floatChannelData![0][frame * 2 + 1] = Float(cos(Double(frame) * 0.02)) * 0.1
    }
    return b
}
@main struct Checks {
    @MainActor static func main() async {
        do {
            let config = ASRConfiguration(providerID: .qwen3ASR, locale: .simplifiedChinese, modelPath: "/fixture")
            let backend = TestBackend(), serial = SerialQwenBackend(underlying: backend)
            _ = try await serial.load(config)
            backend.hold = true
            let first = Task { try await serial.transcribe(fileURL: URL(fileURLWithPath: "/tmp/first"), context: nil) }
            try await until { backend.calls == 1 }
            let second = Task { try await serial.transcribe(fileURL: URL(fileURLWithPath: "/tmp/second"), context: nil) }
            try await Task.sleep(nanoseconds: 10_000_000)
            let third = Task { try await serial.transcribe(fileURL: URL(fileURLWithPath: "/tmp/third"), context: nil) }
            try await Task.sleep(nanoseconds: 10_000_000)
            second.cancel()
            do { _ = try await second.value; throw QwenControllerError.backend("queued cancel accepted") }
            catch is CancellationError {}
            backend.hold = false
            _ = try await first.value; _ = try await third.value
            try check(backend.order == ["first", "third"] && backend.highWater == 1, "FIFO or queued cancellation broken")
            print("PASS one model operation at a time, FIFO and queued cancellation")

            backend.hold = true
            let active = Task { try await serial.transcribe(fileURL: URL(fileURLWithPath: "/tmp/active"), context: nil) }
            try await until { backend.calls == 3 }
            let waiting = Task { try await serial.transcribe(fileURL: URL(fileURLWithPath: "/tmp/waiting"), context: nil) }
            try await Task.sleep(nanoseconds: 10_000_000)
            serial.cancel()
            for task in [active, waiting] {
                do { _ = try await task.value; throw QwenControllerError.backend("global cancel accepted") }
                catch is CancellationError {}
            }
            try check(backend.cancels == 1 && backend.order.last == "active", "cancel sent queued inference")
            print("PASS pair cancellation rejects active and queued results, cancels model once")

            let inference = TestBackend(), shared = SerialQwenBackend(underlying: inference)
            _ = try await shared.load(config)
            let native = TestCapture(), permissions = TestPermissions()
            let limits = QwenSegmentLimits(segmentSeconds: 0.25)
            let mic = QwenSegmentController(backend: shared, permissions: permissions, microphone: native, limits: limits)
            let system = QwenSegmentController(backend: shared, limits: limits)
            _ = try mic.adoptPreparedConfiguration(config); _ = try system.adoptPreparedConfiguration(config)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dual-source-checks-" + UUID().uuidString)
            let model = ClientModel(directory: directory,
                configURL: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("text-mode-config.json"))
            model.add(demo: false)
            model.translateFinal = false
            let session = model.selection!
            for ctl in [mic, system] {
                ctl.onObservationChange = { model.recordQwenAttempt($0) }
                ctl.commitFinal = { try await model.commitQwenFinal($0, sourceURL: nil) }
            }
            let source = try system.begin(.init(sessionID: session, channelID: "system", streamID: "pair-system", source: .systemAudio))
            try system.externalDeviceStarted()
            try await mic.userPressedStartMicrophone(userInitiated: true,
                binding: .init(sessionID: session, channelID: "mic", streamID: "pair-mic", source: .microphone))
            // Full segment plus a tail on each independent source; stop together.
            native.handler?(AudioFrame(buffer: buffer(6000),
                timestamp: .init(source: .microphone, hostSeconds: 100, samplePosition: 0,
                    sampleRate: 16000, presentationSeconds: nil, receivedUptime: 100)))
            _ = source.enqueue(AudioFrame(buffer: buffer(6000),
                timestamp: .init(source: .systemAudio, hostSeconds: nil, samplePosition: nil,
                    sampleRate: 16000, presentationSeconds: 100, receivedUptime: 100)))
            async let micDrain: Void = mic.stopAndDrain()
            async let systemDrain: Void = system.stopAndDrain()
            _ = try await (micDrain, systemDrain)
            try await model.finishQwenAttempts(lifecycle: "completed", failure: nil)
            let saved = try ArchiveStore(directory: directory).load().sessions.first!
            try check(saved.segments.count == 4 && Set(saved.segments.map(\.channelKind)) == ["mic", "system"], "pair sources/finals lost")
            try check(saved.captureAttempts.count == 2 && saved.captureAttempts.allSatisfy {
                $0.lifecycle == "completed" && $0.deviceStarted && $0.audioObserved && $0.asrObserved
            }, "two durable terminal facts missing")
            try check(inference.highWater == 1 && native.state == .stopped, "native stop or inference serialization failed")
            try check(source.enqueue(AudioFrame(buffer: buffer(10), timestamp: .init(source: .systemAudio,
                hostSeconds: nil, samplePosition: nil, sampleRate: 16000, presentationSeconds: 100.375, receivedUptime: 100.375))) == .rejectedInactive,
                "late system PCM accepted")
            print("PASS two source identities, concurrent tail drain, durable terminals, reopen, late PCM rejection")

            // The Core Audio tap callback supplies interleaved stereo Float32.
            // Exercise the same ingress path used by the live system capture.
            let interleavedBackend = TestBackend(), interleavedSerial = SerialQwenBackend(underlying: interleavedBackend)
            _ = try await interleavedSerial.load(config)
            let interleaved = QwenSegmentController(backend: interleavedSerial, limits: limits)
            _ = try interleaved.adoptPreparedConfiguration(config)
            var interleavedFinals: [QwenSegmentFinal] = []
            interleaved.commitFinal = { interleavedFinals.append($0) }
            let interleavedSource = try interleaved.begin(.init(sessionID: "interleaved-system",
                channelID: "system", streamID: "interleaved-stream", source: .systemAudio))
            try interleaved.externalDeviceStarted()
            let tapBuffer = interleavedStereoBuffer(4800)
            let tapResult = interleavedSource.enqueue(AudioFrame(buffer: tapBuffer,
                timestamp: .init(source: .systemAudio, hostSeconds: nil, samplePosition: nil,
                    sampleRate: 48000, presentationSeconds: 10, receivedUptime: 10)))
            try check(tapResult == .accepted, "interleaved system PCM rejected at ingress: \(tapResult)")
            do {
                try await interleaved.stopAndDrain()
            } catch {
                let observation = interleaved.attemptObservation
                throw QwenControllerError.backend("interleaved stop/drain: \(error); state=\(interleaved.state); audio=\(observation?.audioObserved ?? false); asr=\(observation?.asrObserved ?? false); queue=\(String(describing: interleaved.queueSnapshot))")
            }
            try check(interleaved.state == .completed && interleaved.audioObserved &&
                       interleaved.asrObserved && !interleavedFinals.isEmpty,
                       "interleaved system PCM did not reach backend")
            print("PASS live-format interleaved stereo system PCM reaches backend and completes")
            try await checkHighCadenceIngress()
            print("DUAL_AUDIO_CHECKS_COMPLETE; synthetic PCM/backend only; native devices covered separately")
        } catch { print("FAIL \(error)"); exit(1) }
    }
}


/// A real Core Audio tap commonly delivers 48 kHz interleaved stereo in
/// ~10 ms blocks. The default ingress must hold more than the 8-second
/// segment boundary; otherwise capture overflows before ASR can run.
@MainActor func checkHighCadenceIngress() async throws {
    let backend = TestBackend()
    let config = ASRConfiguration(providerID: .qwen3ASR, locale: .simplifiedChinese, modelPath: "/fixture")
    _ = try await backend.load(config)
    let controller = QwenSegmentController(backend: backend)
    _ = try controller.adoptPreparedConfiguration(config)
    let binding = QwenSessionBinding(sessionID: "high-cadence", channelID: "system",
        streamID: "high-cadence-stream", source: .systemAudio)
    let producer = try controller.begin(binding)
    let block = interleavedStereoBuffer(480)
    block.frameLength = 480
    let source = block.floatChannelData![0]
    for i in 0..<960 { source[i] = 0 }
    for index in 0..<800 {
        let seconds = Double(index) * 0.01
        let frame = AudioFrame(buffer: block, timestamp: SourceTimestamp(source: .systemAudio,
            hostSeconds: nil, samplePosition: nil, sampleRate: 48_000,
            presentationSeconds: seconds, receivedUptime: seconds))
        let result = producer.enqueue(frame)
        guard result == .accepted else { throw QwenControllerError.backend("high-cadence enqueue \(index) failed: \(result)") }
    }
    try check(controller.queueSnapshot?.queuedBlocks == 800, "default ingress did not retain 8 seconds of tap blocks")
    print("PASS default ingress retains 800 ten-millisecond tap blocks without overflow")
}
