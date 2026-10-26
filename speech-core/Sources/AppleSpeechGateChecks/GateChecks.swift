import Foundation
import AVFoundation
import AppleOfflineSpeech
import SpeechCore

@MainActor final class CountingBackend: OfflinePCMRecognitionBackend {
    var osAuthorized = true
    var begins = 0, appends = 0, finishes = 0, cancels = 0
    var beginFailure: OfflineSpeechFailure?
    var locales: [OfflineSpeechLocale] = []
    var callbacks: [@MainActor @Sendable (SpeechBackendObservation) -> Void] = []
    var ownedBuffer: AVAudioPCMBuffer?
    func begin(locale: OfflineSpeechLocale, deliver: @escaping @MainActor @Sendable (SpeechBackendObservation) -> Void) throws {
        begins += 1; locales.append(locale)
        if let beginFailure { throw beginFailure }
        callbacks.append(deliver)
    }
    func append(_ buffer: AVAudioPCMBuffer) throws { appends += 1; ownedBuffer = buffer }
    func finishAudio() { finishes += 1 }
    func cancel() { cancels += 1 }
}
@MainActor final class OutputBox { var values: [OfflineSpeechOutput] = [] }
@MainActor final class GateChecks {
    var failures = 0
    let allowed = SpeechStartIntent(userInitiated: true, speechEnabled: true, onDeviceProcessingAuthorized: true)
    func check(_ ok: Bool, _ name: String) { if !ok { failures += 1; print("FAIL \(name)") } }
    func rejects(_ reason: OfflineSpeechFailure, _ action: () throws -> Void) {
        do { try action(); check(false, "expected \(reason)") }
        catch { check((error as? OfflineSpeechFailure) == reason, "error \(error) expected \(reason)") }
    }
    func start(_ adapter: AppleOfflineSpeechAdapter, intent: SpeechStartIntent? = nil, locale: OfflineSpeechLocale = .simplifiedChinese, box: OutputBox = OutputBox(), segment: String = "seg1") throws {
        try adapter.start(intent: intent ?? allowed, locale: locale, sessionId: "synthetic", channelId: "c1", streamId: "st1", segmentId: segment) { output in box.values.append(output) }
    }
    func pcm(_ count: UInt32 = 4) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { throw OfflineSpeechFailure.invalidPCM }
        buffer.frameLength = count
        for frame in 0..<Int(count) { buffer.floatChannelData![0][frame] = 0 }
        return buffer
    }
    let r1 = PCMSourceRange(frameStart: 0, frameEnd: 4, mappingRevision: 1, startNs: 0, endNs: 250000)
    let r2 = PCMSourceRange(frameStart: 4, frameEnd: 8, mappingRevision: 1, startNs: 250000, endNs: 500000)
    func run() throws {
        // Negative gates are checked against the actual adapter, not only a gate helper.
        for (intent, reason) in [
            (SpeechStartIntent(), OfflineSpeechFailure.userStartRequired),
            (SpeechStartIntent(userInitiated: true), .speechDisabled),
            (SpeechStartIntent(userInitiated: true, speechEnabled: true), .explicitAuthorizationRequired)
        ] {
            let backend = CountingBackend(), adapter = try AppleOfflineSpeechAdapter(maxInputFrames: 8, finalResultTimeoutSeconds: 5, backend: backend)
            rejects(reason) { try start(adapter, intent: intent) }
            check(backend.begins == 0 && backend.appends == 0 && adapter.state == .idle, "blocked gate has no task")
        }
        print("PASS explicit start/speech-enabled/on-device consent gates")
        let denied = CountingBackend(); denied.osAuthorized = false
        let deniedAdapter = try AppleOfflineSpeechAdapter(maxInputFrames: 8, finalResultTimeoutSeconds: 5, backend: denied)
        rejects(.osAuthorizationMissing) { try start(deniedAdapter) }
        check(denied.begins == 0, "OS denial does not create task")
        print("PASS existing OS authorization gate")
        let unavailable = CountingBackend(); unavailable.beginFailure = .onDeviceUnavailable
        let unavailableAdapter = try AppleOfflineSpeechAdapter(maxInputFrames: 8, finalResultTimeoutSeconds: 5, backend: unavailable)
        rejects(.onDeviceUnavailable) { try start(unavailableAdapter) }
        check(unavailable.begins == 1 && unavailableAdapter.state == .failed, "offline unavailable has no fallback retry")
        print("PASS on-device backend failure is terminal without fallback")
        let backend = CountingBackend(), adapter = try AppleOfflineSpeechAdapter(maxInputFrames: 8, finalResultTimeoutSeconds: 5, backend: backend), box = OutputBox()
        rejects(.notAcceptingPCM) { try adapter.append(pcm(), source: r1) }
        try start(adapter, box: box)
        rejects(.alreadyActive) { try start(adapter) }
        check(backend.locales == [.simplifiedChinese], "Chinese explicit locale")
        let original = try pcm(); original.floatChannelData![0][0] = 0.25
        try adapter.append(original, source: r1)
        original.floatChannelData![0][0] = 0.75
        check(backend.ownedBuffer?.floatChannelData?[0][0] == 0.25, "PCM retained as owned memory copy")
        backend.callbacks[0](.hypothesis(text: "合成", isFinal: false))
        backend.callbacks[0](.hypothesis(text: "合成", isFinal: false))
        try adapter.append(pcm(), source: r2)
        try adapter.finishAudio()
        check(adapter.state == .finishing && box.values.count == 1 && backend.finishes == 1, "finish not fabricated final")
        backend.callbacks[0](.hypothesis(text: "合成文本", isFinal: true))
        check(adapter.state == .finalized && box.values.count == 2, "partial/final delivered")
        guard case .transcript(let partial) = box.values[0], case .transcript(let final) = box.values[1] else { throw OfflineSpeechFailure.backend("BAD_TEST_OUTPUT") }
        check(partial.status == "partial" && partial.revision == 1 && final.status == "final" && final.revision == 2 && final.replacesRevision == 1, "contiguous partial/final revision")
        check(final.source == PCMSourceRange(frameStart: 0, frameEnd: 8, mappingRevision: 1, startNs: 0, endNs: 500000), "source range preserves appended PCM")
        let e = final.event(id: "generated", sequence: 7, emittedAtNs: 600000)
        check(e.eventSeq == 7 && e.speakerId == nil && e.sourceSpans?.first?.frameEnd == 8, "caller event sequence and unknown speaker/source spans")
        check(try SpeechEvent.decode(e.encoded()) == e, "source span JSON roundtrip")
        print("PASS owned PCM copy/partial/final/source localization/event roundtrip")
        backend.callbacks[0](.hypothesis(text: "late", isFinal: true))
        check(box.values.count == 2, "late post-final callback ignored")
        try start(adapter, locale: .englishUS, box: box, segment: "seg2")
        check(backend.locales == [.simplifiedChinese, .englishUS], "English explicit locale")
        backend.callbacks[0](.hypothesis(text: "old task", isFinal: true))
        check(box.values.count == 2, "old-generation callback cannot affect restarted segment")
        adapter.cancel(); check(adapter.state == .cancelled, "explicit cancel state")
        print("PASS locale choice/generation isolation/cancellation")
        let emptyBackend = CountingBackend(), empty = try AppleOfflineSpeechAdapter(maxInputFrames: 8, finalResultTimeoutSeconds: 5, backend: emptyBackend)
        try start(empty); rejects(.noSourceAudio) { try empty.finishAudio() }
        check(emptyBackend.finishes == 0 && empty.state == .failed, "empty source rejected")
        let limitBackend = CountingBackend(), limit = try AppleOfflineSpeechAdapter(maxInputFrames: 4, finalResultTimeoutSeconds: 5, backend: limitBackend)
        try start(limit); try limit.append(pcm(), source: r1)
        rejects(.inputLimitExceeded) { try limit.append(pcm(), source: r2) }
        check(limitBackend.appends == 1 && limit.state == .failed, "finite input limit")
        print("PASS empty source and input capacity boundaries")
        let gapBackend = CountingBackend(), gap = try AppleOfflineSpeechAdapter(maxInputFrames: 12, finalResultTimeoutSeconds: 5, backend: gapBackend)
        try start(gap); try gap.append(pcm(), source: r1)
        rejects(.nonContiguousInput) { try gap.append(pcm(), source: PCMSourceRange(frameStart: 5, frameEnd: 9, mappingRevision: 1, startNs: 300000, endNs: 550000)) }
        check(gapBackend.appends == 1 && gap.state == .failed, "gap cannot silently join audio")
        let revokeBackend = CountingBackend(), revoke = try AppleOfflineSpeechAdapter(maxInputFrames: 8, finalResultTimeoutSeconds: 5, backend: revokeBackend)
        try start(revoke); revokeBackend.osAuthorized = false
        rejects(.osAuthorizationMissing) { try revoke.append(pcm(), source: r1) }
        check(revokeBackend.appends == 0 && revoke.state == .failed, "revoked permission blocks input")
        print("PASS discontinuity and revoked authorization")
        let timeoutBackend = CountingBackend(), timeout = try AppleOfflineSpeechAdapter(maxInputFrames: 8, finalResultTimeoutSeconds: 5, backend: timeoutBackend)
        let timeoutBox = OutputBox(); try start(timeout, box: timeoutBox)
        try timeout.append(pcm(), source: r1); try timeout.finishAudio(atUptime: 10)
        timeout.pollFinalDeadline(atUptime: 14); check(timeout.state == .finishing, "before final deadline")
        timeout.pollFinalDeadline(atUptime: 15)
        check(timeout.state == .failed && timeout.failure == .finalResultTimeout && timeoutBox.values == [.failed(.finalResultTimeout)], "missing final times out without transcript")
        timeoutBackend.callbacks[0](.hypothesis(text: "after deadline", isFinal: true))
        check(timeoutBox.values.count == 1, "late result after deadline ignored")
        print("PASS bounded final wait and no fabricated final")
    }
}
@main struct AppleSpeechGateChecks {
    @MainActor static func main() {
        let checks = GateChecks()
        do { try checks.run() } catch { checks.failures += 1; print("FAIL unexpected \(error)") }
        print("RESULT: \(checks.failures) failures; test backend + synthetic PCM only; Apple recognition tasks=0; permission requests=0; capture=0")
        exit(checks.failures == 0 ? 0 : 1)
    }
}
