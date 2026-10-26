import SwiftUI
import AppKit
import MeetingCopilotCore
import ClientRuntime

@main struct MeetingCopilotApp: App {
    @StateObject private var model: ClientModel
    @StateObject private var asrSettings: ASRSettingsModel
    @StateObject private var backendSettings: BackendAPISettingsModel
    @StateObject private var intelligence: MeetingIntelligenceModel
    @NSApplicationDelegateAdaptor(AppTerminationDelegate.self) private var termination

    init() {
        let dir = Self.settingsDirectory()
        Self.migratePreviousV2DataIfNeeded(to: dir)
        Self.migrateLegacyDataIfNeeded(to: dir)
        Self.normalizeSettingsPathsIfNeeded(to: dir)
        let client = ClientModel(directory: dir)
        if ProcessInfo.processInfo.environment["MEETING_COPILOT_SMOKE_DEMO"] != "1" {
            client.removeDemonstrationSessions()
        }
        client.translateFinal = true
        _model = StateObject(wrappedValue: client)
        _asrSettings = StateObject(wrappedValue: ASRSettingsModel(directory: dir))
        _backendSettings = StateObject(wrappedValue: BackendAPISettingsModel(directory: dir))
        _intelligence = StateObject(wrappedValue: MeetingIntelligenceModel(directory: dir))
    }

    /// Same data directory rule as ClientModel, so settings live beside the archive.
    private static func settingsDirectory() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let path = env["MEETING_COPILOT_DATA_DIR"] { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(ProductIdentity.dataDirectoryName, isDirectory: true)
    }

    /// Copy the pre-public v2 data directory into the neutral public identity. The old directory stays in
    /// place, so this migration is reversible and never destroys the user's existing archive.
    private static func migratePreviousV2DataIfNeeded(to directory: URL) {
        guard ProcessInfo.processInfo.environment["MEETING_COPILOT_SKIP_LEGACY_MIGRATION"] != "1" else { return }
        do {
            if let report = try LegacyProductMigration.migratePreviousV2DataIfNeeded(destination: directory) {
                fputs("Migrated pre-public v2 data: \(report.copiedFiles) files from \(report.source)\n", stderr)
            }
        } catch {
            fputs("Pre-public v2 data migration failed: \(error.localizedDescription)\n", stderr)
        }
    }

    /// Copy the legacy Foresight archive before constructing any settings or archive model. The old directory
    /// stays in place; migration failure is surfaced rather than silently starting with an empty history.
    private static func migrateLegacyDataIfNeeded(to directory: URL) {
        guard ProcessInfo.processInfo.environment["MEETING_COPILOT_SKIP_LEGACY_MIGRATION"] != "1" else { return }
        do {
            let productRoot = Bundle.main.bundleURL.deletingLastPathComponent()
            let oldProductRoot = productRoot.appendingPathComponent("Foresight Meeting", isDirectory: true)
            var roots = [productRoot]
            if FileManager.default.fileExists(atPath: oldProductRoot.path) { roots.append(oldProductRoot) }
            if let report = try LegacyProductMigration.migrateIfNeeded(
                destination: directory,
                legacyProductRoots: roots,
                destinationProductRoot: productRoot
            ) {
                fputs("Migrated legacy data: \(report.copiedFiles) files from \(report.source)\n", stderr)
            }
        } catch {
            fputs("Legacy data migration failed: \(error.localizedDescription)\n", stderr)
        }
    }

    /// A migrated settings file can still contain absolute paths to the old
    /// product folder. Normalize those paths before any settings model reads
    /// the file, while preserving unrelated keys and strings.
    private static func normalizeSettingsPathsIfNeeded(to directory: URL) {
        guard ProcessInfo.processInfo.environment["MEETING_COPILOT_SKIP_LEGACY_MIGRATION"] != "1" else { return }
        let productRoot = Bundle.main.bundleURL.deletingLastPathComponent()
        let oldProductRoot = productRoot.appendingPathComponent("Foresight Meeting", isDirectory: true)
        do {
            _ = try LegacyProductMigration.normalizeExistingSettingsPaths(
                destination: directory,
                legacyProductRoots: [oldProductRoot],
                destinationProductRoot: productRoot
            )
        } catch {
            fputs("Settings path normalization failed: \(error.localizedDescription)\n", stderr)
        }
    }

