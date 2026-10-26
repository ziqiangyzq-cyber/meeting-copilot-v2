import Foundation

public enum NoteExportFormat: String, CaseIterable { case markdown = "md", json }
public enum NoteOperations {
    // Case-insensitive literal substring, no regex/index lag. Historical/stale text excluded.
    public static func search(_ sessions: [LocalSession], keyword: String) -> [LocalSession] {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sessions }
        return sessions.filter { session in
            let current = session.segments.flatMap { segment -> [String] in
                [segment.current?.text ?? ""] + segment.currentTranslations.map(\.text)
            }
            return ([session.title, session.notes] + session.tags + current).contains { $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }
    public static func exportData(_ session: LocalSession, format: NoteExportFormat) throws -> Data {
        if format == .json {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(session)
        }
        var lines = ["# " + session.title.replacingOccurrences(of: "\n", with: " "), "", "会话 ID：\(session.id)", "标签：\(session.tags.joined(separator: "、"))", "数据：\(session.isDemo ? "自拟演示" : "本地记录")", "", "## 随记", "", session.notes, "", "## 原文与译文"]
        for segment in session.chronologicalSegments {
            lines += ["", "### 段 \(segment.id)", "来源：\(segment.channelKind)"]
            for revision in segment.revisions {
                lines += ["通道：\(revision.channelID ?? "无音频") · 流：\(revision.streamID ?? "无音频")"]
                if segment.channelKind == "mic" { lines += ["原文时间依据：task-local source/raw（原始观测，未校准）；独立 canonical nominal global timeline 见采集来源与诊断"] }
                for span in revision.sourceSpans ?? [] {
                    lines += ["源跨度：\(span.channelId)/\(span.streamId) · [\(span.frameStart), \(span.frameEnd)) native frames · mapping r\(span.mappingRevision)"]
                }
                lines += ["", "原文 r\(revision.revision) · \(revision.status) · [\(revision.startNS), \(revision.endNS)) ns", "", revision.text]
            }
            for translation in segment.translations {
                let isCurrent = segment.currentTranslations.contains(translation)
                lines += ["", "译文 \(translation.id) r\(translation.revision) · 源 r\(translation.sourceRevision) · \(translation.targetLanguage) · \(isCurrent ? "当前" : "过期历史")", "源文快照：\(translation.sourceText)", "", translation.text]
            }
        }
        lines += ["", "## 采集状态（独立于转写最终版本）"]
        for attempt in session.captureAttempts {
            lines += ["", "采集 \(attempt.id) · \(attempt.lifecycle) · \(attempt.locale)", "通道：\(attempt.channelID) · 流：\(attempt.streamID)", "设备启动：\(attempt.deviceStarted) · 音频观察：\(attempt.audioObserved) · ASR观察：\(attempt.asrObserved)"]
            lines += ["模式：\(attempt.mode ?? "finite") · generation：\(attempt.generationID ?? "legacy")"]
            for task in attempt.allTaskIdentities {
                lines += ["task \(task.segmentID) · stream \(task.streamID) · final observed \(task.finalObserved) · 首观察 \(task.firstObservedBy)"]
                for block in task.sourceBlocks ?? [] {
                    lines += ["task-local source（尚未校准）：[\(block.frameStart), \(block.frameEnd)) frames · [\(block.startNS), \(block.endNS)) ns · mapping r\(block.mappingRevision)",
                              "raw host=\(block.hostSeconds.map { String($0) } ?? "nil") samplePosition=\(block.samplePosition.map { String($0) } ?? "nil") sampleRate=\(block.sampleRate) PTS=\(block.presentationSeconds.map { String($0) } ?? "nil") receipt=\(block.receivedUptime)"]
                }
            }
            if let metadata = attempt.canonicalMetadata {
                lines += ["canonical global timeline · nominalFromEpochAnchor（名义时间，未校准）"]
                for block in metadata.blocks {
                    let a = block.anchor
                    lines += ["epoch \(a.epochID) · anchor \(a.startNs) ns · \(a.provenance) · \(a.basis) · \(a.sampleRate) Hz / \(a.channelCount) ch / \(a.encoding) · mapping r\(a.mappingRevision)",
                              "canonical block \(block.blockID) · global frames [\(block.globalFrameStart), \(block.globalFrameEnd)) · nominal [\(block.nominalStartNs), \(block.nominalEndNs)) ns",
                              "raw observation host=\(block.rawObservation.hostSeconds.map { String($0) } ?? "nil") PTS=\(block.rawObservation.presentationSeconds.map { String($0) } ?? "nil") samplePosition=\(block.rawObservation.samplePosition.map { String($0) } ?? "nil") sampleRate=\(block.rawObservation.sampleRate) receipt=\(block.rawObservation.receivedUptime)",
                              "diagnostic basis=\(block.timestampBasis ?? "nil") observedStartNs=\(block.observedStartNs.map { String($0) } ?? "nil") residualNs=\(block.residualNs.map { String($0) } ?? "nil") stepErrorNs=\(block.stepErrorNs.map { String($0) } ?? "nil") estimatedPPM=\(block.estimatedPPM.map { String($0) } ?? "nil")（统计，非校准）"]
                }
                for span in metadata.associations {
                    lines += ["actual backend task \(span.segmentID) · stream \(span.streamID) · block \(span.blockID) · epoch \(span.epochID) · taskStartGlobalFrame \(span.taskStartGlobalFrame) · global [\(span.globalFrameStart), \(span.globalFrameEnd)) · planned task-local [\(span.taskLocalFrameStart), \(span.taskLocalFrameEnd)) · nominal [\(span.nominalStartNs), \(span.nominalEndNs)) ns · \(span.basis) · mapping r\(span.mappingRevision)"]
                }
                for settled in metadata.settlements {
                    lines += ["settled block \(settled.blockID) · \(settled.disposition) · backendAccepted \(settled.backendAccepted) · ownerReturned \(settled.ownerReturned) · failure \(settled.failure ?? "nil")",
                              "settled raw source \(settled.rawObservation.source) host=\(settled.rawObservation.hostSeconds.map { String($0) } ?? "nil") PTS=\(settled.rawObservation.presentationSeconds.map { String($0) } ?? "nil") samplePosition=\(settled.rawObservation.samplePosition.map { String($0) } ?? "nil") sampleRate=\(settled.rawObservation.sampleRate) receipt=\(settled.rawObservation.receivedUptime)"]
                }
                if let c = metadata.terminalCoverage {
                    lines += ["terminalCoverage · transferred \(c.transferredBlocks)/\(c.transferredFrames) · mapped \(c.mappedBlocks)/\(c.mappedFrames) · recognitionConsumed \(c.recognitionConsumedBlocks)/\(c.recognitionConsumedFrames) · rejectedBeforeMapping \(c.rejectedBeforeMappingBlocks)/\(c.rejectedBeforeMappingFrames) · rejectedAfterMapping \(c.rejectedAfterMappingBlocks)/\(c.rejectedAfterMappingFrames) · uncertainAfterMapping \(c.uncertainAfterMappingBlocks)/\(c.uncertainAfterMappingFrames) · backendAccepted \(c.backendAcceptedBlocks)/\(c.backendAcceptedFrames) · ownerReturnedBlocks \(c.ownerReturnedBlocks)",
                              "startedTasks \(c.startedTasks) · validatedFinalTasks \(c.validatedFinalTasks) · validatedFinalFrames \(c.validatedFinalFrames) · canonicalAccountingValid \(c.canonicalAccountingValid) · queueAccountingValid \(c.queueAccountingValid) · ownerQueueAccountingValid \(c.ownerQueueAccountingValid) · completionCoverageValid \(c.completionCoverageValid)"]
                    if let q = c.queue { lines += ["queue accepted \(q.acceptedBlocks) · consumed \(q.consumedBlocks) · released \(q.releasedBlocks) · queued \(q.queuedBlocks) · releasedWithoutTransfer \(c.releasedWithoutTransferBlocks.map { String($0) } ?? "nil")"] }
                }
            } else { lines += ["canonical global timeline: unavailable（历史未提供，不补造）"] }
            if let failure = attempt.failure { lines += ["失败：" + failure] }
        }
        lines += ["", "## 本地资料上下文（未发送给模型）"]
        for material in session.materials {
            lines += ["", "### \(material.fileName)", "SHA256：\(material.sha256)", "", material.text]
        }
        lines += ["", "## 随记修订历史"]
        for version in session.noteHistory {
            lines += ["", "### 随记 r\(version.revision) · \(ISO8601DateFormatter().string(from: version.savedAt))", "", version.text]
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }
    // Export never overwrites any existing file, even one selected accidentally.
    public static func export(_ session: LocalSession, format: NoteExportFormat, to url: URL) throws {
        let bytes = try exportData(session, format: format)
        try bytes.write(to: url, options: .withoutOverwriting)
        guard try Data(contentsOf: url) == bytes else { throw CocoaError(.fileReadCorruptFile) }
        if format == .json {
            guard try JSONDecoder().decode(LocalSession.self, from: bytes) == session else { throw CocoaError(.fileReadCorruptFile) }
        }
    }
}
