import Foundation
import ClientRuntime
import MeetingCopilotCore
import APIIntelligence
import LocalASRProviders
import LocalTranslationEngine
import DesktopSessionController

struct Failure: Error { let text: String }
func check(_ value: @autoclosure () -> Bool, _ text: String) throws { if !value() { throw Failure(text: text) } }
final class Credentials: BackendCredentialStore {
    var entries: [String: String] = [:]
    func save(_ secret: String, reference: String) throws { entries[reference] = secret }
    func read(reference: String) throws -> String? { entries[reference] }
    func remove(reference: String) throws { entries.removeValue(forKey: reference) }
}
actor MockTransport: APIHTTPTransport {
    var requests: [URLRequest] = []
    var status = 200
    func setStatus(_ value: Int) { status = value }
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> APIHTTPResponse {
        requests.append(request)
        let body = request.url!.path.hasSuffix("audio/transcriptions") ? #"{"text":"Hello test"}"# : #"{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"你好，测试。"}}]}"#
        return APIHTTPResponse(statusCode: status, body: Data(body.utf8))
    }
}
@main struct Checks {
    @MainActor static func main() async {
        do {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("network-services-" + UUID().uuidString)
            let creds = Credentials(), transport = MockTransport()
            let services = SpeechServiceSettings(directory: dir, credentials: creds)
            try check(services.persisted.asr.location == .local && services.persisted.translation.location == .local, "legacy defaults changed")
            services.draft.asr.location = .network; services.draft.asr.baseURL = "http://192.168.1.10:8000/v1"; services.draft.asr.modelID = "company-asr"
            services.draft.translation.location = .network; services.draft.translation.baseURL = "https://translation.example/v1"; services.draft.translation.modelID = "personal-translation"
            services.asrSecret = "ASR_TEST_SECRET"; services.translationSecret = "TEXT_TEST_SECRET"
            try await services.test(transport: transport)
            try check(services.testMatches, "successful independent tests not bound")
            let requests = await transport.requests
            try check(requests.count == 2 && requests[0].url?.absoluteString == "http://192.168.1.10:8000/v1/audio/transcriptions", "wrong LAN audio endpoint")
            try check(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer ASR_TEST_SECRET" && requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer TEXT_TEST_SECRET", "keys not independent")
            let body = requests[0].httpBody!
            try check(body.range(of: Data("filename=\"segment.wav\"".utf8)) != nil && body.range(of: Data("RIFF".utf8)) != nil, "audio multipart missing WAV")
            try check(String(data: requests[1].httpBody!, encoding: .utf8)!.contains("Hello."), "test sends arbitrary user data")
            services.draft.translation.modelID = "changed"
            try check(!services.testMatches, "edits not invalidating tests")
            services.draft.translation.modelID = "personal-translation"
            let candidate = try services.prepareSave()
            let store = SettingsStorage(directory: dir)
            try store.saveAll(asr: ASRSelection(), backend: .init(), speechServices: candidate.0)
            services.acceptSave(candidate.0)
            let json = try String(contentsOf: store.fileURL, encoding: .utf8)
            try check(!json.contains("ASR_TEST_SECRET") && !json.contains("TEXT_TEST_SECRET"), "secret leaked into settings")
            let reopened = SpeechServiceSettings(directory: dir, credentials: creds)
            try check(reopened.persisted == services.persisted && !reopened.contentSendingEnabled, "reopen config or consent mismatch")
            let job = TranslationJob(requestID: "r", segmentID: "s", sourceRevision: 1, sourceText: "Hello test", sourceLanguage: "en-US", targetLanguage: "zh-Hans")
            do { _ = try await reopened.translate(job, transport: transport); throw Failure(text: "unauthorised content sent") } catch is NetworkModelError {}
            let deniedCount = await transport.requests.count
            try check(deniedCount == 2, "request sent without consent")
            reopened.contentSendingEnabled = true
            let translation = try await reopened.translate(job, transport: transport)
            try check(translation.translatedText == "你好，测试。", "translation not returned")
            let backend = try NetworkASRBackend(configuration: reopened.persisted.asr, key: reopened.key(reopened.persisted.asr), locale: "zh-CN", transport: transport)
            let model = ClientModel(directory: dir, configURL: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("text-mode-config.json"), translationOperation: { job in
                let disk = try ArchiveStore(directory: dir).load()
                try check(disk.sessions.first?.segments.first?.current?.text == "Hello test", "translation before durable original")
                return try await reopened.translate(job, transport: transport)
            })
            model.add(demo: false); model.translateFinal = true
            let controller = QwenSegmentController(backend: backend)
            _ = try controller.adoptPreparedConfiguration(backend.captureConfiguration)
            controller.commitFinal = { final in try await model.commitQwenFinal(final, sourceURL: dir.appendingPathComponent("test.wav")) }
            let file = dir.appendingPathComponent("test.wav"); try SpeechServiceSettings.silentWAV().write(to: file)
            try await controller.transcribeFile(file, binding: .init(sessionID: model.selection!, channelID: "file", streamID: "network-file", source: .file, sourceURL: file))
            try await model.finishQwenAttempts(lifecycle: "completed", failure: nil)
            for _ in 0..<100 where model.selected?.segments.first?.currentTranslations.isEmpty == true { try await Task.sleep(nanoseconds: 10_000_000) }
            try check(model.selected?.segments.first?.currentTranslations.count == 1, "durable network final not translated")
            try check(model.selected?.captureAttempts.first?.engineVersion?.hasPrefix("network-audio") == true && model.selected?.captureAttempts.first?.mode == "network-api-segmented", "network mislabeled local")
            let disk = try ArchiveStore(directory: dir).load()
            try check(disk == model.archive && disk.sessions.first?.captureAttempts.first?.lifecycle == "completed", "network archive reopen mismatch")
            await transport.setStatus(401)
            do { _ = try await reopened.translate(job, transport: transport); throw Failure(text: "401 accepted") } catch is NetworkModelError {}
            backend.cancel()
            do { _ = try await backend.transcribe(fileURL: file, context: nil); throw Failure(text: "cancel accepted") } catch is CancellationError {}
            let before = await transport.requests.count
            reopened.draft = reopened.persisted; reopened.draft.asr.noAuthentication = true; reopened.draft.translation.location = .local
            await transport.setStatus(200); try await reopened.test(transport: transport)
            let anonymous = await transport.requests
            try check(anonymous.count == before + 1 && anonymous.last!.value(forHTTPHeaderField: "Authorization") == nil, "local translation or no-key mode sent inappropriate request")
            for bad in ["ftp://host/v1", "http://secret:password@host/v1", "https://host/v1?key=hidden"] {
                var config = reopened.draft.asr; config.baseURL = bad
                do { _ = try config.endpoint("audio/transcriptions"); throw Failure(text: "invalid URL accepted") } catch is NetworkModelError {}
            }
            let rollback = try reopened.prepareSave(); reopened.rollback(rollback.1)
            if ProcessInfo.processInfo.environment["VERIFY_LOCAL_MODELS"] == "1" {
                let local = ASRSettingsModel(directory: dir.appendingPathComponent("actual-local-model"))
                guard await local.loadActive() else { throw Failure(text: "new-folder real Qwen load failed") }
                try check(local.activeSelection?.modelPath?.contains("Meeting Copilot/运行依赖") == true, "local load used old directory")
                local.unload()
                let localText = try await InstalledSystemTranslator().translate(job)
                try check(!localText.translatedText.isEmpty, "actual local translation empty")
                print("PASS actual copied-folder Qwen load + installed local translation fixed sentence")
            }
            if let base = ProcessInfo.processInfo.environment["NETWORK_TEST_URL"] {
                var config = NetworkModelConfiguration(); config.location = .network; config.baseURL = base; config.modelID = "loopback-model"; config.noAuthentication = true
                let real = NetworkModelClient()
                let asrText = try await real.transcribe(audio: SpeechServiceSettings.silentWAV(), configuration: config, key: "", language: "en", context: nil)
                let translated = try await real.translate(text: "Hello test", source: "en", target: "zh-Hans", configuration: config, key: "")
                try check(asrText == "Hello test" && translated == "你好，测试。", "real HTTP roundtrip failed")
                config.baseURL = base.replacingOccurrences(of: "/v1", with: "/redirect/v1")
                do { _ = try await real.translate(text: "test", source: "en", target: "zh", configuration: config, key: ""); throw Failure(text: "redirect followed") } catch is NetworkModelError {}
                config.baseURL = base.replacingOccurrences(of: "/v1", with: "/invalid/v1")
                do { _ = try await real.transcribe(audio: SpeechServiceSettings.silentWAV(), configuration: config, key: "", language: "en", context: nil); throw Failure(text: "invalid audio response accepted") } catch is NetworkModelError {}
                let clientDir = dir.appendingPathComponent("production-client-loopback")
                var serviceConfig = SpeechServiceConfiguration()
                var endpointConfig = NetworkModelConfiguration(); endpointConfig.location = .network; endpointConfig.baseURL = base; endpointConfig.modelID = "loopback-production"; endpointConfig.noAuthentication = true; endpointConfig.recognitionLanguage = "auto"
                serviceConfig.asr = endpointConfig; serviceConfig.translation = endpointConfig
                try SettingsStorage(directory: clientDir).saveAll(asr: .init(), backend: .init(), speechServices: serviceConfig)
                let settings = ASRSettingsModel(directory: clientDir)
                let fullClient = ClientModel(directory: clientDir, configURL: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("text-mode-config.json"))
                fullClient.asrSettings = settings; fullClient.add(demo: false); fullClient.translateFinal = true
                fullClient.importQwenFiles([file], settings: settings)
                try check(!fullClient.fileBatch.busy && !fullClient.captureActive, "import opened network before consent")
                settings.services.contentSendingEnabled = true
                fullClient.importQwenFiles([file], settings: settings)
                for _ in 0..<500 where fullClient.captureActive || fullClient.fileBatch.busy || fullClient.selected?.segments.first?.currentTranslations.isEmpty != false { try await Task.sleep(nanoseconds: 10_000_000) }
                try check(!fullClient.captureActive && fullClient.captureStatus.contains("已结束") && fullClient.selected?.segments.first?.currentTranslations.count == 1, "production client network import/translation/terminal failed")
                print("PASS real production ClientModel network file import + automatic translation + durable terminal + consent guard")
                print("PASS real loopback HTTP audio/chat + redirect refused + incompatible response refused")
            }
            print("PASS NetworkServiceChecks: separate LAN/online endpoints + keys, multipart WAV, fixed probes, consent, no plaintext secrets, persisted reopen, durable network ASR→translation→terminal, failures/cancel, mixed local/no-key, invalid URLs")
        } catch { print("FAIL NetworkServiceChecks: \(error)"); exit(1) }
    }
}