    var body: some Scene {
        WindowGroup("Meeting Copilot", id: "main") {
            ClientView(model: model, asrSettings: asrSettings, backendSettings: backendSettings, intelligence: intelligence).onAppear {
                // The capture path must start on the persisted locale, not a built-in default.
                model.asrSettings = asrSettings
                model.recognizerLocale = asrSettings.persisted.locale
                if model.translateFinal { model.translateMissingCurrentSegments() }
                termination.model = model
                // Incremental persistence is an explicit opt-in; the default path stays ArchiveStore.
                if ProcessInfo.processInfo.environment["MEETING_COPILOT_INCREMENTAL"] == "1" { Task { await model.enableIncrementalOnLaunch() } }
                captureSmokeEvidenceIfRequested()
                closeWitnessIfRequested(model: model, termination: termination)
            }.onReceive(asrSettings.$requested) { selection in
                if !model.captureActive, selection.providerID == "apple-speech-on-device" {
                    model.recognizerLocale = selection.locale
                }
            }.onReceive(model.$captureActive) { asrSettings.captureActive = $0 }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                // Core Audio Tap permission has no public preflight. Do not
                // infer denial from activation; the explicit probe is the
                // only truthful status update.
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
                // Closing a window is not a durability gate. It only stops the synthetic/real capture; the
                // store's close gate runs in applicationShouldTerminate below.
                if let window = notification.object as? NSWindow,
                   window.title == "Meeting Copilot" { model.cancelCapture() }
            }
        }
        .commands { CommandGroup(replacing: .newItem) { Button("新建会议") { model.add(demo: false) }.keyboardShortcut("n").disabled(!model.loaded || model.error != nil) } }
        Window("Meeting Copilot · HUD", id: "hud") { ClientHUD(model: model, asrSettings: asrSettings) }
            .windowStyle(.hiddenTitleBar).windowResizability(.contentSize)
        Window("Meeting Copilot · 设置", id: "settings") {
            SettingsView(asr: asrSettings, backend: backendSettings, captureActive: model.captureActive)
        }.windowResizability(.contentSize)
    }
    /// Real-application close-gate witness. Not a unit check: this runs inside the launched app, edits a real
    /// note through the same model the TextEditor binding uses, then asks AppKit to terminate so the real
    /// `applicationShouldTerminate` gate of `AppTerminationDelegate` decides. Only `MEETING_COPILOT_CLOSE_WITNESS`
    /// (an isolated temp path) enables it; ordinary launches never enter here.
    private func closeWitnessIfRequested(model: ClientModel, termination: AppTerminationDelegate) {
        guard let prefix = ProcessInfo.processInfo.environment["MEETING_COPILOT_CLOSE_WITNESS"] else { return }
        let mode = ProcessInfo.processInfo.environment["MEETING_COPILOT_CLOSE_WITNESS_MODE"] ?? "pass"
        let witness = URL(fileURLWithPath: prefix + ".txt")
        func append(_ line: String) {
            let existing = (try? String(contentsOf: witness, encoding: .utf8)) ?? ""
            try? (existing + line + "\n").write(to: witness, atomically: true, encoding: .utf8)
        }
        append("LAUNCHED pid=\(ProcessInfo.processInfo.processIdentifier) mode=\(mode) incremental=\(ProcessInfo.processInfo.environment["MEETING_COPILOT_INCREMENTAL"] ?? "unset")")
        let deadline = Date().addingTimeInterval(25)
        func waitReady(_ body: @escaping () -> Void) {
            if model.incremental?.isAvailable == true, model.loaded { append("READY head=\(model.incremental?.lastConfirmedHead ?? 0)"); body(); return }
            if Date() >= deadline { append("FAIL incremental store never became available"); exit(5) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { waitReady(body) }
        }
        waitReady {
            // Reopen mode proves the exact projection after a real close, in a new process, without editing.
            if mode == "reopen" {
                let sessions = model.archive.sessions
                let notes = sessions.first?.notes ?? ""
                append("REOPEN sessions=\(sessions.count) notes_present=\(notes.contains("窗口关闭门合成随记")) notes_revision=\(sessions.first?.noteHistory.last?.revision ?? 0) head=\(model.incremental?.lastConfirmedHead ?? 0) text=\(notes)")
                self.writeWitnessState(model: model, prefix: prefix, verdict: "reopened")
                exit(0)
            }
            model.add(demo: false)
            guard let session = model.selected else { append("FAIL no session"); exit(6) }
            let text = mode == "fail" ? String(repeating: "超额随记内容 ", count: 2000)
                                      : "窗口关闭门合成随记：示例词 节点 USD 2,450.75。"
            model.notes(text, id: session.id)
            let revision = model.archive.sessions.first { $0.id == session.id }?.noteHistory.last?.revision ?? 0
            append("EDITED session=\(session.id) note_revision=\(revision) characters=\(text.count)")
            append("REQUEST_TERMINATE")
            // A real quit arrives as a runloop event (menu/Cmd-Q), not from inside a main-queue dispatch block:
            // calling terminate from a dispatch callback would start AppKit's nested _shouldTerminate runloop
            // while the main queue is still draining, so a `.terminateLater` reply could never be scheduled.
            Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { _ in NSApplication.shared.terminate(nil) }
            // The gate replies asynchronously: on a clean close the app is gone before this fires. If it is still
            // alive, the refusal is a recorded fact, not a silent hang. Exit 70 marks "terminate was refused",
            // which is the expected, correct outcome for the oversized-note case and a bug for the clean case.
            DispatchQueue.main.asyncAfter(deadline: .now() + (mode == "fail" ? 8 : 12)) {
                let status = model.incrementalSavingStatus
                let closed = model.incremental?.isClosed ?? false
                append("TERMINATE-REFUSED error=\(model.error ?? "nil") status=\(status) store_closed=\(closed) head=\(model.incremental?.lastConfirmedHead ?? 0) unconfirmed=\(model.hasUnconfirmedIncrementalWork)")
                self.writeWitnessState(model: model, prefix: prefix, verdict: "refused-after-terminate")
                exit(70)
            }
        }
    }
    private func writeWitnessState(model: ClientModel, prefix: String, verdict: String) {
        let payload: [String: Any] = ["verdict": verdict, "error": model.error ?? "",
                                      "incremental_status": model.incrementalSavingStatus,
                                      "confirmed_head": model.incremental?.lastConfirmedHead ?? 0,
                                      "has_unconfirmed": model.hasUnconfirmedIncrementalWork]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        try? data.write(to: URL(fileURLWithPath: prefix + ".json"))
    }
    private func captureSmokeEvidenceIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["MEETING_COPILOT_UI_EVIDENCE"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            do {
                guard let window = NSApplication.shared.windows.first(where: { $0.contentView != nil }), let view = window.contentView,
                      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileReadUnknown) }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
                try png.write(to: URL(fileURLWithPath: path), options: .atomic)
                let witness = "UI_RENDERED\nwindow=\(window.title)\nsize=\(view.bounds.size)\nsessions=\(model.archive.sessions.count)\nengine=mic-offline-integrated-default-disabled\nstore=\(model.store.fileURL.path)\n"
                try witness.write(toFile: path + ".txt", atomically: true, encoding: .utf8)
                NSApplication.shared.terminate(nil)
            } catch { fputs("UI smoke failed: \(error)\n", stderr); exit(2) }
        }
    }
}

