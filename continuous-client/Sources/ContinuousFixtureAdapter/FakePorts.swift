import Foundation
import AVFoundation
import MeetingCopilotAudioCapture
import AppleOfflineSpeech
import RotatingSpeechSession
import DesktopSessionController
import MeetingCopilotCore

@MainActor final class FixturePermissions: DesktopPermissionGateway {
    var microphoneRequests = 0, speechRequests = 0
    func requestMicrophone() async -> Bool { microphoneRequests += 1; return true }
    func requestSpeech() async -> Bool { speechRequests += 1; return true }
}
@MainActor final class FixtureCapture: DesktopCapturePort {
    var state: CaptureState = .idle
    var onStateChange: (@MainActor @Sendable (CaptureState) -> Void)?
    private var handler: AudioFrameHandler?
    private(set) var starts = 0, stops = 0, emittedBlocks = 0, emittedFrames = 0
    func start(intent: CaptureIntent, onFrame: @escaping AudioFrameHandler) throws {
        try CaptureGate.microphone(intent, permissionGranted: true)
        starts += 1; handler = onFrame; state = .running
    }
    func stop() { if state == .running { stops += 1 }; state = .stopped }
    func emit(_ samples: ArraySlice<Float>, position: Int, rate: Double, hostStart: Double) throws {
        guard state == .running, let handler,
              let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(samples.count)) else {
            throw AdapterFailure("FAKE_CAPTURE_NOT_RUNNING_OR_FORMAT_INVALID")
        }
        buffer.frameLength = UInt32(samples.count)
        for (index, sample) in samples.enumerated() { buffer.floatChannelData![0][index] = sample }
        let timestamp = SourceTimestamp(source: .microphone, hostSeconds: hostStart + Double(position) / rate,
            samplePosition: Int64(position), sampleRate: rate, presentationSeconds: nil,
            receivedUptime: ProcessInfo.processInfo.systemUptime)
        handler(AudioFrame(buffer: buffer, timestamp: timestamp))
        emittedBlocks += 1; emittedFrames += samples.count
    }
}
@MainActor final class DormantFixtureBackend: OfflinePCMRecognitionBackend {
    var osAuthorized: Bool { true }
    func begin(locale: OfflineSpeechLocale, deliver: @escaping @MainActor @Sendable (SpeechBackendObservation) -> Void) throws { throw AdapterFailure("UNEXPECTED_FINITE_BACKEND_USE") }
    func append(_ buffer: AVAudioPCMBuffer) throws { throw AdapterFailure("UNEXPECTED_FINITE_BACKEND_USE") }
    func finishAudio() {}
    func cancel() {}
}
struct TaskObservation: Codable {
    let index: Int, streamID: String, segmentID: String
    let samples: [Float], appendAttempts: Int, successfulAppends: Int, begins: Int, finishCalls: Int, cancels: Int
    let deliveredHypotheses: [HypothesisObservation]
}
struct HypothesisObservation: Codable { let text: String, isFinal: Bool }
struct PreASRObservation: Codable {
    let taskIndex: Int
    let blockID: UUID?
    let associationID: UUID?
    let associationDurable: Bool
    let storeError: String?
}
@MainActor final class FixtureBackend: OfflinePCMRecognitionBackend {
    let identity: RotatingSpeechTaskIdentity
    let index: Int
    let script: FixtureInput.TaskHypotheses
    let throwFirstAppend: Bool
    var beforeAppend: (@MainActor (Int) -> Void)?
    var osAuthorized: Bool { true }
    private var deliver: (@MainActor @Sendable (SpeechBackendObservation) -> Void)?
    private(set) var samples: [Float] = []
    private(set) var appendAttempts = 0, successfulAppends = 0, begins = 0, finishes = 0, cancels = 0
    private(set) var observations: [HypothesisObservation] = []
    init(identity: RotatingSpeechTaskIdentity, index: Int, script: FixtureInput.TaskHypotheses, throwFirstAppend: Bool) {
        self.identity = identity; self.index = index; self.script = script; self.throwFirstAppend = throwFirstAppend
    }
    func begin(locale: OfflineSpeechLocale, deliver: @escaping @MainActor @Sendable (SpeechBackendObservation) -> Void) throws { begins += 1; self.deliver = deliver }
    func append(_ buffer: AVAudioPCMBuffer) throws {
        appendAttempts += 1; beforeAppend?(index)
        if throwFirstAppend && appendAttempts == 1 { throw AdapterFailure("INPUT_FIRST_APPEND_THROW") }
        guard let data = buffer.floatChannelData else { throw AdapterFailure("UNEXPECTED_NONFLOAT_PCM") }
        for i in 0..<Int(buffer.frameLength) { samples.append(data[0][i]) }
        let hypothesisIndex = successfulAppends; successfulAppends += 1
        if script.partials.indices.contains(hypothesisIndex) { send(script.partials[hypothesisIndex], final: false) }
    }
    func finishAudio() { finishes += 1 }
    func sendFinalFromInput() { if let text = script.final { send(text, final: true) } }
    private func send(_ text: String, final: Bool) {
        observations.append(HypothesisObservation(text: text, isFinal: final))
        deliver?(.hypothesis(text: text, isFinal: final))
    }
    func cancel() { cancels += 1 }
    var observation: TaskObservation {
        TaskObservation(index: index, streamID: identity.streamId, segmentID: identity.segmentId, samples: samples,
            appendAttempts: appendAttempts, successfulAppends: successfulAppends, begins: begins,
            finishCalls: finishes, cancels: cancels, deliveredHypotheses: observations)
    }
}
@MainActor final class FixtureFactory {
    let input: FixtureInput
    var backends: [FixtureBackend] = []
    var beforeAppend: (@MainActor (Int) -> Void)?
    init(_ input: FixtureInput) { self.input = input }
    func make(_ identity: RotatingSpeechTaskIdentity) throws -> any OfflinePCMRecognitionBackend {
        let index = backends.count
        guard input.taskHypotheses.indices.contains(index) else { throw AdapterFailure("INPUT_TASK_HYPOTHESES_EXHAUSTED") }
        let backend = FixtureBackend(identity: identity, index: index, script: input.taskHypotheses[index],
            throwFirstAppend: input.firstAppendThrow == true && index == 0)
        backend.beforeAppend = beforeAppend; backends.append(backend); return backend
    }
}
struct RawOutputObservation: Codable {
    let kind: String, generationID: UUID
    var streamID: String? = nil, segmentID: String? = nil
    var text: String? = nil, status: String? = nil, revision: Int? = nil, replacesRevision: Int? = nil
    var frameStart: Int? = nil, frameEnd: Int? = nil, mappingRevision: Int? = nil
    var startNS: String? = nil, endNS: String? = nil
    var rawTimestamp: LocalRawObservation? = nil
    var terminalState: String? = nil
}
struct DriverPhaseObservation: Codable {
    let phase: String, mode: String, snapshotState: String
    let captureActive: Bool
    let consumedBlocks: UInt64?
    let backendCount: Int
    let finishCalls: [Int], finalDeliveries: [Int]
    let uptime: Double
}
@MainActor final class AdapterRecord {
    var driverPhases: [DriverPhaseObservation] = []
    var droppedDriverPhases = 0
    private var lastPhaseSignature: String?
    func observeDriver(phase: String, mode: String, snapshotState: String, captureActive: Bool,
                       consumedBlocks: UInt64?, backends: [FixtureBackend]) {
        let finishes = backends.map { $0.finishes }
        let finals = backends.map { $0.observations.filter { $0.isFinal }.count }
        let signature = "\(phase)|\(mode)|\(snapshotState)|\(captureActive)|\(String(describing: consumedBlocks))|\(backends.count)|\(finishes)|\(finals)"
        guard signature != lastPhaseSignature else { return }
        lastPhaseSignature = signature
        guard driverPhases.count < 128 else { droppedDriverPhases += 1; return }
        driverPhases.append(DriverPhaseObservation(phase: phase, mode: mode, snapshotState: snapshotState,
            captureActive: captureActive, consumedBlocks: consumedBlocks, backendCount: backends.count,
            finishCalls: finishes, finalDeliveries: finals, uptime: ProcessInfo.processInfo.systemUptime))
    }
    var preASR: [PreASRObservation] = []
    var raw: [RawOutputObservation] = []
    var order: [String] = []
    var terminalCoverageDurableBeforeRaw: Bool?
    var terminalDiskReadError: String?
}
