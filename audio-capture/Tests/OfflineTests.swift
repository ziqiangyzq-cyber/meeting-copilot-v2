import Foundation
import AVFoundation
import CoreMedia
import MeetingCopilotAudioCapture

func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw NSError(domain: "OfflineAudioTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
func rejects(_ expected: CaptureFailure, _ action: () throws -> Void) throws {
    do { try action(); throw NSError(domain: "OfflineAudioTests", code: 2) }
    catch let error as CaptureFailure { try check(error == expected, "Expected \(expected), got \(error)") }
}

@main struct OfflineTests {
    @MainActor static func main() async throws {
        let enabled = CaptureIntent(userInitiated: true, microphoneEnabled: true, systemAudioEnabled: true)
        try rejects(.userActionRequired) { try CaptureGate.microphone(CaptureIntent(), permissionGranted: true) }
        try rejects(.channelDisabled) { try CaptureGate.microphone(CaptureIntent(userInitiated: true), permissionGranted: true) }
        try rejects(.microphonePermissionMissing) { try CaptureGate.microphone(enabled, permissionGranted: false) }
        try rejects(.screenPermissionMissing) { try CaptureGate.systemAudio(enabled, permissionGranted: false) }
        try rejects(.channelDisabled) { try CaptureGate.systemAudio(CaptureIntent(userInitiated: true), permissionGranted: true) }
        try CaptureGate.microphone(enabled, permissionGranted: true)
        try CaptureGate.systemAudio(enabled, permissionGranted: true)

        // Inject false probes: start exits before any real permission probe or native device setup.
        let mic = MicrophoneCapture(permissionProbe: { false })
        try rejects(.microphonePermissionMissing) {
            try mic.start(intent: enabled) { _ in fatalError("Unexpected live mic frame") }
        }
        try check(mic.state == .failed(.microphonePermissionMissing), "Mic denial state")
        mic.stop(); mic.stop()
        try check(mic.state == .stopped, "Mic stop is idempotent after denied start")
        let system = SystemAudioCapture(permissionProbe: { false })
        do {
            try await system.start(intent: enabled, displayID: 1) { _ in fatalError("Unexpected live system frame") }
            throw NSError(domain: "OfflineAudioTests", code: 3)
        } catch let error as CaptureFailure {
            try check(error == .screenPermissionMissing, "System denial")
        }
        try check(system.state == .failed(.screenPermissionMissing), "System denial state")
        try await system.stop(); try await system.stop()
        try check(system.state == .stopped, "System stop idempotent after denied start")
        print("PASS explicit consent/channel gates and injected unauthorized starts; no device opened")

        for interleaved in [false, true] {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: interleaved)!
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32)!
            pcm.frameLength = 32
            let lists = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
            for entry in lists {
                memset(entry.mData!, 0x2A, Int(entry.mDataByteSize))
            }
            try PCMUtilities.validate(pcm)
            let copy = try PCMUtilities.copy(pcm)
            try check(copy.frameLength == 32 && copy.format == format, "PCM format/frame length preserved")
            let copies = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for index in lists.indices {
                try check(lists[index].mData != copies[index].mData, "Copy owns memory")
                try check(memcmp(lists[index].mData!, copies[index].mData!, Int(lists[index].mDataByteSize)) == 0, "PCM bytes preserved")
            }
        }
        let zero = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!, frameCapacity: 32)!
        try rejects(.invalidBuffer) { try PCMUtilities.validate(zero) }
        print("PASS interleaved/planar PCM copies, ownership, format and empty-buffer rejection")

        let host = AVAudioTime.hostTime(forSeconds: 12.5)
        let time = AVAudioTime(hostTime: host, sampleTime: 24000, atRate: 48000)
        let micTime = SourceTimestamp.microphone(time, sampleRate: 48000, receivedUptime: 14)
        try check(micTime.source == .microphone && micTime.samplePosition == 24000, "Mic source/sample position")
        try check(abs(micTime.hostSeconds! - 12.5) < 0.00001 && micTime.presentationSeconds == nil, "Host time conversion")
        let pts = SourceTimestamp.systemAudio(CMTime(value: 96000, timescale: 48000), sampleRate: 48000, receivedUptime: 4)
        try check(pts.source == .systemAudio && pts.presentationSeconds == 2 && pts.hostSeconds == nil, "Source PTS preserved")
        let invalid = SourceTimestamp.systemAudio(.invalid, sampleRate: 48000, receivedUptime: 4)
        try check(invalid.presentationSeconds == nil, "Invalid PTS is absent, not invented")
        print("PASS source identity, host/sample/PTS timestamp conversion and invalid PTS")

        // In-memory synthesized PCM CMSampleBuffer, not a real recording or device stream.
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        var description: CMAudioFormatDescription?
        try check(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
            asbd: format.streamDescription, layoutSize: 0, layout: nil, magicCookieSize: 0,
            magicCookie: nil, extensions: nil, formatDescriptionOut: &description) == noErr, "Synthetic audio format")
        var block: CMBlockBuffer?
        let byteCount = 32 * MemoryLayout<Float>.size
        try check(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: byteCount, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &block) == noErr, "Synthetic PCM block")
        try check(CMBlockBufferFillDataBytes(with: 0, blockBuffer: block!, offsetIntoDestination: 0,
            dataLength: byteCount) == noErr, "Fill synthetic PCM")
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000),
            presentationTimeStamp: CMTime(value: 48000, timescale: 48000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        try check(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: description, sampleCount: 32, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &sample) == noErr, "Synthetic PCM sample buffer")
        let decoded = try SystemPCMDecoder.decode(sample!)
        try check(decoded.frameLength == 32 && decoded.format.sampleRate == 48000 && decoded.format.channelCount == 1, "System PCM decode")
        try check(decoded.floatChannelData![0][0] == 0, "Synthetic zero PCM preserved")
        print("PASS ScreenCaptureKit compatibility decoder using synthetic memory-only CMSampleBuffer")

        // Live Core Audio Tap PCM conversion from a synthetic AudioBufferList.
        // This exercises the frame-length and timestamp path without opening a
        // device or requesting permission.
        let tapFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000,
                                      channels: 2, interleaved: false)!
        let tapBuffer = AVAudioPCMBuffer(pcmFormat: tapFormat, frameCapacity: 256)!
        tapBuffer.frameLength = 256
        for channel in 0..<Int(tapFormat.channelCount) {
            for frame in 0..<Int(tapBuffer.frameLength) {
                tapBuffer.floatChannelData![channel][frame] = Float(frame) / 256
            }
        }
        try PCMUtilities.validate(tapBuffer)
        let tapCopy = try PCMUtilities.copy(tapBuffer)
        try check(tapCopy.frameLength == 256 && tapCopy.format.channelCount == 2,
                  "Core Audio tap PCM conversion")
        print("PASS Core Audio Tap PCM copy, frame length, channel format")
        print("ALL OFFLINE TESTS PASSED; live capture, permission prompting and audio file writing were not invoked")
    }
}
