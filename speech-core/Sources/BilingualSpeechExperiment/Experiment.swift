import Foundation
import AVFoundation
@preconcurrency import Speech
import SpeechCore

struct AudioCase: Codable, Sendable {
    let id: String, audioPath: String, voiceName: String, voiceLocale: String, groundtruth: String
    let expectedTerms: [String]
}
struct Condition: Codable, Sendable {
    let id: String, contextualStrings: [String]
    let addsPunctuation: Bool?
}
struct ExperimentInput: Codable, Sendable {
    let audios: [AudioCase], locales: [String], conditions: [Condition]
    let timeoutSeconds: Double, windowSeconds: Double
    let maxWindows: Int
    let syntheticAudioAuthorized: Bool
    func validate() throws {
        guard syntheticAudioAuthorized, !audios.isEmpty, audios.count <= 100, !conditions.isEmpty, conditions.count <= 20,
              !locales.isEmpty, locales.count <= 2, Set(locales).count == locales.count,
              locales.allSatisfy({ ["zh-CN", "zh-Hans-CN", "en-US"].contains($0) }),
              locales.filter({ $0.hasPrefix("zh") }).count <= 1,
              timeoutSeconds.isFinite, timeoutSeconds > 0, timeoutSeconds <= 3600,
              windowSeconds.isFinite, windowSeconds > 0, maxWindows > 0,
              Set(audios.map(\.id)).count == audios.count, Set(conditions.map(\.id)).count == conditions.count,
              audios.allSatisfy({ !$0.id.isEmpty && $0.audioPath.hasPrefix("/") && !$0.voiceName.isEmpty && !$0.voiceLocale.isEmpty && !$0.groundtruth.isEmpty }),
              conditions.allSatisfy({ !$0.id.isEmpty && $0.contextualStrings.count <= 100 && $0.contextualStrings.allSatisfy({ !$0.isEmpty && $0.count <= 200 }) }) else { throw CoreError.invalid("INVALID_EXPERIMENT_CONFIG") }
    }
}
struct TermCheck: Codable, Sendable { let term: String, exactCaseInsensitivePresent: Bool, whitespaceInsensitivePresent: Bool }
struct LaneMetrics: Codable, Sendable {
    let voiceName: String, voiceLocale: String
    let normalizedCharacterSimilarity: Double
    let normalization: String
    let termChecks: [TermCheck]
    let expectedPunctuation: [String], observedPunctuation: [String]
}
struct LaneResult: Codable, Sendable {
    let locale: String, outcome: String, recognized: String
    let tokens: [TimedSpeechToken]
    let contextualStrings: [String], addsPunctuation: Bool?
    let elapsedSeconds: Double
    let error: String?
    let metrics: LaneMetrics?
}
struct ConditionResult: Codable, Sendable {
    let audioId: String, condition: String
    let lanes: [LaneResult], windows: [BilingualWindow]
}
struct ExperimentReport: Codable, Sendable {
    let schemaVersion: Int, input: ExperimentInput, authorizationRaw: Int
    let outcome: String, conditions: [ConditionResult], errors: [String], notes: [String]
}
enum Metrics {
    static func normalized(_ s: String) -> [Unicode.Scalar] {
        s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
    }
    static func whitespaceFree(_ s: String) -> String { String(s.lowercased().unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }) }
    static func punctuation(_ s: String) -> [String] { s.unicodeScalars.filter { CharacterSet.punctuationCharacters.contains($0) }.map(String.init) }
    static func calculate(audio: AudioCase, text: String) -> LaneMetrics {
        let a = normalized(audio.groundtruth), b = normalized(text)
        var previous = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var row = [i + 1]
            for (j, y) in b.enumerated() { row.append(min(row[j] + 1, previous[j + 1] + 1, previous[j] + (x == y ? 0 : 1))) }
            previous = row
        }
        let similarity = 1 - Double(previous[b.count]) / Double(max(1, max(a.count, b.count)))
        return LaneMetrics(voiceName: audio.voiceName, voiceLocale: audio.voiceLocale, normalizedCharacterSimilarity: similarity,
            normalization: "Lowercase, retain Unicode alphanumeric scalars; 1-Levenshtein/max(reference length,hypothesis length). Not accuracy/CER; punctuation reported separately.",
            termChecks: audio.expectedTerms.map { TermCheck(term: $0, exactCaseInsensitivePresent: text.lowercased().contains($0.lowercased()), whitespaceInsensitivePresent: whitespaceFree(text).contains(whitespaceFree($0))) },
            expectedPunctuation: punctuation(audio.groundtruth), observedPunctuation: punctuation(text))
    }
}
@MainActor final class LaneTask {
    private var task: SFSpeechRecognitionTask?
    private var continuation: CheckedContinuation<LaneResult, Never>?
    private var deadline: Task<Void, Never>?
    private var recognizer: SFSpeechRecognizer?
    private var latestText = "", latestTokens: [TimedSpeechToken] = []
    private let locale: String, condition: Condition, audioCase: AudioCase
    private var started = ProcessInfo.processInfo.systemUptime
    init(locale: String, condition: Condition, audio: AudioCase) { self.locale = locale; self.condition = condition; audioCase = audio }
    func run(timeoutSeconds: Double) async -> LaneResult {
        started = ProcessInfo.processInfo.systemUptime
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { return result("authorization_missing", error: "NO_AUTHORIZATION_REQUESTED") }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)) else { return result("unsupported_locale", error: nil) }
        guard recognizer.supportsOnDeviceRecognition else { return result("on_device_unavailable", error: nil) }
        guard recognizer.isAvailable else { return result("recognizer_unavailable", error: nil) }
        self.recognizer = recognizer
        let request = SFSpeechURLRecognitionRequest(url: URL(fileURLWithPath: audioCase.audioPath))
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        if !condition.contextualStrings.isEmpty { request.contextualStrings = condition.contextualStrings }
        if let punctuation = condition.addsPunctuation { request.addsPunctuation = punctuation }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let tokens = result?.bestTranscription.segments.map {
                    TimedSpeechToken(text: $0.substring, startSeconds: $0.timestamp, durationSeconds: $0.duration, confidence: $0.confidence)
                }
                let final = result?.isFinal ?? false
                let code = error.map { let e = $0 as NSError; return "\(e.domain):\(e.code)" }
                Task { @MainActor [weak self] in
                    guard let self, self.continuation != nil else { return }
                    if let text { self.latestText = text }
                    if let tokens { self.latestTokens = tokens }
                    if final { self.complete("final", error: nil) }
                    else if let code { self.complete("error", error: code) }
                }
            }
            self.deadline = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000)) } catch { return }
                self?.complete("timeout", error: "FINAL_DEADLINE_EXCEEDED")
            }
        }
    }
    private func result(_ outcome: String, error: String?) -> LaneResult {
        LaneResult(locale: locale, outcome: outcome, recognized: latestText, tokens: latestTokens, contextualStrings: condition.contextualStrings,
                   addsPunctuation: condition.addsPunctuation, elapsedSeconds: ProcessInfo.processInfo.systemUptime - started,
                   error: error, metrics: outcome == "final" ? Metrics.calculate(audio: audioCase, text: latestText) : nil)
    }
    private func complete(_ outcome: String, error: String?) {
        guard let c = continuation else { return }
        let observation = result(outcome, error: error)
        continuation = nil; deadline?.cancel(); deadline = nil; task?.cancel(); task = nil; recognizer = nil
        c.resume(returning: observation)
    }
}