/// Real termination gate. `applicationShouldTerminate` returns `.terminateLater` and only replies `true` after
/// the incremental store reported a genuinely clean close; otherwise the window stays open and retry stays possible.
/// A failed close never blocks the process forever: a bounded second wait reports the real reason and leaves the
/// decision to `MEETING_COPILOT_FORCE_QUIT`, which is explicit and off by default.
@MainActor final class AppTerminationDelegate: NSObject, NSApplicationDelegate {
    var model: ClientModel?
    private var inFlight = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model?.cancelMaterialFolderScan()
        guard let model, model.incremental != nil, !inFlight else { return .terminateNow }
        inFlight = true
        Task { [weak self] in
            let result = await model.prepareForTermination()
            guard let self else { sender.reply(toApplicationShouldTerminate: result.ready); return }
            if result.ready {
                sender.reply(toApplicationShouldTerminate: true)
            } else {
                self.inFlight = false
                model.error = "退出前保存未完成：\(result.reason ?? "未知") · 窗口保留，可修正后重试退出"
                if ProcessInfo.processInfo.environment["MEETING_COPILOT_FORCE_QUIT"] == "1" { sender.reply(toApplicationShouldTerminate: true) }
                else { sender.reply(toApplicationShouldTerminate: false) }
            }
        }
        return .terminateLater
    }
}
