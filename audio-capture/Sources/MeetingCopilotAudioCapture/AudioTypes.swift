import Foundation
import AVFoundation
import CoreMedia
import CoreGraphics

public enum AudioSource: String, Sendable { case microphone, systemAudio }
public enum CaptureState: Equatable, Sendable {
    case idle, starting, running, stopping, stopped
    case failed(CaptureFailure)
}
public enum CaptureFailure: LocalizedError, Equatable, Sendable {
    case userActionRequired, channelDisabled, microphonePermissionMissing, screenPermissionMissing
    case alreadyActive, invalidConfiguration, invalidBuffer, displayUnavailable
    case deviceInterrupted, noDataTimeout, noAudioFrames
    case nativeError(String)
}

extension CaptureFailure {
    /// User-facing diagnostics for system audio. Keep the native code visible
    /// so permission failures can be distinguished from no audio.
    public var errorDescription: String? {
        switch self {
        case .userActionRequired:
            return "请从 App 内点击“开始”后再采集。"
        case .channelDisabled:
            return "当前声音来源未启用。"
        case .microphonePermissionMissing:
            return "尚未允许使用麦克风，请到“系统设置 > 隐私与安全性 > 麦克风”授权。"
        case .screenPermissionMissing:
            return "尚未允许电脑声音采集，请到“系统设置 > 隐私与安全性 > 仅系统录音”授权。"
        case .alreadyActive:
            return "采集已经在运行或正在切换，请稍候。"
        case .invalidConfiguration:
            return "音频采集参数无效。"
        case .invalidBuffer:
            return "系统返回的音频数据格式无效。"
        case .displayUnavailable:
            return "当前显示范围不可用，请在高级设置中重新选择屏幕。"
        case .deviceInterrupted:
            return "音频设备已断开或被系统切换。"
        case .noDataTimeout:
            return "电脑声音采集已启动，但音频数据中断；请停止后重试。"
        case .noAudioFrames:
            return "电脑声音采集已启动，但没有返回音频帧。请确认系统正在播放声音，并在“系统设置 > 隐私与安全性 > 仅系统录音”中允许 Meeting Copilot。"
        case .nativeError(let message):
            return "电脑声音采集失败：\(message)"
        }
    }
}
/// The caller sets these values only in a real user-initiated Start action.
/// This value does not request OS permission and is not proof of an actual UI action.
public struct CaptureIntent: Sendable {
    public var userInitiated: Bool
    public var microphoneEnabled: Bool
    public var systemAudioEnabled: Bool
    public init(userInitiated: Bool = false, microphoneEnabled: Bool = false, systemAudioEnabled: Bool = false) {
        self.userInitiated = userInitiated
        self.microphoneEnabled = microphoneEnabled
        self.systemAudioEnabled = systemAudioEnabled
    }
}
public enum CaptureGate {
    public static func microphone(_ intent: CaptureIntent, permissionGranted: Bool) throws {
        guard intent.userInitiated else { throw CaptureFailure.userActionRequired }
        guard intent.microphoneEnabled else { throw CaptureFailure.channelDisabled }
        guard permissionGranted else { throw CaptureFailure.microphonePermissionMissing }
    }
    public static func systemAudio(_ intent: CaptureIntent, permissionGranted: Bool) throws {
        guard intent.userInitiated else { throw CaptureFailure.userActionRequired }
        guard intent.systemAudioEnabled else { throw CaptureFailure.channelDisabled }
        guard permissionGranted else { throw CaptureFailure.screenPermissionMissing }
    }
}
public enum ExistingPermissions {
    /// Query only. Does not request access or initialize an audio device.
    public static func microphone() -> Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    /// There is no public preflight for Core Audio Tap / "仅系统录音".
    /// The App learns the result by creating a minimal tap from the explicit
    /// permission button or by the real capture path. Returning false here
    /// must never be treated as a denial.
    public static func systemAudio() -> Bool { false }
}
public struct SourceTimestamp: Equatable, Sendable {
    public let source: AudioSource
    /// Monotonic host-clock time in seconds, when available; never wall-clock time.
    public let hostSeconds: Double?
    /// Native source sample position/rate (mic), not resampled/mixed position.
    public let samplePosition: Int64?
    public let sampleRate: Double
    /// Original CMSampleBuffer PTS in seconds (system audio), not receipt time.
    public let presentationSeconds: Double?
    /// Monotonic receipt time; use only to observe scheduling delay/heartbeat.
    public let receivedUptime: Double
    public init(source: AudioSource, hostSeconds: Double?, samplePosition: Int64?, sampleRate: Double,
                presentationSeconds: Double?, receivedUptime: Double) {
        self.source = source; self.hostSeconds = hostSeconds; self.samplePosition = samplePosition
        self.sampleRate = sampleRate; self.presentationSeconds = presentationSeconds; self.receivedUptime = receivedUptime
    }
    public static func microphone(_ time: AVAudioTime, sampleRate: Double, receivedUptime: Double) -> SourceTimestamp {
        SourceTimestamp(source: .microphone,
            hostSeconds: time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : nil,
            samplePosition: time.isSampleTimeValid ? time.sampleTime : nil, sampleRate: sampleRate,
            presentationSeconds: nil, receivedUptime: receivedUptime)
    }
    public static func systemAudio(_ pts: CMTime, sampleRate: Double, receivedUptime: Double) -> SourceTimestamp {
        let seconds = CMTimeGetSeconds(pts)
        return SourceTimestamp(source: .systemAudio, hostSeconds: nil, samplePosition: nil,
            sampleRate: sampleRate, presentationSeconds: pts.isNumeric && seconds.isFinite ? seconds : nil,
            receivedUptime: receivedUptime)
    }
}
/// PCM is borrowed for this callback's duration. For asynchronous retention call PCMUtilities.copy.
/// The callback runs on an audio delivery thread/queue, never assume MainActor.
public struct AudioFrame {
    public let buffer: AVAudioPCMBuffer
    public let timestamp: SourceTimestamp
    public var source: AudioSource { timestamp.source }
    public init(buffer: AVAudioPCMBuffer, timestamp: SourceTimestamp) { self.buffer = buffer; self.timestamp = timestamp }
}
public typealias AudioFrameHandler = @Sendable (AudioFrame) -> Void