@main struct BilingualSpeechExperiment {
    static func selfCheck() throws {
        let zh = [TimedSpeechToken(text: "合成", startSeconds: 0.5, durationSeconds: 1, confidence: 0.1)]
        let en = [TimedSpeechToken(text: "ExampleTerm", startSeconds: 1, durationSeconds: 0.5, confidence: 0.99)]
        let windows = try BilingualTimeAlignment.windows(chinese: zh, english: en, audioDurationSeconds: 3, windowSeconds: 1, maxWindows: 3)
        guard windows.count == 3, windows[0].englishCandidates.isEmpty, windows[1].englishCandidates == en,
              windows[1].chineseCandidates == zh, windows[1].requiresHumanReview,
              windows[1].decision == "bilingual_candidates_unresolved", windows[2].decision == "no_hypothesis" else { throw CoreError.invalid("ALIGNMENT_SELF_CHECK") }
        do {
            _ = try BilingualTimeAlignment.windows(chinese: zh, english: en, audioDurationSeconds: 3, windowSeconds: 1, maxWindows: 2)
            throw CoreError.invalid("EXPECTED_WINDOW_LIMIT")
        } catch CoreError.invalid("WINDOW_LIMIT_OR_DURATION") { }
        let audio = AudioCase(id: "check", audioPath: "/synthetic", voiceName: "TEST_ONLY_NOT_A_VOICE_MEASUREMENT", voiceLocale: "none", groundtruth: "ExampleTerm，示例术语。", expectedTerms: ["ExampleTerm", "示例术语"])
        let metrics = Metrics.calculate(audio: audio, text: "Exam pleTerm，示例术语。")
        guard !metrics.termChecks[0].exactCaseInsensitivePresent, metrics.termChecks[0].whitespaceInsensitivePresent,
              metrics.observedPunctuation == ["，", "。"], metrics.normalizedCharacterSimilarity == 1 else { throw CoreError.invalid("METRICS_SELF_CHECK") }
        print("PASS alignment half-open windows, overlap preservation, no confidence selection, finite limit, term exact/whitespace policy, punctuation and metric normalization; recognition_tasks=0")
    }
    @MainActor static func main() async {
        do {
            if CommandLine.arguments == [CommandLine.arguments[0], "--authorize-once"] {
                // Explicit Chief-triggered setup only: no input files, recognition tasks, retry or timer.
                let raw = await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
                    SFSpeechRecognizer.requestAuthorization { status in continuation.resume(returning: status.rawValue) }
                }
                print("authorization_status_raw=\(raw)")
                exit(raw == SFSpeechRecognizerAuthorizationStatus.authorized.rawValue ? 0 : 77)
            }
            if CommandLine.arguments == [CommandLine.arguments[0], "--self-check"] { try selfCheck(); return }
            guard CommandLine.arguments.count == 4, ["--authorized-synthetic", "--validate-input"].contains(CommandLine.arguments[1]) else {
                fputs("Usage: --authorized-synthetic|--validate-input /absolute/input.json /absolute/new-report.json; or --self-check\n", stderr); exit(64)
            }
            let mode = CommandLine.arguments[1], manifest = CommandLine.arguments[2], reportPath = CommandLine.arguments[3]
            guard manifest.hasPrefix("/"), reportPath.hasPrefix("/"), !FileManager.default.fileExists(atPath: reportPath) else { throw CoreError.invalid("ABSOLUTE_NEW_PATH_REQUIRED") }
            let input = try JSONDecoder().decode(ExperimentInput.self, from: Data(contentsOf: URL(fileURLWithPath: manifest)))
            try input.validate()
            // Validate all identical audio origins before starting any tasks. No capture or asset preparation.
            var durations: [String: Double] = [:]
            for audio in input.audios {
                let file = try AVAudioFile(forReading: URL(fileURLWithPath: audio.audioPath))
                let duration = Double(file.length) / file.processingFormat.sampleRate
                _ = try BilingualTimeAlignment.windows(chinese: [], english: [], audioDurationSeconds: duration, windowSeconds: input.windowSeconds, maxWindows: input.maxWindows)
                durations[audio.id] = duration
            }
            let auth = mode == "--validate-input" ? -1 : SFSpeechRecognizer.authorizationStatus().rawValue
            var conditions: [ConditionResult] = [], errors: [String] = []
            var outcome = mode == "--validate-input" ? "input_validated_no_recognition" : "blocked_authorization"
            if mode == "--authorized-synthetic" && SFSpeechRecognizer.authorizationStatus() == .authorized {
                for audio in input.audios {
                    for condition in input.conditions {
                        // Each locale has a separate recognizer and task, same file offset origin.
                        let tasks = input.locales.map { LaneTask(locale: $0, condition: condition, audio: audio) }
                        let unsorted = await withTaskGroup(of: LaneResult.self, returning: [LaneResult].self) { group in
                            for task in tasks { group.addTask { await task.run(timeoutSeconds: input.timeoutSeconds) } }
                            var results: [LaneResult] = []; for await result in group { results.append(result) }; return results
                        }
                        let lanes = unsorted.sorted { input.locales.firstIndex(of: $0.locale)! < input.locales.firstIndex(of: $1.locale)! }
                        let windows = try BilingualTimeAlignment.windows(chinese: lanes.first(where: { $0.locale.hasPrefix("zh") })?.tokens ?? [],
                            english: lanes.first(where: { $0.locale.hasPrefix("en") })?.tokens ?? [], audioDurationSeconds: durations[audio.id]!, windowSeconds: input.windowSeconds, maxWindows: input.maxWindows)
                        conditions.append(ConditionResult(audioId: audio.id, condition: condition.id, lanes: lanes, windows: windows))
                        // Persist after EVERY condition, so a killed LaunchServices process has partial evidence.
                        try write(input: input, auth: auth, outcome: "in_progress", conditions: conditions, errors: errors, path: reportPath)
                    }
                }
                outcome = conditions.allSatisfy({ $0.lanes.allSatisfy({ $0.outcome == "final" }) }) ? "completed_unresolved_candidates" : "partial_or_failed"
            } else if mode != "--validate-input" { errors.append("No existing authorization for this executable identity; no authorization request, no recognition tasks.") }
            try write(input: input, auth: auth, outcome: outcome, conditions: conditions, errors: errors, path: reportPath)
            print("report=\(reportPath) outcome=\(outcome) voices=\(input.audios.map(\.voiceName)) auth=\(auth)")
            exit(["completed_unresolved_candidates", "input_validated_no_recognition"].contains(outcome) ? 0 : (outcome == "blocked_authorization" ? 77 : 2))
        } catch { fputs("BilingualSpeechExperiment: \(error)\n", stderr); exit(2) }
    }
    static func write(input: ExperimentInput, auth: Int, outcome: String, conditions: [ConditionResult], errors: [String], path: String) throws {
        let report = ExperimentReport(schemaVersion: 1, input: input, authorizationRaw: auth, outcome: outcome, conditions: conditions, errors: errors,
            notes: ["Input records supplied voice provenance and reference. Character similarity is not accuracy; no metrics on incomplete/error lanes.",
                    "All conditions/locales use the same audio bytes. contextualStrings improves likelihood only; addsPunctuation tested independently and jointly.",
                    "SFTranscriptionSegment timing is relative to the shared file origin. Confidence is not cross-locale language detection.",
                    "Windows retain overlapping raw tokens; cross-window duplicate candidates must not be concatenated into a merged transcript.",
                    "macOS14.2 legacy APIs only; actual parallel resource availability still requires runtime measurement.",
                    "Experiment mode never requests permission. The separate explicit --authorize-once setup mode is Chief-triggered only and performs no audio/task/data operations.",
                    "No automatic lane selection, capture, upload, network fallback or download.",
                    "customizedLanguageModel is not configured: no authorized prepared local LM artifact provided; no LM training/asset preparation in this experiment."])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: URL(fileURLWithPath: path), options: [.atomic])
    }
}
