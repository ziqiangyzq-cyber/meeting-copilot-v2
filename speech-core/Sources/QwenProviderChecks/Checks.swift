import Foundation
import Darwin
import LocalASRProviders
import AppleOfflineSpeech

final class FakeWorker: QwenWorkerTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var loadContinuation: CheckedContinuation<QwenLoadAcknowledgement, any Error>?
    private var transcriptContinuation: CheckedContinuation<QwenTranscriptAcknowledgement, any Error>?
    private var waiters: [(String, CheckedContinuation<Void, Never>)] = []
    private var exitHandler: (@Sendable (Int32) -> Void)?
    private(set) var stops = 0
    func setExitHandler(_ handler: @escaping @Sendable (Int32) -> Void) { lock.withLock { exitHandler = handler } }
    func stop() { lock.withLock { stops += 1 } } // Deliberately delivers late acks for generation checks.
    func load(runtime: QwenRuntimeConfiguration, modelPath: String, context: String?) async throws -> QwenLoadAcknowledgement {
        try await withCheckedThrowingContinuation { c in
            let ready = lock.withLock { () -> [CheckedContinuation<Void,Never>] in
                loadContinuation = c; let ready = waiters.filter { $0.0 == "load" }.map { $0.1 }; waiters.removeAll { $0.0 == "load" }; return ready
            }
            ready.forEach { $0.resume() }
        }
    }
    func transcribe(fileURL: URL, requestID: String, context: String?, expectedAudioSHA256: String?) async throws -> QwenTranscriptAcknowledgement {
        try await withCheckedThrowingContinuation { c in
            let ready = lock.withLock { () -> [CheckedContinuation<Void,Never>] in
                transcriptContinuation = c; let ready = waiters.filter { $0.0 == "transcribe" }.map { $0.1 }; waiters.removeAll { $0.0 == "transcribe" }; return ready
            }
            ready.forEach { $0.resume() }
        }
    }
    func wait(_ kind: String) async {
        await withCheckedContinuation { c in
            let pending = lock.withLock { () -> Bool in
                if (kind == "load" ? loadContinuation != nil : transcriptContinuation != nil) { return true }
                waiters.append((kind,c)); return false
            }
            if pending { c.resume() }
        }
    }
    func completeLoad(_ result: Result<QwenLoadAcknowledgement,any Error>) {
        let c = lock.withLock { let c = loadContinuation; loadContinuation = nil; return c }; c?.resume(with: result)
    }
    func completeTranscript(_ result: Result<QwenTranscriptAcknowledgement,any Error>) {
        let c = lock.withLock { let c = transcriptContinuation; transcriptContinuation = nil; return c }; c?.resume(with: result)
    }
    func crash() { lock.withLock { exitHandler }?(9) }
}
struct CheckFailure: Error { let name: String }
@main struct QwenChecks {
    static let modelVersion = "mlx-community/Qwen3-ASR-1.7B-bf16@e1f6c266914abc5a46e8756e02580f834a6cf8a7"
    static let fakeEngine = "fake-only/qwen-test"
    static let sha = String(repeating: "a", count: 64)
    static let ack = QwenLoadAcknowledgement(engineVersion: fakeEngine, modelVersion: modelVersion, loadSeconds: 0.1, workerPID: 123)
    static func transcript(_ text: String = "合成示例", eos: Bool = true, audioSHA: String = sha, noSpeech: Bool? = nil) -> QwenTranscriptAcknowledgement {
        .init(text: text, language: "Chinese", audioSHA256: audioSHA, engineVersion: fakeEngine, modelVersion: modelVersion,
              duration: 2, elapsedSeconds: 0.1, workerPID: 123, generations: [.init(tokenIDs: [12,eos ? 151645 : 34], endedWithEOS: eos, rawDecoded: text)], noSpeech: noSpeech)
    }
    @MainActor static func main() async {
        let root = CommandLine.arguments.dropFirst().first(where: { $0.hasPrefix("/") }).map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).deletingLastPathComponent().appendingPathComponent("qwen-asr-validation")
        let modelPath = root.appendingPathComponent("model").path
        let config = ASRConfiguration(providerID: .qwen3ASR, locale: .simplifiedChinese, modelPath: modelPath)
        var passes = 0
        func check(_ ok: Bool, _ name: String) throws { guard ok else { throw CheckFailure(name: name) }; passes += 1; print("PASS \(name)") }
        func expectFailure<T>(_ task: Task<T, any Error>) async throws {
            do { _ = try await task.value; throw CheckFailure(name: "expected task failure") }
            catch is CheckFailure { throw CheckFailure(name: "unexpected successful task") }
            catch { print("EXPECTED_ERROR \(error)") }
        }
        func prepared(_ fake: FakeWorker) async throws -> LocalASRProvider {
            let p = LocalASRProvider(providerID: .qwen3ASR, qwenFactory: { fake })
            let task = Task { @MainActor in try await p.loadAsync(config) }
            await fake.wait("load"); fake.completeLoad(.success(ack)); _ = try await task.value; return p
        }
        do {
            try check(LocalASRRegistry.catalog[1].implemented, "Qwen catalog implemented, not readiness claim")
            let p = LocalASRRegistry.make(.qwen3ASR)
            try check(p.inspect(config).state == .readyToPrepare && p.activeEngine == nil, "inspect paths not weights loaded")
            do { _ = try p.load(config); throw CheckFailure(name: "sync load accepted") }
            catch let e as ASRProviderError { try check(e == .qwen("ASYNC_LOAD_REQUIRED"), "synchronous Qwen load rejected") }
            try check(p.inspect(.init(providerID: .qwen3ASR, locale: .englishUS, modelPath: "relative")).state == .invalidConfiguration, "relative model path rejected")
            try check(p.inspect(.init(providerID: .qwen3ASR, locale: .englishUS, modelPath: "/missing/model")).state == .unavailable, "missing runtime unavailable, never Apple")
            try check(p.inspect(.init(providerID: .qwen3ASR, locale: .englishUS, modelPath: modelPath, terminologyContext: String(repeating: "墙", count: 2000))).state == .invalidConfiguration, "UTF8 context limit rejects before load")
            let delayed = FakeWorker(), loading = LocalASRProvider(providerID: .qwen3ASR, qwenFactory: { delayed })
            let first = Task { @MainActor in try await loading.loadAsync(config) }
            await delayed.wait("load")
            try check(loading.state == .loading && loading.activeEngine == nil, "prepared waits real load acknowledgement")
            do { _ = try await loading.loadAsync(config); throw CheckFailure(name: "parallel load accepted") }
            catch let e as ASRProviderError { try check(e == .activeRecognition, "concurrent load rejected without queue") }
            loading.cancel(); delayed.completeLoad(.success(ack)); try await expectFailure(first)
            try check(loading.state == .cancelled && loading.activeEngine == nil && delayed.stops > 0, "cancel invalidates late load acknowledgement")
            let fake = FakeWorker(), q = try await prepared(fake)
            try check(q.state == .prepared && q.activeEngine?.locale == "auto" && q.activeEngine?.modelVersion == modelVersion && q.qwenLoadAcknowledgement?.workerPID == 123, "load identity and PID bound to acknowledgement")
            let oldGeneration = q.activeEngine!.generation
            let task = Task { @MainActor in try await q.transcribeSegment(fileURL: root.appendingPathComponent("unused.wav"), expectedAudioSHA256: sha) }
            await fake.wait("transcribe")
            do { _ = try await q.transcribeSegment(fileURL: root.appendingPathComponent("unused2.wav")); throw CheckFailure(name: "parallel transcript accepted") }
            catch let e as ASRProviderError { try check(e == .activeRecognition, "single provider rejects overlapping controllers") }
            fake.completeTranscript(.success(transcript())); let result = try await task.value
            try check(result.text == "合成示例" && result.engine == q.activeEngine && !result.rawResponseJSON.isEmpty && q.state == .finalized, "batch final preserves raw text engine and evidence")
            let late = Task { @MainActor in try await q.transcribeSegment(fileURL: root.appendingPathComponent("unused.wav")) }
            await fake.wait("transcribe"); q.unload(); fake.completeTranscript(.success(transcript("晚返回"))); try await expectFailure(late)
            try check(q.state == .idle && q.activeEngine == nil, "unload retires active and late result")
            let reloading = Task { @MainActor in try await q.loadAsync(config) }
            await fake.wait("load"); fake.completeLoad(.success(ack)); let reloaded = try await reloading.value
            try check(reloaded.generation > oldGeneration, "reload changes generation")
            fake.crash(); await Task.yield(); await Task.yield()
            try check(q.state == .failed && q.activeEngine == nil && q.lastFailure == .qwen("WORKER_EXITED_9"), "idle worker exit clears prepared identity")
            do {
                let f = FakeWorker(), provider = try await prepared(f)
                let t = Task { @MainActor in try await provider.transcribeSegment(fileURL: root.appendingPathComponent("unused.wav"), expectedAudioSHA256: sha) }
                await f.wait("transcribe"); f.completeTranscript(.success(transcript("", noSpeech: true)))
                let r = try await t.value
                try check(r.noSpeech && r.text.isEmpty && provider.activeEngine != nil && provider.state == .finalized && f.stops == 0, "explicit no speech keeps validated engine")
                provider.unload()
            }
            for (name, response) in [("empty transcript", transcript(" \n")),("budget without EOS", transcript("未终止",eos:false)),("wrong audio identity",transcript(audioSHA:String(repeating:"b",count:64))),("contradictory no speech",transcript("text",noSpeech:true)),("no speech without EOS",transcript("",eos:false,noSpeech:true)),("no speech wrong audio",transcript("",audioSHA:String(repeating:"b",count:64),noSpeech:true))] {
                let f = FakeWorker(), provider = try await prepared(f)
                let t = Task { @MainActor in try await provider.transcribeSegment(fileURL: root.appendingPathComponent("unused.wav"),expectedAudioSHA256:sha) }
                await f.wait("transcribe"); f.completeTranscript(.success(response)); try await expectFailure(t)
                try check(provider.state == .failed && provider.activeEngine == nil && f.stops > 0, name + " fails, requires reload")
            }
            let failed = FakeWorker(), bad = LocalASRProvider(providerID: .qwen3ASR,qwenFactory:{failed})
            let failedTask = Task { @MainActor in try await bad.loadAsync(config) }
            await failed.wait("load"); failed.completeLoad(.failure(QwenBridgeError.protocolFailure("ASSET_SHA_MISMATCH"))); try await expectFailure(failedTask)
            try check(bad.state == .failed && bad.activeEngine == nil, "asset load failure never prepared")
            let apple = LocalASRRegistry.make(.appleSpeech)
            let appleConfig = ASRConfiguration(providerID:.appleSpeech,locale:.simplifiedChinese)
            print("APPLE_INSPECT \(apple.inspect(appleConfig).state.rawValue) permission_requests=0 tasks=0")
            try check(apple.activeEngine == nil, "Apple inspect unchanged and no recognition task")
            if CommandLine.arguments.contains("--lease-v2") {
                let real = LocalASRRegistry.make(.qwen3ASR)
                let identity = try await real.loadAsync(config)
                try check(identity.engineVersion.contains("bridge=2;lease=uid-global-v2") && real.state == .prepared, "packaged bridge actually loads v2 worker")
                print("V2_LOAD " + String(data: try JSONEncoder().encode(real.qwenLoadAcknowledgement!), encoding: .utf8)!)
                let fixture = root.deletingLastPathComponent().appendingPathComponent("integration-check/asr-model-comparison-001/canonical-pcm/mixed-m1.wav")
                let result = try await real.transcribeSegment(fileURL: fixture)
                try check(result.engine == identity && !result.text.isEmpty, "one existing synthetic final through packaged v2")
                print("V2_FINAL request=\(result.requestID) raw=" + result.rawResponseJSON)
                let pid = real.qwenLoadAcknowledgement!.workerPID
                real.unload()
                for _ in 0..<100 {
                    if Darwin.kill(Int32(pid), 0) != 0 { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                try check(real.state == .idle && real.activeEngine == nil && Darwin.kill(Int32(pid), 0) != 0, "v2 unload exits process and clears identity")
            }
            if CommandLine.arguments.contains("--real") {
                let real = LocalASRRegistry.make(.qwen3ASR)
                let start = ProcessInfo.processInfo.systemUptime
                let heartbeat = Task { @MainActor in
                    try await Task.sleep(for: .milliseconds(20))
                    print("MAIN_ACTOR_HEARTBEAT state=\(real.state.rawValue)")
                    return ProcessInfo.processInfo.systemUptime-start
                }
                let identity = try await real.loadAsync(config)
                let tick = try await heartbeat.value
                try check(tick < 2 && real.state == .prepared && identity.modelVersion == modelVersion, "real background load leaves MainActor responsive")
                print("REAL_LOAD " + String(data:try JSONEncoder().encode(real.qwenLoadAcknowledgement!),encoding:.utf8)!)
                let contender = LocalASRRegistry.make(.qwen3ASR)
                do { _ = try await contender.loadAsync(config); throw CheckFailure(name:"GPU lease stolen") }
                catch let error as ASRProviderError {
                    try check(String(describing:error).contains("QWEN_GPU_BUSY"),"second provider cannot steal global GPU lease")
                }
                for id in ["mono-zh","mono-en","mixed-m1","mixed-m2"] {
                    let fixture = root.deletingLastPathComponent().appendingPathComponent("integration-check/asr-model-comparison-001/canonical-pcm/\(id).wav")
                    let output = try await real.transcribeSegment(fileURL:fixture)
                    try check(!output.text.isEmpty && output.engine == identity,"real final \(id)")
                    print("REAL_FINAL fixture=\(id) request=\(output.requestID) raw=" + output.rawResponseJSON)
                }
                let pid = real.qwenLoadAcknowledgement!.workerPID
                let cancelled = Task { @MainActor in try await real.transcribeSegment(fileURL:root.deletingLastPathComponent().appendingPathComponent("integration-check/asr-model-comparison-001/canonical-pcm/mixed-m1.wav")) }
                await Task.yield(); real.cancel(); try await expectFailure(cancelled)
                try check(real.state == .cancelled && real.activeEngine == nil,"real cancel kills active worker and discards final")
                for _ in 0..<100 {
                    if Darwin.kill(Int32(pid),0) != 0 { break }
                    try await Task.sleep(for:.milliseconds(10))
                }
                try check(Darwin.kill(Int32(pid),0) != 0,"real cancelled process exited")
                let timeout = LocalASRRegistry.make(.qwen3ASR)
                let runtime = QwenRuntimeConfiguration(pythonExecutableURL:root.appendingPathComponent(".venv-local/bin/python"),modelManifestURL:root.appendingPathComponent("model-assets.json"),referenceDirectoryURL:root.appendingPathComponent("reference"),timeoutSeconds:0.01)
                do { _ = try await timeout.loadAsync(.init(providerID:.qwen3ASR,locale:.simplifiedChinese,modelPath:modelPath,qwenRuntime:runtime)); throw CheckFailure(name:"timeout unexpectedly prepared") }
                catch let error as ASRProviderError { print("REAL_TIMEOUT \(error)") }
                try check(timeout.activeEngine == nil && timeout.state == .failed,"real load deadline never publishes prepared")
            }
            print("RESULT \(passes)/\(passes) PASS; real mode=\(CommandLine.arguments.contains("--real")); mic=0 permission_requests=0")
        } catch {
            print("FAIL \(error)"); exit(1)
        }
    }
}