public enum PCMUtilities {
    public static func validate(_ buffer: AVAudioPCMBuffer) throws {
        guard buffer.format.sampleRate.isFinite, buffer.format.sampleRate > 0,
              buffer.format.channelCount > 0, buffer.frameLength > 0,
              buffer.frameLength <= buffer.frameCapacity else { throw CaptureFailure.invalidBuffer }
    }
    /// A memory-only owned copy. Does not resample, write a file or open a device.
    public static func copy(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        try validate(buffer)
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            throw CaptureFailure.invalidBuffer
        }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == target.count else { throw CaptureFailure.invalidBuffer }
        for index in source.indices {
            guard let src = source[index].mData, let dst = target[index].mData,
                  source[index].mDataByteSize <= target[index].mDataByteSize else { throw CaptureFailure.invalidBuffer }
            memcpy(dst, src, Int(source[index].mDataByteSize))
        }
        return copy
    }

    /// Copies borrowed capture PCM and converts it to non-interleaved Float32.
    /// Core Audio process taps can deliver interleaved Float32, while the
    /// recognizer ingress and sample extraction require planar Float32.
    public static func copyAsPlanarFloat32(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        try validate(buffer)
        let format = buffer.format
        guard format.commonFormat == .pcmFormatFloat32 else {
            throw CaptureFailure.invalidBuffer
        }
        if !format.isInterleaved {
            return try copy(buffer)
        }
        guard let planar = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: format.sampleRate,
                                         channels: format.channelCount,
                                         interleaved: false),
              let output = AVAudioPCMBuffer(pcmFormat: planar,
                                            frameCapacity: buffer.frameLength),
              let source = buffer.floatChannelData?[0],
              let channels = output.floatChannelData else {
            throw CaptureFailure.invalidBuffer
        }
        output.frameLength = buffer.frameLength
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        for frame in 0..<frameCount {
            let base = frame * channelCount
            for channel in 0..<channelCount {
                channels[channel][frame] = source[base + channel]
            }
        }
        return output
    }
}

/// Locked heartbeat only: no PCM held, no callback blocking on MainActor.
final class Heartbeat: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Double = 0
    func update(_ time: Double) { lock.lock(); last = time; lock.unlock() }
    func age(at time: Double) -> Double { lock.lock(); defer { lock.unlock() }; return time - last }
}
