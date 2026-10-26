import Foundation
import ClientRuntime
import LocalASRProviders
import AppleOfflineSpeech

// Settings behavioural checks. Every claim is exercised through the real settings models and real storage;
// nothing is stubbed. The Apple path only inspects (no task, no authorization prompt, no microphone).
struct SettingsCheckFailure: Error { let message: String }
func settingsRequire(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw SettingsCheckFailure(message: message) }
}

@MainActor func runSettingsChecks(root: URL) async throws {
    // 1. requested / persisted / active are genuinely separate.
    let d1 = root.appendingPathComponent("separation")
    try FileManager.default.createDirectory(at: d1, withIntermediateDirectories: true)
    let m = ASRSettingsModel(directory: d1)
    try settingsRequire(m.persisted.providerID == ASRProviderID.qwen3ASR.rawValue, "a fresh setup defaults to the Qwen candidate without loading")
    try settingsRequire(m.activeEngineDescription == nil, "nothing is active before a real load")
    try settingsRequire(m.request(providerID: ASRProviderID.appleSpeech.rawValue, locale: "en-US", modelPath: nil), "a supported provider can be requested")
    try settingsRequire(m.requested.locale == "en-US", "requested records the pick")
    try settingsRequire(m.persisted.locale != "en-US", "requesting alone must not change what is persisted")
    try settingsRequire(m.activeEngineDescription == nil, "requesting alone must not create an active engine")
    try settingsRequire(m.save(), "saving the selection succeeds")
    try settingsRequire(m.persisted.locale == "en-US", "persisted now reflects the saved pick")
    try settingsRequire(m.activeEngineDescription == nil, "saving is still not readiness")
    print("PASS settings: requested / persisted / active stay separate (save != ready)")

    // 2. persistence survives a restart.
    let m2 = ASRSettingsModel(directory: d1)
    try settingsRequire(m2.persisted.locale == "en-US", "the saved selection survives a reopen")
    try settingsRequire(m2.activeEngineDescription == nil, "a reopen does not fabricate an active engine")
    print("PASS settings: saved selection survives relaunch; active stays empty")

    // 3a. an un-implemented provider cannot be picked at all, and nothing is substituted for it.
    let d3 = root.appendingPathComponent("unsupported")
    try FileManager.default.createDirectory(at: d3, withIntermediateDirectories: true)
    let m3 = ASRSettingsModel(directory: d3)
    let qwen = ASRProviderID.qwen3ASR.rawValue
    try settingsRequire(m3.request(providerID: qwen, locale: "zh-CN", modelPath: "/tmp/whatever", runtimePath: "/tmp/runtime", context: "SampleTerm"), "Qwen can be configured as a candidate")
    try settingsRequire(m3.requested.providerID == qwen, "the candidate remains Qwen; no silent substitute")
    try settingsRequire(m3.activeEngineDescription == nil, "candidate configuration does not load weights")
    try settingsRequire(m3.save(), "candidate configuration can be persisted")
    let candidateReopen = ASRSettingsModel(directory: d3)
    try settingsRequire(candidateReopen.persisted.runtimePath == "/tmp/runtime" && candidateReopen.persisted.context == "SampleTerm", "runtime and user terminology survive relaunch")
    try settingsRequire(candidateReopen.activeEngineDescription == nil, "reopening configured Qwen does not load")
    let oldApple = try JSONDecoder().decode(ASRSelection.self, from: Data(#"{"providerID":"apple-speech-on-device","locale":"en-US"}"#.utf8))
    try settingsRequire(oldApple.providerID == "apple-speech-on-device" && oldApple.runtimePath == nil && oldApple.context == nil, "old Apple settings decode unchanged, with missing new fields nil")
    print("PASS settings: Qwen candidate persists without loading; runtime/context reopen; old Apple stays unchanged")

    // 3b. Defensive: a PERSISTED selection naming an un-integrated provider (older file, hand-edited, or a
    // provider withdrawn later). It must report unsupported and must never run as something else.
    let d3b = root.appendingPathComponent("unsupported-persisted")
    try FileManager.default.createDirectory(at: d3b, withIntermediateDirectories: true)
    let storage = SettingsStorage(directory: d3b)
    try storage.saveASR(ASRSelection(providerID: qwen, locale: "zh-CN", modelPath: "/tmp/qwen-model-dir"))
    let m3b = ASRSettingsModel(directory: d3b)
    try settingsRequire(m3b.persisted.providerID == qwen, "the stored un-integrated selection is read back as-is")
    if case .prepared = m3b.status { throw SettingsCheckFailure(message: "a stored path cannot be prepared") }
    let invalidLoad = await m3b.loadActive()
    try settingsRequire(!invalidLoad, "loading a missing Qwen directory fails")
    try settingsRequire(m3b.activeEngineDescription == nil, "no engine becomes active for it")
    let test = await m3b.runShortAudioTest()
    try settingsRequire(test.contains("完整文件"), "Qwen short test must direct to full files: \(test)")
    try settingsRequire(!test.contains("Apple"), "the test result never claims Apple ran in its place: \(test)")
    print("PASS settings: a persisted un-integrated provider reports unsupported and never runs as Apple")

    // 4. switching is refused while a capture is active.
    let d4 = root.appendingPathComponent("capture-active")
    try FileManager.default.createDirectory(at: d4, withIntermediateDirectories: true)
    let m4 = ASRSettingsModel(directory: d4)
    m4.captureActive = true
    try settingsRequire(!m4.request(providerID: ASRProviderID.appleSpeech.rawValue, locale: "en-US", modelPath: nil), "switching during capture is refused")
    try settingsRequire(m4.lastRefusal == .captureActive, "the refusal reason is capture-active")
    try settingsRequire(m4.requested.locale != "en-US", "the pick is not applied during capture")
    try settingsRequire(!m4.save(), "saving during capture is refused")
    let captureLoad = await m4.loadActive()
    try settingsRequire(!captureLoad, "loading during capture is refused")
    let duringCapture = await m4.runShortAudioTest()
    try settingsRequire(!duringCapture.isEmpty, "the short-audio test during capture explains itself")
    m4.captureActive = false
    try settingsRequire(m4.request(providerID: ASRProviderID.appleSpeech.rawValue, locale: "en-US", modelPath: nil), "after capture stops, switching is accepted again")
    print("PASS settings: switching/saving/loading are refused during capture and allowed after")

    // 5. Apple path: a read-only inspect, no task, no prompt. Whatever the OS says is reported verbatim.
    let d5 = root.appendingPathComponent("apple-inspect")
    try FileManager.default.createDirectory(at: d5, withIntermediateDirectories: true)
    let m5 = ASRSettingsModel(directory: d5)
    _ = m5.request(providerID: ASRProviderID.appleSpeech.rawValue, locale: "zh-CN", modelPath: nil)
    m5.refresh()
    switch m5.status {
    case .permissionRequired, .unavailable, .readyToPrepare, .prepared:
        print("PASS settings: Apple inspect returned a real state without starting a task: \(m5.status)")
    case .unsupported, .invalidConfiguration, .failed, .loading:
        throw SettingsCheckFailure(message: "unexpected Apple inspect state: \(m5.status)")
    }
    try settingsRequire(m5.activeEngineDescription == nil, "inspect never activates an engine")

    // 6. backend API settings: stored separately, key kept as a reference only.
    let d6 = root.appendingPathComponent("backend")
    try FileManager.default.createDirectory(at: d6, withIntermediateDirectories: true)
    let b = BackendAPISettingsModel(directory: d6)
    try settingsRequire(b.status == .unconfigured, "a fresh backend is unconfigured")
    b.draft.baseURL = "https://example.invalid/v1"
    b.draft.modelID = "some-model"
    b.draft.secretReference = "DSH_SECRET_DEFINITELY_NOT_SET_FOR_TEST"
    try settingsRequire(b.save(), "backend settings save")
    try settingsRequire(b.status == .configuredUnverified, "saved backend is configured but NOT claimed available")
    try settingsRequire(!b.secretIsPresent(), "a missing key is reported as absent, not assumed")
    let raw = try String(contentsOf: b.storableFileURLForCheck(), encoding: .utf8)
    try settingsRequire(!raw.contains("sk-"), "no key material is written")
    try settingsRequire(raw.contains("DSH_SECRET_DEFINITELY_NOT_SET_FOR_TEST"), "only the reference name is stored")
    let b2 = BackendAPISettingsModel(directory: d6)
    try settingsRequire(b2.persisted.baseURL == "https://example.invalid/v1", "backend settings survive a reopen")
    print("PASS settings: backend API stored separately; only a key reference is persisted, never the key")

    // 7. the settings file is separate from the archive schema.
    try settingsRequire(FileManager.default.fileExists(atPath: d6.appendingPathComponent("settings.json").path),
                        "settings live in their own settings.json")
    try settingsRequire(!FileManager.default.fileExists(atPath: d6.appendingPathComponent("sessions.json").path),
                        "writing settings does not create or touch the archive file")
    print("PASS settings: settings.json is separate from the archive; the archive is never written by settings")

    _ = try b.apiConfiguration()
    b.inspectAPIConfiguration()
    if case .verificationFailed = b.status {} else { throw SettingsCheckFailure(message: "missing credential must not be usable") }
    let savedBefore = try Data(contentsOf: b.storableFileURLForCheck())
    b.draft.secretReference = "synthetic-secret-value/never-a-reference"
    try settingsRequire(!b.save(), "credential value-like text is rejected rather than persisted")
    let savedAfter = try Data(contentsOf: b.storableFileURLForCheck())
    try settingsRequire(savedBefore == savedAfter, "rejected credential input leaves settings file unchanged")
    print("PASS settings: real API configuration validates offline; missing credentials fail closed; secret value input cannot persist")

    try await runFileBatchChecks(root: root)
    try await runQwenWriterChecks(root: root)
    print("SETTINGS_CHECKS_COMPLETE")
}

@main struct SettingsChecksMain {
    @MainActor static func main() async {
        do {
            guard let base = ProcessInfo.processInfo.environment["SETTINGS_CHECK_ROOT"] else {
                print("SETTINGS_CHECK_ROOT required"); exit(2)
            }
            let root = URL(fileURLWithPath: base, isDirectory: true)
            if FileManager.default.fileExists(atPath: root.path) {
                print("refusing existing directory \(root.path)"); exit(2)
            }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try await runSettingsChecks(root: root)
        } catch {
            print("SETTINGS_CHECKS_FAILED: \(error)")
            exit(3)
        }
    }
}
