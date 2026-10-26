import Foundation

public struct TimedSpeechToken: Codable, Equatable, Sendable {
    public let text: String, startSeconds: Double, durationSeconds: Double, confidence: Float
    public init(text: String, startSeconds: Double, durationSeconds: Double, confidence: Float) {
        self.text = text; self.startSeconds = startSeconds; self.durationSeconds = durationSeconds; self.confidence = confidence
    }
}
public struct BilingualWindow: Codable, Equatable, Sendable {
    public let startSeconds: Double, endSeconds: Double
    public let chineseCandidates: [TimedSpeechToken], englishCandidates: [TimedSpeechToken]
    public let requiresHumanReview: Bool
    public let decision: String
}
/// Both lanes use offsets relative to the SAME audio file/task origin.
/// Confidence is recorded, never compared across language models to decide the language.
public enum BilingualTimeAlignment {
    public static func windows(chinese: [TimedSpeechToken], english: [TimedSpeechToken], audioDurationSeconds: Double, windowSeconds: Double, maxWindows: Int) throws -> [BilingualWindow] {
        guard audioDurationSeconds.isFinite, audioDurationSeconds > 0, windowSeconds.isFinite, windowSeconds > 0, maxWindows > 0,
              ceil(audioDurationSeconds / windowSeconds) <= Double(maxWindows) else { throw CoreError.invalid("WINDOW_LIMIT_OR_DURATION") }
        for token in chinese + english {
            guard token.startSeconds.isFinite, token.durationSeconds.isFinite, token.startSeconds >= 0, token.durationSeconds > 0,
                  (token.startSeconds + token.durationSeconds).isFinite, token.confidence.isFinite, token.confidence >= 0, token.confidence <= 1 else { throw CoreError.invalid("INVALID_TIMED_TOKEN") }
        }
        let zh = chinese.sorted { $0.startSeconds < $1.startSeconds }, en = english.sorted { $0.startSeconds < $1.startSeconds }
        return (0..<Int(ceil(audioDurationSeconds / windowSeconds))).map { i in
            let start = Double(i) * windowSeconds, end = min(audioDurationSeconds, start + windowSeconds)
            let z = zh.filter { $0.startSeconds < end && $0.startSeconds + $0.durationSeconds > start }
            let e = en.filter { $0.startSeconds < end && $0.startSeconds + $0.durationSeconds > start }
            // Single-lane speech also needs review: the other lane may have failed/dropped language.
            return BilingualWindow(startSeconds: start, endSeconds: end, chineseCandidates: z, englishCandidates: e,
                requiresHumanReview: !z.isEmpty || !e.isEmpty, decision: z.isEmpty && e.isEmpty ? "no_hypothesis" : "bilingual_candidates_unresolved")
        }
    }
}
