import Foundation
import Translation
import NaturalLanguage

public enum TranslationLanguages {
    /// Qwen returns names such as "English"; Apple expects language identifiers.
    public static func code(_ raw: String, text: String = "") -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let names = ["english": "en", "chinese": "zh-Hans", "mandarin": "zh-Hans",
                     "japanese": "ja", "korean": "ko", "french": "fr", "german": "de",
                     "spanish": "es", "italian": "it", "portuguese": "pt",
                     "russian": "ru", "arabic": "ar", "hindi": "hi"]
        if let code = names[value] { return code }
        if value.range(of: #"^[a-z]{2,3}(-[a-z0-9]{2,8})*$"#, options: .regularExpression) != nil {
            return value
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue ?? value
    }
    public static func sameLanguage(_ source: String, _ target: String, text: String = "") -> Bool {
        let a = Locale.Language(identifier: code(source, text: text)).languageCode
        let b = Locale.Language(identifier: code(target)).languageCode
        return a != nil && a == b
    }
}

public struct TranslationJob: Equatable, Sendable {
    public let requestID: String
    public let segmentID: String
    public let sourceRevision: Int
    public let sourceText: String
    public let sourceLanguage: String
    public let targetLanguage: String
    public init(requestID: String, segmentID: String, sourceRevision: Int, sourceText: String, sourceLanguage: String, targetLanguage: String) {
        self.requestID = requestID; self.segmentID = segmentID; self.sourceRevision = sourceRevision
        self.sourceText = sourceText; self.sourceLanguage = sourceLanguage; self.targetLanguage = targetLanguage
    }
}

public struct TranslationOutput: Equatable, Sendable {
    public let job: TranslationJob
    public let translatedText: String
    public let engine: String
    public init(job: TranslationJob, translatedText: String, engine: String) {
        self.job = job; self.translatedText = translatedText; self.engine = engine
    }
}

public enum LocalTranslationError: Error, LocalizedError, Equatable {
    case invalidJob, unsupportedOS, unsupportedLanguagePair, languageAssetsNotInstalled, unknownReadiness, emptyResult
    public var errorDescription: String? {
        switch self {
        case .invalidJob: return "翻译请求缺少片段、版本、文本或语言。"
        case .unsupportedOS: return "此独立翻译适配器需要 macOS 26 或更新版本。"
        case .unsupportedLanguagePair: return "系统不支持当前翻译语言对。"
        case .languageAssetsNotInstalled: return "翻译语言资源尚未安装。本应用不会自动下载或回退云端。"
        case .unknownReadiness: return "无法确认翻译资源状态，已停止翻译。"
        case .emptyResult: return "引擎返回空译文，原文保留。"
        }
    }
}

/// System engine only; publishing sequence/revisions belongs to the SpeechCore coordinator.
/// Never writes files, downloads models, requests microphone access or chooses a cloud fallback.
@MainActor
public final class InstalledSystemTranslator {
    public init() {}
    public func translate(_ job: TranslationJob) async throws -> TranslationOutput {
        guard !job.requestID.isEmpty, !job.segmentID.isEmpty, job.sourceRevision > 0,
              !job.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !job.sourceLanguage.isEmpty, !job.targetLanguage.isEmpty else { throw LocalTranslationError.invalidJob }
        guard #available(macOS 26.0, *) else { throw LocalTranslationError.unsupportedOS }
        try Task.checkCancellation()
        if TranslationLanguages.sameLanguage(job.sourceLanguage, job.targetLanguage, text: job.sourceText) {
            return TranslationOutput(job: job, translatedText: job.sourceText, engine: "source-already-in-target-language")
        }
        let source = Locale.Language(identifier: TranslationLanguages.code(job.sourceLanguage, text: job.sourceText))
        let target = Locale.Language(identifier: TranslationLanguages.code(job.targetLanguage))
        let availability = LanguageAvailability()
        switch await availability.status(from: source, to: target) {
        case .installed: break
        case .supported: throw LocalTranslationError.languageAssetsNotInstalled
        case .unsupported: throw LocalTranslationError.unsupportedLanguagePair
        @unknown default: throw LocalTranslationError.unknownReadiness
        }
        try Task.checkCancellation()
        let session = TranslationSession(installedSource: source, target: target)
        let response = try await session.translate(job.sourceText)
        try Task.checkCancellation()
        guard !response.targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LocalTranslationError.emptyResult }
        return TranslationOutput(job: job, translatedText: response.targetText, engine: "apple-system-installed")
    }
}
