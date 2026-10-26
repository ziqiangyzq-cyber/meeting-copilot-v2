import Foundation
import AVFoundation
import CoreAudio
import CoreMedia
import Darwin

/// Converts a ScreenCaptureKit CMSampleBuffer into PCM. Retained as an
/// independent decoder check and compatibility utility; live system audio now
/// uses Core Audio process taps.
public enum SystemPCMDecoder {
    public static func decode(_ sample: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        guard CMSampleBufferDataIsReady(sample),
              let description = CMSampleBufferGetFormatDescription(sample),
              CMFormatDescriptionGetMediaType(description) == kCMMediaType_Audio,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              asbd.pointee.mFormatID == kAudioFormatLinearPCM,
              let format = AVAudioFormat(streamDescription: asbd) else { throw CaptureFailure.invalidBuffer }
        let count = CMSampleBufferGetNumSamples(sample)
        guard count > 0, count <= Int(Int32.max),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
            throw CaptureFailure.invalidBuffer
        }
        buffer.frameLength = AVAudioFrameCount(count)
        let result = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0,
            frameCount: Int32(count), into: buffer.mutableAudioBufferList)
        guard result == noErr else { throw CaptureFailure.nativeError("PCM copy OSStatus \(result)") }
        try PCMUtilities.validate(buffer)
        return buffer
    }
}

private enum CoreAudioTapError: LocalizedError {
    case operation(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .operation(let name, let status):
            return "\(name)失败（Core Audio \(status)）"
        }
    }
}

private enum CoreAudioTapSupport {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func requireSuccess(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw CoreAudioTapError.operation(operation, status) }
    }

    static func read<T>(_ object: AudioObjectID,
                        selector: AudioObjectPropertySelector,
                        initial: T,
                        qualifier: UInt32? = nil) throws -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status: OSStatus
        if let qualifier {
            var qualifier = qualifier
            status = withUnsafePointer(to: &qualifier) { pointer in
                withUnsafeMutablePointer(to: &value) { valuePointer in
                    AudioObjectGetPropertyData(object, &address,
                        UInt32(MemoryLayout<UInt32>.size), pointer, &size, valuePointer)
                }
            }
        } else {
            status = withUnsafeMutablePointer(to: &value) { valuePointer in
                AudioObjectGetPropertyData(object, &address, 0, nil, &size, valuePointer)
            }
        }
        try requireSuccess(status, "读取 Core Audio 属性")
        return value
    }

    static func processObject(for pid: pid_t) throws -> AudioObjectID {
        try read(systemObject,
                 selector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                 initial: AudioObjectID(kAudioObjectUnknown),
                 qualifier: UInt32(bitPattern: pid))
    }

    static func defaultOutputUID() throws -> CFString {
        let device: AudioDeviceID = try read(systemObject,
            selector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            initial: AudioDeviceID(kAudioObjectUnknown))
        guard device != kAudioObjectUnknown else {
            throw CoreAudioTapError.operation("读取默认输出设备", kAudioHardwareBadDeviceError)
        }
        return try read(device,
                        selector: kAudioDevicePropertyDeviceUID,
                        initial: "" as CFString)
    }

    static func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        try read(tap,
                 selector: kAudioTapPropertyFormat,
                 initial: AudioStreamBasicDescription())
    }
}

/// Live macOS 14.2+ system audio through a private Core Audio process tap.
/// The public lifecycle and PCM callback match the former ScreenCaptureKit
/// implementation, so Qwen and dual-audio wiring do not change.
@MainActor
public final class SystemAudioCapture {
    public private(set) var state: CaptureState = .idle
    public var onStateChange: (@MainActor @Sendable (CaptureState) -> Void)?

    private var processTapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var format: AVAudioFormat?
    private var sessionID: UUID?
    private var watchdog: Task<Void, Never>?
    private var firstFrameSeen = false
    private let heartbeat = Heartbeat()
    private let outputQueue = DispatchQueue(label: "MeetingCopilotAudioCapture.systemPCM")
    private let permissionProbe: @Sendable () -> Bool?

    /// `permissionProbe` is only for isolated tests and injected denials.
    /// `nil` means "no public preflight available; try the real tap".
    public init(permissionProbe: @escaping @Sendable () -> Bool? = { nil }) {
        self.permissionProbe = permissionProbe
    }

