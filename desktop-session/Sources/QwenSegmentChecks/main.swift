import Foundation
import AVFoundation
import DesktopSessionController
import LocalASRProviders
import MeetingCopilotAudioCapture
import AppleOfflineSpeech

@MainActor final class Permissions: DesktopPermissionGateway {
    var microphones = 0, speeches = 0, granted = true
    func requestMicrophone() async -> Bool { microphones += 1; return granted }
    func requestSpeech() async -> Bool { speeches += 1; return true }
}
@MainActor final class Capture: DesktopCapturePort {
    var state: CaptureState = .idle
    var onStateChange: (@MainActor @Sendable (CaptureState) -> Void)?
    var starts = 0
    func start(intent: CaptureIntent, onFrame: @escaping AudioFrameHandler) throws { starts += 1; state = .running }
    func stop() { state = .stopped }
}
@MainActor final class Backend: QwenSegmentBackend {
    var identity = ASREngineIdentity(providerID: .qwen3ASR, engineVersion: "injected-only", modelVersion: "test", locale: "auto", generation: 0)
    var config: ASRConfiguration?, loads = 0, calls = 0, cancels = 0
    var gated = false, loadFailure = false, inferenceFailure = false
    var silent = false, unmarkedEmpty = false
    var gates: [Int: CheckedContinuation<Void, Never>] = [:]
    var startedWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    var durations: [Double] = [], diskHighWater = 0
    func preparedEngine(for configuration: ASRConfiguration) -> ASREngineIdentity? { config == configuration ? identity : nil }
    func load(_ configuration: ASRConfiguration) async throws -> ASREngineIdentity {
        if loadFailure { throw QwenControllerError.backend("INJECTED_LOAD_FAILURE") }
        loads += 1; config = configuration
        identity = ASREngineIdentity(providerID: .qwen3ASR, engineVersion: "injected-only", modelVersion: "test", locale: "auto", generation: UInt64(loads))
        return identity
    }
    func transcribe(fileURL: URL, context: String?) async throws -> QwenBatchResult {
        let file = try AVAudioFile(forReading: fileURL)
        guard file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1,
              file.length > 0, file.length <= 128000 else { throw QwenControllerError.invalidPCM }
        diskHighWater = max(diskHighWater, try FileManager.default.contentsOfDirectory(atPath: fileURL.deletingLastPathComponent().path).count)
        durations.append(Double(file.length) / 16000)
        calls += 1; let ticket = calls, engine = identity
        if gated {
            await withCheckedContinuation { continuation in
                gates[ticket] = continuation
                let ready = startedWaiters.filter { $0.0 <= calls }; startedWaiters.removeAll { $0.0 <= calls }
                for (_, waiter) in ready { waiter.resume() }
            }
        }
        if inferenceFailure { throw QwenControllerError.backend("INJECTED_INFERENCE_FAILURE") }
        return .init(text: silent || unmarkedEmpty ? "" : "segment \(ticket)", language: "auto", engine: engine, noSpeech: silent)
    }
    func waitForCall(_ count: Int) async {
        if calls >= count { return }
        await withCheckedContinuation { startedWaiters.append((count, $0)) }
    }
    func release(_ ticket: Int) { gates.removeValue(forKey: ticket)?.resume() }
    func cancel() { cancels += 1; config = nil }
    func unload() { config = nil }
}
@MainActor final class Sink {
    var finals: [QwenSegmentFinal] = []
    var gate: CheckedContinuation<Void, Never>?, entered: CheckedContinuation<Void, Never>?
    var shouldGate = false, reject = false
    func commit(_ final: QwenSegmentFinal) async throws {
        if shouldGate { await withCheckedContinuation { gate = $0; entered?.resume(); entered = nil } }
        if reject { throw QwenControllerError.backend("WRITER_REJECTED") }
        finals.append(final)
    }
    func waitForCommit() async {
        if gate != nil { return }
        await withCheckedContinuation { entered = $0 }
    }
    func release() { gate?.resume(); gate = nil }
}
func audio(_ frames: Int, rate: Double = 48000) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(frames))!
    buffer.frameLength = UInt32(frames)
    for n in 0..<frames { buffer.floatChannelData![0][n] = Float(sin(Double(n) * 0.02)) * 0.05 }
    return buffer
}
func fixture(_ url: URL, seconds: Double, rate: Double = 48000) throws {
    let b = audio(Int(seconds * rate), rate: rate)
    let file = try AVAudioFile(forWriting: url, settings: b.format.settings)
    try file.write(from: b)
}
@MainActor func require(_ condition: Bool, _ reason: String) throws {
    if !condition { throw QwenControllerError.backend("CHECK_FAILED: " + reason) }
}
@MainActor func expectFailure(_ action: () async throws -> Void) async throws {
    do { try await action() } catch { return }
    throw QwenControllerError.backend("EXPECTED_FAILURE_MISSING")
}
@MainActor func controller(_ backend: Backend, _ permissions: Permissions, _ capture: Capture, limits: QwenSegmentLimits = .init()) -> QwenSegmentController {
    QwenSegmentController(backend: backend, permissions: permissions, microphone: capture, limits: limits)
}
@main struct Checks {
    @MainActor static func main() async {
        do {
            let args = CommandLine.arguments
            if args.count == 5 && args[1] == "--real-native" {
                let config = ASRConfiguration(providerID: .qwen3ASR, locale: .simplifiedChinese, modelPath: args[2])
                let permissions = Permissions(), capture = Capture()
                let realBackend = ProductionQwenSegmentBackend()
                let ctl = QwenSegmentController(backend: realBackend, permissions: permissions, microphone: capture)
                let sink = Sink(), writerURL = URL(fileURLWithPath: args[4])
                var rawRows: [[String: Any]] = []
                ctl.commitFinal = { final in
                    guard let r = realBackend.lastResult, r.engine == final.engine, r.text == final.text else { throw QwenControllerError.backend("RAW_ACK_MISMATCH") }
                    rawRows.append(["attemptID": final.attemptID.uuidString, "session": final.binding.sessionID, "sequence": final.sequence,
                        "audioSHA256": r.audioSHA256, "requestID": r.requestID, "duration": r.duration, "elapsedSeconds": r.elapsedSeconds,
                        "rawResponseJSON": r.rawResponseJSON])
                    try JSONSerialization.data(withJSONObject: rawRows, options: [.prettyPrinted, .sortedKeys]).write(to: writerURL.appendingPathExtension("raw.json"), options: .atomic)
                    try await sink.commit(final)
                    let rows: [[String: Any]] = sink.finals.map { ["sequence": $0.sequence, "session": $0.binding.sessionID,
                        "source": $0.binding.source.rawValue, "frameStart": $0.sourceRange.frameStart, "frameEnd": $0.sourceRange.frameEnd,
                        "startNs": String($0.sourceRange.startNs), "endNs": String($0.sourceRange.endNs), "text": $0.text,
                        "language": $0.language, "engine": $0.engine.engineVersion, "model": $0.engine.modelVersion ?? "",
                        "timingBasis": $0.timingBasis] }
                    try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: writerURL, options: .atomic)
                    let back = try JSONSerialization.jsonObject(with: Data(contentsOf: writerURL)) as! [[String: Any]]
                    try require(back.count == rows.count, "writer readback")
                }
                _ = try await ctl.prepare(config)
                let inputURL = URL(fileURLWithPath: args[3])
                try await ctl.transcribeFile(inputURL, binding: .init(sessionID: "synthetic-native", channelID: "file", streamID: "s1", source: .file))
                try require(ctl.state == .completed && !sink.finals.isEmpty && !ctl.deviceStarted, "real backend to durable writer")
                let fileFinals = sink.finals.count
                // Exercise the borrowed native capture ingress without opening any device.
                let nativeFile = try AVAudioFile(forReading: inputURL, commonFormat: .pcmFormatFloat32, interleaved: false)
                guard nativeFile.length <= 32 * 8192 else { throw QwenControllerError.invalidConfiguration }
                let producer = try ctl.begin(.init(sessionID: "synthetic-ingress", channelID: "mic", streamID: "s2", source: .microphone))
                var offset: Int64 = 0
                while offset < nativeFile.length {
                    let n = AVAudioFrameCount(min(8192, nativeFile.length - offset))
                    let buffer = AVAudioPCMBuffer(pcmFormat: nativeFile.processingFormat, frameCapacity: n)!
                    try nativeFile.read(into: buffer, frameCount: n)
                    let seconds = 1 + Double(offset) / buffer.format.sampleRate
                    let result = producer.enqueue(.init(buffer: buffer, timestamp: .init(source: .microphone, hostSeconds: seconds,
                        samplePosition: offset, sampleRate: buffer.format.sampleRate, presentationSeconds: nil, receivedUptime: seconds)))
                    try require(result == .accepted, "native ingress admission")
                    offset += Int64(n)
                }
                try await ctl.stopAndDrain()
                try require(ctl.state == .completed && sink.finals.count > fileFinals && !ctl.deviceStarted && ctl.asrObserved, "real ingress seals/drains/ack with zero device")
                let longURL = writerURL.deletingLastPathComponent().appendingPathComponent("synthetic-native-repeat-25s.wav")
                let repeatSource = try AVAudioFile(forReading: inputURL, commonFormat: .pcmFormatFloat32, interleaved: false)
                var repeatWriter: AVAudioFile? = try AVAudioFile(forWriting: longURL, settings: repeatSource.processingFormat.settings)
                let goal = Int64(repeatSource.processingFormat.sampleRate * 25)
                var written: Int64 = 0
                while written < goal {
                    if repeatSource.framePosition == repeatSource.length { repeatSource.framePosition = 0 }
                    let n = AVAudioFrameCount(min(8192, min(goal - written, repeatSource.length - repeatSource.framePosition)))
                    let buffer = AVAudioPCMBuffer(pcmFormat: repeatSource.processingFormat, frameCapacity: n)!
                    try repeatSource.read(into: buffer, frameCount: n); try repeatWriter!.write(from: buffer); written += Int64(n)
                }
                repeatWriter = nil
                let beforeLong = sink.finals.count
                try await ctl.transcribeFile(longURL, binding: .init(sessionID: "synthetic-native-25s", channelID: "file", streamID: "s3", source: .file))
                let longFinals = Array(sink.finals.dropFirst(beforeLong))
                try require(ctl.state == .completed && longFinals.count == 4 && longFinals.last!.sourceRange.frameEnd == Int(goal), "real 25s four segments all native frames")
                try require(longFinals.map { $0.sourceRange.endNs - $0.sourceRange.startNs } == [8000000000,8000000000,8000000000,1000000000], "real source durations 8/8/8/1")
                try require(sink.finals.allSatisfy { $0.engine == sink.finals[0].engine }, "one loaded engine generation all sessions")
                try require(permissions.microphones == 0 && permissions.speeches == 0 && capture.starts == 0, "real run zero hardware/permissions")
                try ctl.unload()
                print("PASS real native PCM -> bounded mono16k WAV -> Qwen -> writer readback; segments=\(sink.finals.count)")
                return
            }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("qwen-segment-checks-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            let longFile = root.appendingPathComponent("synthetic-25s.wav"), shortFile = root.appendingPathComponent("synthetic-short.wav")
            try fixture(longFile, seconds: 25); try fixture(shortFile, seconds: 0.1, rate: 16000)
            let config = ASRConfiguration(providerID: .qwen3ASR, locale: .simplifiedChinese, modelPath: "/injected-model")
            let fileBinding = QwenSessionBinding(sessionID: "a", channelID: "file", streamID: "s", source: .file)
            let micBinding = QwenSessionBinding(sessionID: "mic", channelID: "mic", streamID: "s", source: .microphone)
            do {
                let b = Backend(), p = Permissions(), c = Capture(), sink = Sink(), ctl = controller(b, p, c)
                ctl.commitFinal = { try await sink.commit($0) }
                _ = try await ctl.prepare(config)
                try await ctl.transcribeFile(longFile, binding: fileBinding)
                try require(ctl.state == .completed && sink.finals.count == 4, "25s file four segments")
                try require(b.loads == 1 && b.durations == [8, 8, 8, 1], "persistent load and exact limits")
                try require(b.diskHighWater == 1 && ctl.highWaterPendingSegments <= 4, "disk/RAM bounds")
                for (index, f) in sink.finals.enumerated() {
                    try require(f.sequence == index + 1 && f.sourceRange.frameStart == (index == 0 ? 0 : sink.finals[index-1].sourceRange.frameEnd), "contiguous native range")
                }
                let ids = sink.finals.map { $0.recognitionStreamID }
                try require(Set(ids).count == 4 && ids.allSatisfy { $0 != fileBinding.streamID }, "independent task stream per segment")
                for f in sink.finals {
                    let replay = QwenSegmentFinal(binding: f.binding, attemptID: f.attemptID, sequence: f.sequence,
                        sourceRange: f.sourceRange, text: f.text, language: f.language, engine: f.engine)
                    try require(replay.recognitionStreamID == f.recognitionStreamID && f.binding.streamID == fileBinding.streamID,
                                "stable replay identity and original input mapping")
                    try require(f.sourceRange.mappingRevision == fileBinding.mappingRevision, "original mapping revision")
                }
                try require(sink.finals.last!.sourceRange.frameEnd == 25 * 48000, "all native PCM accounted")
                try require(sink.finals.allSatisfy { $0.binding.source.rawValue == "audio_file" && $0.binding.sourceURL == longFile }, "real audio_file identity")
                try require(!ctl.deviceStarted && ctl.audioObserved && ctl.asrObserved && ctl.attemptID == sink.finals[0].attemptID, "file observation and real attempt")
                try require(p.microphones == 0 && p.speeches == 0 && c.starts == 0, "file zero permissions/device")
                print("PASS file >3 segments / bounded memory+disk / one load / continuous ranges / zero permission")
            }
            do {
                let b = Backend(), p = Permissions(), c = Capture(), ctl = controller(b, p, c)
                b.loadFailure = true
                try await expectFailure { _ = try await ctl.prepare(config) }
                if case .failed = ctl.state {} else { throw QwenControllerError.backend("load must fail") }
                try require(ctl.engine == nil && c.starts == 0, "failed load not ready")
                print("PASS load failure clears readiness and never opens hardware")
            }
            do {
                let b = Backend(), p = Permissions(), c = Capture(), sink = Sink(), ctl = controller(b, p, c)
                b.gated = true; ctl.commitFinal = { try await sink.commit($0) }
                _ = try await ctl.prepare(config)
                let old = Task { try await ctl.transcribeFile(shortFile, binding: fileBinding) }
                await b.waitForCall(1)
                let oldObservation = ctl.attemptObservation
                try require(oldObservation?.audioObserved == true && oldObservation?.asrObserved == false, "audio observed before backend ack")
                ctl.cancel()
                try require(ctl.attemptObservation == oldObservation && ctl.engine == nil, "cancel preserves history but clears active engine")
                _ = try await ctl.prepare(config)
                try require(ctl.attemptObservation == oldObservation, "reload does not rewrite old attempt facts")
                let fresh = Task { try await ctl.transcribeFile(shortFile, binding: .init(sessionID: "b", channelID: "file", streamID: "new", source: .file)) }
                await b.waitForCall(2)
                try require(ctl.attemptObservation?.attemptID != oldObservation?.attemptID &&
                            ctl.attemptObservation?.engineAtStart != oldObservation?.engineAtStart &&
                            ctl.attemptObservation?.asrObserved == false, "fresh attempt and historical engine isolated")
                b.release(1)
                _ = try? await old.value
                try require(sink.finals.isEmpty, "late old result cannot commit")
                b.release(2); try await fresh.value
                try require(sink.finals.count == 1 && sink.finals[0].binding.sessionID == "b" && ctl.state == .completed, "new session isolated")
                print("PASS cancel noncooperative late result / two-session isolation / reload")
            }
            do {
                let b = Backend(), p = Permissions(), c = Capture(), sink = Sink(), ctl = controller(b, p, c)
                sink.shouldGate = true; ctl.commitFinal = { try await sink.commit($0) }
                _ = try await ctl.prepare(config)
                let task = Task { try await ctl.transcribeFile(shortFile, binding: fileBinding) }
                await sink.waitForCommit()
                try require(ctl.state == .draining && ctl.deliveredSegments == 0, "await durable ack")
                try await expectFailure { _ = try await ctl.prepare(config) }
                sink.release(); try await task.value
                try require(ctl.state == .completed && ctl.deliveredSegments == 1, "completion after ack")
                print("PASS async writer ack gates completion / busy configuration rejection")
            }
            do {
                let b = Backend(), p = Permissions(), c = Capture(), sink = Sink(), ctl = controller(b, p, c)
                sink.reject = true; ctl.commitFinal = { try await sink.commit($0) }
                _ = try await ctl.prepare(config)
                try await expectFailure { try await ctl.transcribeFile(shortFile, binding: fileBinding) }
                try require(ctl.deliveredSegments == 0 && ctl.engine == nil, "writer reject is not completed")
                try require(ctl.attemptObservation?.audioObserved == true && ctl.attemptObservation?.asrObserved == true,
                            "writer failure preserves audio and recognized facts")
                print("PASS writer failure clears engine and cannot complete")
            }
            do {
                let b = Backend(), p = Permissions(), c = Capture(), ctl = controller(b, p, c)
                p.granted = false; _ = try await ctl.prepare(config)
                try await expectFailure { try await ctl.userPressedStartMicrophone(userInitiated: false, binding: micBinding) }
                try require(p.microphones == 0, "no user action no permission")
                try await expectFailure { try await ctl.userPressedStartMicrophone(userInitiated: true, binding: micBinding) }
                try require(p.microphones == 1 && p.speeches == 0 && c.starts == 0, "Qwen mic no Apple speech auth")
                try require(ctl.attemptObservation != nil && !ctl.audioObserved && !ctl.asrObserved && !ctl.deviceStarted && ctl.engine == nil,
                            "denied attempt retains historical engine with zero observations")
                print("PASS explicit mic action only / denial / Apple speech requests zero")
            }
            do {
                let b = Backend(), p = Permissions(), c = Capture(), ctl = controller(b, p, c, limits: .init(ingressBlocks: 1))
                _ = try await ctl.prepare(config); let producer = try ctl.begin(micBinding)
                let frame = AudioFrame(buffer: audio(1600, rate: 16000), timestamp: .init(source: .microphone, hostSeconds: 1,
                    samplePosition: 0, sampleRate: 16000, presentationSeconds: nil, receivedUptime: 1))
                _ = producer.enqueue(frame); let rejected = producer.enqueue(frame)
                if case .failed = rejected {} else { throw QwenControllerError.backend("overflow must reject") }
                try await expectFailure { try await ctl.stopAndDrain() }
                if case .failed = ctl.state {} else { throw QwenControllerError.backend("overflow cannot complete") }
                print("PASS capture ingress overflow poisons attempt, never silently drops")
            }
            do {
                let b = Backend(), p = Permissions(), c = Capture(), ctl = controller(b, p, c, limits: .init(drainTimeoutSeconds: 0.05))
                b.gated = true; _ = try await ctl.prepare(config); let producer = try ctl.begin(micBinding)
                _ = producer.enqueue(.init(buffer: audio(1600, rate: 16000), timestamp: .init(source: .microphone, hostSeconds: 1,
                    samplePosition: 0, sampleRate: 16000, presentationSeconds: nil, receivedUptime: 1)))
                let stop = Task { try await ctl.stopAndDrain() }
                await b.waitForCall(1)
                try await expectFailure { try await stop.value }
                try require(ctl.state == .failed(.drainTimeout) && ctl.deliveredSegments == 0, "bounded drain timeout; observed=\(ctl.state), delivered=\(ctl.deliveredSegments)")
                b.release(1)
                print("PASS stop seals tail / noncooperative drain deadline / late result rejected")
            }
            do {
                let b = Backend(), p = Permissions(), c = Capture(), ctl = controller(b, p, c)
                _ = try await ctl.prepare(config); let producer = try ctl.begin(micBinding)
                let invalid = audio(1600, rate: 16000); invalid.floatChannelData![0][0] = .nan
                _ = producer.enqueue(.init(buffer: invalid, timestamp: .init(source: .microphone, hostSeconds: 1,
                    samplePosition: 0, sampleRate: 16000, presentationSeconds: nil, receivedUptime: 1)))
                try await expectFailure { try await ctl.stopAndDrain() }
                try require(b.calls == 0 && !ctl.audioObserved && !ctl.asrObserved && ctl.attemptObservation?.audioObserved == false,
                            "invalid PCM never counts as observed or reaches backend")
                print("PASS nonfinite PCM rejected before inference")
            }
            do {
                let b = Backend(), p = Permissions(), c = Capture(), sink = Sink(), ctl = controller(b, p, c)
                sink.shouldGate = true; ctl.commitFinal = { try await sink.commit($0) }
                _ = try await ctl.prepare(config)
                let old = Task { try await ctl.transcribeFile(shortFile, binding: fileBinding) }
                await sink.waitForCommit(); ctl.cancel()
                try await expectFailure { try await old.value }
                try require(ctl.state == .cancelled && ctl.deliveredSegments == 0, "cancel during writer does not complete")
                sink.release(); sink.shouldGate = false
                _ = try await ctl.prepare(config)
                try await ctl.transcribeFile(shortFile, binding: .init(sessionID: "new-writer-session", channelID: "file", streamID: "new", source: .file))
                try require(sink.finals.count == 2 && sink.finals[0].binding.sessionID == "a" && sink.finals[1].binding.sessionID == "new-writer-session", "old durable fact keeps old target")
                try require(ctl.deliveredSegments == 1 && ctl.state == .completed, "only new ack counts in new attempt")
                print("PASS cancel during durable writer / old committed fact stays old / new target isolated")
            }
            do {
                let b = Backend(), p = Permissions(), c = Capture(), sink = Sink(), ctl = controller(b, p, c)
                b.inferenceFailure = true; ctl.commitFinal = { try await sink.commit($0) }
                var observations: [QwenAttemptObservation] = []
                ctl.onObservationChange = { observations.append($0) }
                let startedEngine = try await ctl.prepare(config)
                try await expectFailure { try await ctl.transcribeFile(shortFile, binding: fileBinding) }
                try require(sink.finals.isEmpty && !ctl.asrObserved && ctl.engine == nil, "inference error no final/ready")
                try require(ctl.audioObserved && ctl.attemptObservation?.engineAtStart == startedEngine &&
                            ctl.attemptObservation?.binding.sourceURL == shortFile, "failed backend retains decoded audio/source/engine history")
                try require(observations.count == 2 && !observations[0].audioObserved && observations[1].audioObserved &&
                            observations.allSatisfy { !$0.asrObserved && !$0.deviceStarted }, "independent monotonic observation callback")
                print("PASS backend failure cannot reach writer or completed")
            }
            do {
                let b = Backend(), p = Permissions(), c = Capture(), sink = Sink(), ctl = controller(b, p, c)
                ctl.commitFinal = { try await sink.commit($0) }
                _ = try await ctl.prepare(config); let producer = try ctl.begin(micBinding)
                let attempt = ctl.attemptID
                _ = producer.enqueue(.init(buffer: audio(1600, rate: 16000), timestamp: .init(source: .microphone, hostSeconds: 1,
                    samplePosition: 0, sampleRate: 16000, presentationSeconds: nil, receivedUptime: 1)))
                try await ctl.stopAndDrain()
                try require(ctl.state == .completed && sink.finals.count == 1 && sink.finals[0].attemptID == attempt, "stop tail commits one final")
                try require(sink.finals[0].sourceRange.startNs == 1000000000 && sink.finals[0].sourceRange.endNs == 1100000000, "source-time extent not word alignment")
                if case .rejectedInactive = producer.enqueue(.init(buffer: audio(1, rate: 16000), timestamp: .init(source: .microphone, hostSeconds: 2,
                    samplePosition: 1600, sampleRate: 16000, presentationSeconds: nil, receivedUptime: 2))) {} else { throw QwenControllerError.backend("stop must seal") }
                try require(c.starts == 0 && p.microphones == 0 && p.speeches == 0 && !ctl.deviceStarted, "synthetic capture ingress no device")
                print("PASS accepted capture tail drains / source timestamp / sealed input / zero hardware")
            }
            do {
                let b = Backend(), p = Permissions(), c = Capture(), ctl = controller(b, p, c)
                _ = try await ctl.prepare(config); let producer = try ctl.begin(micBinding)
                _ = producer.enqueue(.init(buffer: audio(1600, rate: 16000), timestamp: .init(source: .systemAudio,
                    hostSeconds: 1, samplePosition: 0, sampleRate: 16000, presentationSeconds: 1, receivedUptime: 1)))
                try await expectFailure { try await ctl.stopAndDrain() }
                try require(!ctl.audioObserved && !ctl.asrObserved && b.calls == 0, "wrong source cannot count as observed")
                print("PASS source validation precedes audio observation")
            }
            do {
                let b = Backend(), p = Permissions(), c = Capture(), sink = Sink(), ctl = controller(b, p, c)
                b.silent = true; var notices = 0
                ctl.onNoSpeech = { notices += 1 }
                ctl.commitFinal = { try await sink.commit($0) }
                _ = try await ctl.prepare(config); let producer = try ctl.begin(micBinding)
                _ = producer.enqueue(.init(buffer: audio(1600, rate: 16000), timestamp: .init(source: .microphone,
                    hostSeconds: 1, samplePosition: 0, sampleRate: 16000, presentationSeconds: nil, receivedUptime: 1)))
                try await ctl.stopAndDrain()
                try require(ctl.state == .completed && ctl.engine != nil && ctl.audioObserved && !ctl.asrObserved &&
                            ctl.skippedNoSpeechSegments == 1 && sink.finals.isEmpty && notices == 1,
                            "explicit no speech completes without fake transcript or engine cancellation")
                b.silent = false; let next = try ctl.begin(micBinding)
                _ = next.enqueue(.init(buffer: audio(1600, rate: 16000), timestamp: .init(source: .microphone,
                    hostSeconds: 2, samplePosition: 0, sampleRate: 16000, presentationSeconds: nil, receivedUptime: 2)))
                try await ctl.stopAndDrain()
                try require(sink.finals.count == 1 && ctl.skippedNoSpeechSegments == 0 && ctl.asrObserved, "speech accepted after silent capture")
                print("PASS explicit no speech keeps engine, writes no empty final, and accepts subsequent speech")
            }
            do {
                let b = Backend(), p = Permissions(), c = Capture(), ctl = controller(b, p, c)
                b.unmarkedEmpty = true
                _ = try await ctl.prepare(config)
                try await expectFailure { try await ctl.transcribeFile(shortFile, binding: fileBinding) }
                try require(ctl.engine == nil && !ctl.asrObserved, "unmarked empty response remains a protocol error")
                print("PASS unmarked empty result remains rejected")
            }
            do {
                let b = Backend(), p = Permissions(), c = Capture(), sink = Sink()
                let ctl = controller(b, p, c, limits: .init(ingressBlocks: 64))
                ctl.commitFinal = { try await sink.commit($0) }
                _ = try await ctl.prepare(config); let producer = try ctl.begin(micBinding)
                for i in 0..<40 {
                    // Contiguous native samples, host clock drifts by 200 ppm.
                    _ = producer.enqueue(.init(buffer: audio(4800), timestamp: .init(source: .microphone,
                        hostSeconds: 1 + Double(i) * 0.10002, samplePosition: Int64(i * 4800),
                        sampleRate: 48000, presentationSeconds: nil, receivedUptime: 1)))
                }
                try await ctl.stopAndDrain()
                try require(ctl.state == .completed && sink.finals.count == 1 &&
                            sink.finals[0].sourceRange.startNs == 1000000000 &&
                            sink.finals[0].sourceRange.endNs == 5000000000,
                            "native samples control duration despite host drift")
                print("PASS contiguous native PCM tolerates host drift; source extent remains sample based")
            }
            do {
                let b = Backend(), p = Permissions(), c = Capture(), ctl = controller(b, p, c)
                _ = try await ctl.prepare(config); let producer = try ctl.begin(micBinding)
                for (position, seconds) in [(Int64(0), 1.0), (Int64(1601), 1.1)] {
                    _ = producer.enqueue(.init(buffer: audio(1600, rate: 16000), timestamp: .init(source: .microphone,
                        hostSeconds: seconds, samplePosition: position, sampleRate: 16000,
                        presentationSeconds: nil, receivedUptime: seconds)))
                }
                try await expectFailure { try await ctl.stopAndDrain() }
                try require(ctl.state == .failed(.discontinuousSource) && b.calls == 0 &&
                            ctl.continuityFailureDescription?.contains("采样位置跳变") == true,
                            "one dropped native sample must fail with diagnostics")
                print("PASS real native gap remains rejected with diagnostic and zero inference")
            }
            do {
                let b = Backend(), p = Permissions(), c = Capture(), ctl = controller(b, p, c)
                _ = try await ctl.prepare(config); let producer = try ctl.begin(micBinding)
                for (position, seconds) in [(Int64(0), 1.0), (Int64(1600), 2.0)] {
                    _ = producer.enqueue(.init(buffer: audio(1600, rate: 16000), timestamp: .init(source: .microphone,
                        hostSeconds: seconds, samplePosition: position, sampleRate: 16000, presentationSeconds: nil, receivedUptime: seconds)))
                }
                try await expectFailure { try await ctl.stopAndDrain() }
                try require(ctl.state == .failed(.discontinuousSource) && ctl.audioObserved && !ctl.asrObserved && b.calls == 0,
                            "valid first PCM fact survives later discontinuity")
                print("PASS later invalid source cannot erase earlier valid audio fact")
            }
            do {
                let b = Backend(), p = Permissions(), c = Capture(), ctl = controller(b, p, c)
                _ = try await ctl.prepare(config); _ = try ctl.begin(micBinding)
                ctl.cancel()
                let cancelled = ctl.attemptObservation
                try require(cancelled != nil && !ctl.audioObserved && !ctl.asrObserved && !ctl.deviceStarted, "cancel before PCM has zero facts")
                _ = try await ctl.prepare(config); _ = try ctl.begin(micBinding)
                try require(ctl.attemptObservation?.attemptID != cancelled?.attemptID && !ctl.audioObserved && !ctl.asrObserved,
                            "new attempt resets observations")
                ctl.cancel()
                try require(p.microphones == 0 && p.speeches == 0 && c.starts == 0, "observation checks zero hardware")
                print("PASS cancel before PCM / fresh attempt reset / historical identity retained")
            }
            do {
                let b = Backend(), p = Permissions(), c = Capture(), sink = Sink(), ctl = controller(b, p, c)
                let system = QwenSessionBinding(sessionID: "system-session", channelID: "system", streamID: "system-stream", source: .systemAudio)
                ctl.commitFinal = { try await sink.commit($0) }
                _ = try await ctl.prepare(config)
                let producer = try ctl.begin(system)
                try require(!ctl.deviceStarted, "begin does not fabricate hardware start")
                try ctl.externalDeviceStarted()
                _ = producer.enqueue(.init(buffer: audio(1600, rate: 16000), timestamp: .init(source: .systemAudio,
                    hostSeconds: nil, samplePosition: nil, sampleRate: 16000, presentationSeconds: 5, receivedUptime: 5)))
                try await ctl.stopAndDrain()
                try require(ctl.state == .completed && sink.finals.count == 1 && sink.finals[0].binding.source == .systemAudio && ctl.deviceStarted,
                    "system source drains with explicit device observation")
                try require(sink.finals[0].sourceRange.startNs == 5_000_000_000 && sink.finals[0].sourceRange.endNs == 5_100_000_000,
                    "system PTS source extent preserved")
                b.silent = true
                let next = try ctl.begin(system)
                _ = next.enqueue(.init(buffer: audio(1600, rate: 16000), timestamp: .init(source: .systemAudio,
                    hostSeconds: nil, samplePosition: nil, sampleRate: 16000, presentationSeconds: 7, receivedUptime: 7)))
                try await ctl.stopAndDrain()
                try require(ctl.state == .completed && ctl.skippedNoSpeechSegments == 1 && sink.finals.count == 1 && ctl.engine != nil,
                    "silent system audio never writes an empty final or stops engine")
                let third = try ctl.begin(system)
                ctl.externalCaptureFailed("INJECTED_STREAM_STOP")
                try require(ctl.engine == nil && !ctl.deviceStarted && !ctl.audioObserved, "system native failure invalidates attempt")
                if case .rejectedInactive = third.enqueue(.init(buffer: audio(1, rate: 16000), timestamp: .init(source: .systemAudio,
                    hostSeconds: nil, samplePosition: nil, sampleRate: 16000, presentationSeconds: 8, receivedUptime: 8))) {} else {
                    throw QwenControllerError.backend("failed native stream must reject late PCM")
                }
                try require(c.starts == 0 && p.microphones == 0 && p.speeches == 0, "system path cannot request microphone/speech")
                print("PASS system source PTS / durable tail / explicit device observation / no-speech continuation / native failure and late PCM rejection")
            }
            // Resolve and check before removal; only this check's generated fixture directory.
            guard root.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL,
                  root.lastPathComponent.hasPrefix("qwen-segment-checks-") else { throw QwenControllerError.invalidConfiguration }
            try FileManager.default.removeItem(at: root)
            print("PASS ALL qwen segment checks; real microphone=0 real permissions=0 real API=0")
        } catch { fputs("FAIL \(error)\n", stderr); exit(1) }
    }
}
