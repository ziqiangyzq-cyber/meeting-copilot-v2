import Foundation
import MeetingCopilotCore

extension ClientModel {
    public func quickNoteTimeLabel(at date: Date = Date()) -> String {
        guard captureActive, let start = quickNoteCaptureStartedAt else { return "随记时间" }
        let seconds = Int(max(0, date.timeIntervalSince(start)))
        return String(format: qwenBatchActive ? "本轮导入 %02d:%02d" : "本轮采集 %02d:%02d", seconds / 60, seconds % 60)
    }

    /// The clock is a writing timestamp, and the segment is the nearest saved
    /// original. Neither is claimed to be a calibrated word/audio alignment.
    public func appendTimedNote(_ text: String, at date: Date = Date()) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, loaded, error == nil, let session = selected, !session.isDeleted else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var context = formatter.string(from: date)
        if captureActive { context += " · " + quickNoteTimeLabel(at: date) }
        if !session.segments.isEmpty {
            context += " · 附近原文段 \(session.segments.count)"
        }
        let separator = session.notes.isEmpty || session.notes.hasSuffix("\n") ? "" : "\n"
        notes(session.notes + separator + "[\(context)] \(trimmed)", id: session.id)
    }

    public func removeDemonstrationSessions() {
        guard loaded, !captureActive, error == nil else { return }
        for session in archive.activeSessions where session.isDemo {
            deleteSession(session.id, reason: "user_requested_remove_demo")
            if error != nil { break }
        }
    }
}
