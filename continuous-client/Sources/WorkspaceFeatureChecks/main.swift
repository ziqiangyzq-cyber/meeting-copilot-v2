import Foundation
import CoreGraphics
import CoreText
import MeetingCopilotCore
import ClientRuntime

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL " + message) }
    print("PASS " + message)
}

@main struct WorkspaceFeatureChecks {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-copilot-workspace-checks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("materials")
        let nested = folder.appendingPathComponent("一级/二级")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("项目术语\n示例词".utf8).write(to: folder.appendingPathComponent("agenda.md"))
        try Data("决定：核对图纸。".utf8).write(to: nested.appendingPathComponent("decision.txt"))
        try Data("complex".utf8).write(to: nested.appendingPathComponent("drawing.dwg"))
        try Data("hidden".utf8).write(to: folder.appendingPathComponent(".secret.txt"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("outside.txt"),
            withDestinationURL: root.appendingPathComponent("outside.txt"))
        try Data("outside".utf8).write(to: root.appendingPathComponent("outside.txt"))
        let pdfURL = nested.appendingPathComponent("text.pdf")
        let consumer = CGDataConsumer(url: pdfURL as CFURL)!
        var rect = CGRect(x: 0, y: 0, width: 500, height: 500)
        let context = CGContext(consumer: consumer, mediaBox: &rect, nil)!
        context.beginPDFPage(nil)
        context.textPosition = CGPoint(x: 30, y: 400)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Meeting reference PDF") as CFAttributedString)
        CTLineDraw(line, context); context.endPDFPage(); context.closePDF()
        if let fixturePath = ProcessInfo.processInfo.environment["WORKSPACE_MATERIAL_FIXTURE"] {
            let destination = URL(fileURLWithPath: fixturePath, isDirectory: true)
            if !FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.copyItem(at: folder, to: destination) }
        }
        let emptyPDF = nested.appendingPathComponent("scan.pdf")
        let blankConsumer = CGDataConsumer(url: emptyPDF as CFURL)!
        let blank = CGContext(consumer: blankConsumer, mediaBox: &rect, nil)!
        blank.beginPDFPage(nil); blank.endPDFPage(); blank.closePDF()
        let scan = try MaterialFolder.scan(folder)
        check(scan.materials.count == 3, "recursive TXT/MD/text PDF; hidden and symlink excluded")
        check(scan.materials.contains(where: { $0.text.contains("Meeting reference PDF") }), "PDF text actually extracted")
        check(scan.report.contains(where: { $0.contains("scan.pdf") && $0.contains("OCR") }), "image-only PDF skipped with explicit reason")
        check(scan.report.contains(where: { $0.contains("drawing.dwg") }), "unsupported file reported")
        check(scan.report.contains(where: { $0.contains("符号链接") }), "symbolic link reported")
        let small = try MaterialFolder.scan(folder, maxFileBytes: 5)
        check(small.materials.isEmpty, "oversized files skipped with no partial import")
        let limited = try MaterialFolder.scan(folder, maxFiles: 1)
        check(limited.materials.count == 1 && limited.report.contains(where: { $0.contains("上限") }), "file cap reported")

        let dataDir = root.appendingPathComponent("app-data")
        let model = ClientModel(directory: dataDir)
        model.add(demo: false)
        let activeID = model.selection!
        let original = LocalSegment(id: "saved-original", channelKind: "system",
            revisions: [SourceRevision(revision: 1, text: "Review drawings", startNS: "0", endNS: "8000000000")])
        model.archive.sessions[0].segments.append(original)
        check(model.persist(), "original fixture durably saved")
        model.appendTimedNote("确认负责人", at: Date(timeIntervalSince1970: 1_800_000_000))
        check(model.selected!.notes.contains("附近原文段 1") && model.selected!.notes.contains("确认负责人"), "timed note anchors nearest saved original")
        let noteSnapshot = MeetingSourceSnapshot(session: model.selected!, includeMaterials: false)
        check(noteSnapshot.sources.contains(where: { $0.citationID == "N1" && $0.text.contains("确认负责人") }), "timed notes included in minutes source snapshot")
        model.configureMaterialFolder(folder, sessionID: activeID)
        while model.materialFolderBusy { try await Task.sleep(nanoseconds: 20_000_000) }
        check(model.error == nil && model.selected!.materials.count == 3, "folder snapshot durably saved")
        let ids = model.selected!.materials.map(\.id)
        model.refreshMaterialFolder()
        while model.materialFolderBusy { try await Task.sleep(nanoseconds: 20_000_000) }
        check(model.selected!.materials.map(\.id) == ids, "unchanged refresh preserves identities")
        let before = MeetingSourceSnapshot(session: model.selected!, includeMaterials: true)
        try Data("决定变更：下周核对。".utf8).write(to: nested.appendingPathComponent("decision.txt"))
        model.refreshMaterialFolder()
        while model.materialFolderBusy { try await Task.sleep(nanoseconds: 20_000_000) }
        let after = MeetingSourceSnapshot(session: model.selected!, includeMaterials: true)
        check(after.fingerprint != before.fingerprint && model.selected!.materials.count == 3, "changed folder replaces active snapshot and invalidates source fingerprint")
        let reopened = ClientModel(directory: dataDir)
        check(reopened.selected!.notes == model.selected!.notes && reopened.selectedMaterialFolder?.path == folder.path,
            "note and folder configuration reopen persisted")
        let firstID = model.selection!
        model.add(demo: false)
        let selectedID = model.selection!
        model.deleteSession(firstID)
        check(model.selection == selectedID && model.visibleSessions.count == 1, "right-click target deletion leaves another selected session unchanged")
        check(model.deletedSessions.first?.id == firstID && model.deletedSessions.first?.notes.contains("确认负责人") == true,
            "deleted original and notes retained for audit")
        reopened.deleteSession(firstID)
        check(reopened.error != nil && reopened.visibleSessions.contains(where: { $0.id == firstID }), "stale delete fails and rolls back local tombstone")
        model.add(demo: true)
        model.removeDemonstrationSessions()
        check(!model.visibleSessions.contains(where: \.isDemo) && model.deletedSessions.contains(where: \.isDemo),
            "demo removal is auditable and real session preserved")
        let final = ClientModel(directory: dataDir)
        check(final.visibleSessions.count == 1 && final.deletedSessions.count == 2, "deletion and demo retirement survive restart")
        print("WORKSPACE_FEATURE_CHECKS_COMPLETE; isolated files and local source snapshots; no API")
    }
}