    /// displayID remains in the public signature for source compatibility but
    /// is intentionally unused: a Core Audio tap captures system output
    /// without requesting screen-recording access.
    public func start(intent: CaptureIntent, displayID: CGDirectDisplayID,
                      sampleRate: Int = 48000, channels: Int = 2,
                      noDataTimeout: Double? = nil,
                      onFrame: @escaping AudioFrameHandler) async throws {
        do {
            try CaptureGate.systemAudio(intent, permissionGranted: true)
            if let granted = permissionProbe(), !granted {
                throw CaptureFailure.screenPermissionMissing
            }
            guard processTapID == kAudioObjectUnknown,
                  aggregateDeviceID == kAudioObjectUnknown,
                  ioProcID == nil,
                  state != .starting, state != .stopping else {
                throw CaptureFailure.alreadyActive
            }
            guard (sampleRate == 48000 || sampleRate == 24000), (1...2).contains(channels),
                  noDataTimeout == nil || (noDataTimeout!.isFinite && noDataTimeout! >= 1) else {
                throw CaptureFailure.invalidConfiguration
            }
        } catch {
            if processTapID == kAudioObjectUnknown { setState(.failed(asFailure(error))) }
            throw error
        }

        let id = UUID()
        sessionID = id
        firstFrameSeen = false
        setState(.starting)
        do {
            try createTap(excludingPID: getpid())
            guard sessionID == id, let format else { throw CancellationError() }

            var procID: AudioDeviceIOProcID?
            let heartbeat = self.heartbeat
            let firstFrame = { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.sessionID == id else { return }
                    self.firstFrameSeen = true
                }
            }
            let failure = { [weak self] (error: Error) in
                Task { @MainActor [weak self] in
                    guard let self, self.sessionID == id else { return }
                    await self.fail(self.asFailure(error))
                }
            }
            let status = AudioDeviceCreateIOProcIDWithBlock(
                &procID, aggregateDeviceID, outputQueue
            ) { _, inputData, inputTime, _, _ in
                guard inputData.pointee.mNumberBuffers > 0 else { return }
                do {
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                        bufferListNoCopy: inputData,
                                                        deallocator: nil) else {
                        throw CaptureFailure.invalidBuffer
                    }
                    if buffer.frameLength == 0 {
                        let lists = UnsafeMutableAudioBufferListPointer(
                            UnsafeMutablePointer(mutating: inputData))
                        let bytesPerFrame = buffer.format.streamDescription.pointee.mBytesPerFrame
                        guard bytesPerFrame > 0 else { throw CaptureFailure.invalidBuffer }
                        let bytes = lists.reduce(0) { $0 + Int($1.mDataByteSize) }
                        buffer.frameLength = AVAudioFrameCount(bytes / Int(bytesPerFrame))
                    }
                    try PCMUtilities.validate(buffer)
                    let now = ProcessInfo.processInfo.systemUptime
                    heartbeat.update(now)
                    _ = firstFrame()
                    let seconds = inputTime.pointee.mFlags.contains(.sampleTimeValid)
                        ? inputTime.pointee.mSampleTime / format.sampleRate
                        : nil
                    onFrame(AudioFrame(buffer: buffer,
                        timestamp: SourceTimestamp(source: .systemAudio,
                            hostSeconds: nil, samplePosition: nil,
                            sampleRate: format.sampleRate,
                            presentationSeconds: seconds,
                            receivedUptime: now)))
                } catch {
                    _ = failure(error)
                }
            }
            try CoreAudioTapSupport.requireSuccess(status, "创建系统音频回调")
            ioProcID = procID
            let startStatus = AudioDeviceStart(aggregateDeviceID, procID)
            try CoreAudioTapSupport.requireSuccess(startStatus, "启动系统音频设备")
            guard sessionID == id else {
                cleanup()
                throw CancellationError()
            }
            heartbeat.update(ProcessInfo.processInfo.systemUptime)
            try await waitForFirstFrame(sessionID: id, timeout: noDataTimeout ?? 8)
            setState(.running)
            if let timeout = noDataTimeout {
                watchdog = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
                        guard let self, self.sessionID == id else { return }
                        if self.heartbeat.age(at: ProcessInfo.processInfo.systemUptime) > timeout {
                            await self.fail(.noDataTimeout)
                            return
                        }
                    }
                }
            }
        } catch {
            if sessionID == id {
                let failure = asFailure(error)
                await fail(failure)
                throw failure
            }
            cleanup()
            throw error
        }
    }

    /// Idempotent stop. Native teardown happens synchronously on MainActor;
    /// the async signature is retained for the existing callers.
    public func stop() async throws {
        if state == .stopping { throw CaptureFailure.alreadyActive }
        sessionID = nil
        watchdog?.cancel()
        watchdog = nil
        guard processTapID != kAudioObjectUnknown ||
              aggregateDeviceID != kAudioObjectUnknown ||
              ioProcID != nil else {
            if state != .stopped { setState(.stopped) }
            return
        }
        setState(.stopping)
        var firstFailure: OSStatus = noErr
        if aggregateDeviceID != kAudioObjectUnknown, let ioProcID {
            let status = AudioDeviceStop(aggregateDeviceID, ioProcID)
            if status != noErr, firstFailure == noErr { firstFailure = status }
            let destroyStatus = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            if destroyStatus != noErr, firstFailure == noErr { firstFailure = destroyStatus }
            self.ioProcID = nil
        }
        if aggregateDeviceID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            if status != noErr, firstFailure == noErr { firstFailure = status }
            aggregateDeviceID = kAudioObjectUnknown
        }
        if processTapID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyProcessTap(processTapID)
            if status != noErr, firstFailure == noErr { firstFailure = status }
            processTapID = kAudioObjectUnknown
        }
        format = nil
        if firstFailure == noErr {
            setState(.stopped)
        } else {
            let failure = asFailure(CoreAudioTapError.operation("停止系统音频设备", firstFailure))
            setState(.failed(failure))
            throw failure
        }
    }

    /// A short tap-only authorization probe. No aggregate device or long-lived
    /// capture remains. This is called only from the explicit permission button.
    public static func probePermission() throws {
        var tap = AudioObjectID(kAudioObjectUnknown)
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "Meeting Copilot System Audio Permission"
        description.muteBehavior = .unmuted
        let status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else {
            throw CaptureFailure.nativeError("创建系统录音权限探针失败（Core Audio \(status)）")
        }
        if tap != kAudioObjectUnknown {
            _ = AudioHardwareDestroyProcessTap(tap)
        }
    }

    private func createTap(excludingPID pid: pid_t) throws {
        let ownProcess = try CoreAudioTapSupport.processObject(for: pid)
        let excluded = ownProcess == kAudioObjectUnknown ? [] : [ownProcess]
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.uuid = UUID()
        description.name = "Meeting Copilot System Audio"
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        try CoreAudioTapSupport.requireSuccess(tapStatus, "创建系统录音")
        processTapID = tap

        let asbd = try CoreAudioTapSupport.tapFormat(tap)
        var streamDescription = asbd
        guard let nativeFormat = AVAudioFormat(streamDescription: &streamDescription) else {
            throw CaptureFailure.invalidBuffer
        }
        format = nativeFormat

        let outputUID = try CoreAudioTapSupport.defaultOutputUID()
        let aggregateUID = UUID().uuidString
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Meeting Copilot System Audio",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString
            ]]
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary, &aggregate)
        try CoreAudioTapSupport.requireSuccess(aggregateStatus, "创建系统音频聚合设备")
        aggregateDeviceID = aggregate
    }

    private func fail(_ failure: CaptureFailure) async {
        do { try await stop() } catch {
            // stop() reports the native teardown failure and clears what it can.
        }
        setState(.failed(failure))
    }

    private func setState(_ next: CaptureState) {
        state = next
        if let handler = onStateChange { Task { @MainActor in handler(next) } }
    }

    private func waitForFirstFrame(sessionID id: UUID, timeout: Double) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !firstFrameSeen {
            guard sessionID == id else { throw CancellationError() }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw CaptureFailure.noAudioFrames
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func cleanup() {
        sessionID = nil
        watchdog?.cancel(); watchdog = nil
        if aggregateDeviceID != kAudioObjectUnknown, let ioProcID {
            _ = AudioDeviceStop(aggregateDeviceID, ioProcID)
            _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateDeviceID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if processTapID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyProcessTap(processTapID)
            processTapID = kAudioObjectUnknown
        }
        format = nil
    }

    private func asFailure(_ error: Error) -> CaptureFailure {
        if let failure = error as? CaptureFailure { return failure }
        let ns = error as NSError
        if ns.domain == NSOSStatusErrorDomain,
           let failure = captureFailure(for: OSStatus(ns.code)) {
            return failure
        }
        return .nativeError(error.localizedDescription)
    }

    private func captureFailure(for status: OSStatus) -> CaptureFailure? {
        switch status {
        case kAudioHardwareIllegalOperationError, kAudioHardwareUnsupportedOperationError:
            return .nativeError("系统音频设备拒绝该操作（Core Audio \(status)）；请确认系统为 macOS 14.2 或更高版本。")
        case kAudioHardwareBadObjectError, kAudioHardwareBadDeviceError:
            return .nativeError("系统音频设备不可用（Core Audio \(status)）；请检查当前输出设备后重试。")
        default:
            return nil
        }
    }

    deinit {
        watchdog?.cancel()
        if aggregateDeviceID != kAudioObjectUnknown, let ioProcID {
            _ = AudioDeviceStop(aggregateDeviceID, ioProcID)
            _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
        }
        if aggregateDeviceID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }
        if processTapID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyProcessTap(processTapID)
        }
    }
}
