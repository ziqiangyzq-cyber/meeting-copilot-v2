import Foundation
import MeetingCopilotCore
import LocalTranslationEngine

@main struct ClientIntegrationChecks {
    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 4 else { print("Usage: ClientIntegrationChecks CONFIG_JSON NEW_STORE_DIR --synthetic|--translate"); exit(64) }
        let config = try TextModeConfig.load(URL(fileURLWithPath: args[1]))
        let dir = URL(fileURLWithPath: args[2], isDirectory: true)
        guard !FileManager.default.fileExists(atPath: dir.path) else { throw CocoaError(.fileWriteFileExists) }
        let realEngine = args[3] == "--translate"
        var session = LocalSession(title: "Client integration · synthetic source", tags: ["QA"])
        var coordinator = try TextSessionCoordinator(session: session, config: config)
        let source = try coordinator.submit(text: "Do not cancel the contract. The budget is USD 2,450.75.")
        let request = try coordinator.request(segmentID: source.segmentId!, targetLanguage: "zh-Hans")
        let oldOutput: String
        if realEngine {
            let job = TranslationJob(requestID: request.id, segmentID: request.segmentId, sourceRevision: request.sourceRevision, sourceText: request.sourceText, sourceLanguage: "en", targetLanguage: "zh-Hans")
            oldOutput = try await InstalledSystemTranslator().translate(job).translatedText
        } else { oldOutput = "合成测试译文，不是引擎结果" }
        guard let published = try coordinator.accept(request, translatedText: oldOutput), published.sourceRevision == 1, published.revision == 1 else { throw failure("initial binding") }
        coordinator.project(into: &session)
        let correction = try coordinator.submit(text: "Do not cancel the contract. The budget is USD 3,500.", segmentID: source.segmentId!)
        coordinator.project(into: &session)
        guard session.segments[0].currentTranslations.isEmpty, session.segments[0].translations.count == 1 else { throw failure("immediate stale") }
        guard try coordinator.accept(request, translatedText: oldOutput) == nil else { throw failure("late old response") }
        let fresh = try coordinator.request(segmentID: correction.segmentId!, targetLanguage: "zh-Hans")
        let newOutput: String
        if realEngine {
            let job = TranslationJob(requestID: fresh.id, segmentID: fresh.segmentId, sourceRevision: fresh.sourceRevision, sourceText: fresh.sourceText, sourceLanguage: "en", targetLanguage: "zh-Hans")
            newOutput = try await InstalledSystemTranslator().translate(job).translatedText
        } else { newOutput = "新合成测试译文" }
        guard let current = try coordinator.accept(fresh, translatedText: newOutput), current.sourceRevision == 2, current.revision == 2 else { throw failure("fresh binding") }
        coordinator.project(into: &session)
        session.editNotes("合成笔记：😀 USD 3,500；原译文版本分别保存。")
        var archive = LocalArchive(); archive.sessions = [session]
        var store: ArchiveStore? = ArchiveStore(directory: dir)
        archive = try store!.save(archive); store = nil
        let reloaded = try ArchiveStore(directory: dir).load()
        guard archive == reloaded else { throw failure("archive reopen") }
        let reconstructed = try TextSessionCoordinator(session: reloaded.sessions[0], config: config)
        guard reconstructed.core.lastAppliedSequence == coordinator.core.lastAppliedSequence,
              reconstructed.core.currentTranslation(fresh.translationId)?.translatedText == newOutput,
              reloaded.sessions[0].segments[0].currentTranslations.count == 1 else { throw failure("journal replay") }
        try NoteOperations.export(session, format: .json, to: dir.appendingPathComponent("session.json"))
        try NoteOperations.export(session, format: .markdown, to: dir.appendingPathComponent("session.md"))
        let report: [String: Any] = ["status": "passed", "engine": realEngine ? "apple-system-installed" : "synthetic-no-engine", "source_text": fresh.sourceText, "source_revision": fresh.sourceRevision, "translation_revision": current.revision!, "translated_text": newOutput, "stale_response_discarded": true, "old_translation_retained": true, "journal_reopened": true, "store_path": dir.path, "capture": "not-started", "scope": "Actual client coordinator + actual SpeechCore + actual ArchiveStore; synthetic typed source"]
        let bytes = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try bytes.write(to: dir.appendingPathComponent("report.json"), options: .withoutOverwriting)
        print(String(decoding: bytes, as: UTF8.self))
    }
    static func failure(_ text: String) -> NSError { NSError(domain: "ClientIntegration", code: 2, userInfo: [NSLocalizedDescriptionKey: text]) }
}
