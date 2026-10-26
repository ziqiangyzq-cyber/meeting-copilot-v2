import Foundation
import Combine
import CryptoKit
import Darwin
import MeetingCopilotCore
import APIIntelligence

public struct MeetingDraft: Codable, Equatable, Identifiable {
    public var id: String { job.jobID }
    public let createdAt: Date
    public let sessionTitle: String
    public let sourceFingerprint: String
    public let endpointHost: String
    public let modelID: String
    public let job: APIIntelligenceJob
    public let content: DerivedIntelligenceContent

    public var markdown: String {
        var result = "# \(sessionTitle)\n\nAI 草稿 · 请核对原文\n\n"
        if let question = job.question { result += "问题：\(question)\n\n" }
        result += content.draft + "\n\n"
        for action in content.actionItems {
            result += "- \(action.text)（负责人：\(action.owner ?? "未明确")；期限：\(action.dueDate ?? "未明确")）[\(action.citationIDs.joined(separator: ", "))]\n"
        }
        result += "\n## 来源快照\n\n"
        for source in job.sources {
            result += "[\(source.citationID)] \(source.text)\n\n"
        }
        return result
    }
}

private struct MeetingDraftArchive: Codable, Equatable {
    var version = 1
    var generation = 0
    var drafts: [MeetingDraft] = []
}

/// A separate durable file: generation never overwrites human notes or transcripts.
public final class MeetingDraftStore {
    public let fileURL: URL
    private var archive: MeetingDraftArchive
    public init(directory: URL) throws {
        fileURL = directory.appendingPathComponent("meeting-drafts.json")
        archive = try Self.load(fileURL)
    }
    private static func load(_ url: URL) throws -> MeetingDraftArchive {
        guard FileManager.default.fileExists(atPath: url.path) else { return MeetingDraftArchive() }
        let data = try JSONDecoder().decode(MeetingDraftArchive.self, from: Data(contentsOf: url))
        guard data.version == 1 else { throw StoreError.unsupportedSchema }
        return data
    }
    public var drafts: [MeetingDraft] { archive.drafts }
    public func append(_ draft: MeetingDraft) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = Darwin.open(fileURL.appendingPathExtension("lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw StoreError.busy }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw StoreError.busy }
        defer { flock(fd, LOCK_UN) }
        let disk = try Self.load(fileURL)
        guard disk.generation == archive.generation else { throw StoreError.conflict }
        if archive.drafts.contains(where: { $0.id == draft.id }) { return }
        var next = archive
        next.generation += 1
        next.drafts.append(draft)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try Data(contentsOf: fileURL).write(to: fileURL.appendingPathExtension("backup"), options: .atomic)
        }
        try encoder.encode(next).write(to: fileURL, options: .atomic)
        guard try Self.load(fileURL) == next else { throw CocoaError(.fileReadCorruptFile) }
        archive = next
    }
}

public struct MeetingSourceSnapshot: Equatable {
    public let sessionID: String
    public let title: String
    public let fingerprint: String
    public let binding: RevisionBinding
    public let notes: String
    public let sources: [CitationSnapshot]

    public init(session: LocalSession, includeMaterials: Bool) {
        sessionID = session.id; title = session.title; notes = session.notes
        binding = RevisionBinding(sessionID: session.id,
            transcriptRevision: session.segments.reduce(0) { $0 + ($1.current?.revision ?? 0) },
            noteRevision: session.noteHistory.last?.revision ?? 0)
        var snapshots: [CitationSnapshot] = []
        for segment in session.chronologicalSegments {
            guard let source = segment.current, source.status != "partial",
                  !source.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            snapshots.append(CitationSnapshot(citationID: "T\(snapshots.count + 1)", sourceID: segment.id,
                sourceRevision: source.revision,
                text: "原文段 \(session.segments.firstIndex(where: { $0.id == segment.id }).map { $0 + 1 } ?? 0)\n" + source.text))
        }
        if !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            snapshots.append(CitationSnapshot(citationID: "N1", sourceID: "notes:" + session.id,
                sourceRevision: binding.noteRevision, text: notes))
        }
        if includeMaterials {
            for (index, material) in session.materials.enumerated() {
                guard !material.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                snapshots.append(CitationSnapshot(citationID: "M\(index + 1)", sourceID: material.id,
                    sourceRevision: 0, text: "资料：\(material.fileName)\n\(material.text)"))
            }
        }
        sources = snapshots
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(snapshots)) ?? Data()
        fingerprint = SHA256.hash(data: Data((session.id + "\n" + session.title + "\n" + notes + "\n").utf8) + data)
            .map { String(format: "%02x", $0) }.joined()
    }
    public func job(kind: IntelligenceRequestKind, question: String) -> APIIntelligenceJob {
        APIIntelligenceJob(jobID: UUID().uuidString, binding: binding, kind: kind,
            originalNotes: notes, sources: sources, language: "zh-Hans",
            question: kind == .questionAnswer ? question : nil)
    }
}

@MainActor public final class MeetingIntelligenceModel: ObservableObject {
    @Published public private(set) var drafts: [MeetingDraft] = []
    @Published public private(set) var unsavedDraft: MeetingDraft?
    @Published public private(set) var running = false
    @Published public private(set) var status = "选择会话后，可生成中文纪要、行动项或向记录提问。"
    @Published public private(set) var error: String?
    private var store: MeetingDraftStore?
    private var activeSnapshot: MeetingSourceSnapshot?
    private var ticket: UUID?
    private var cancellation: APICancellationToken?
    private var task: Task<Void, Never>?

    public init(directory: URL) {
        do { let loaded = try MeetingDraftStore(directory: directory); store = loaded; drafts = loaded.drafts }
        catch { self.error = "AI 草稿记录读取失败，已停止写入，请保留原文件。" }
    }
    public func records(sessionID: String) -> [MeetingDraft] {
        drafts.filter { $0.job.binding.sessionID == sessionID }.reversed()
    }
    public func contextChanged(_ snapshot: MeetingSourceSnapshot?) {
        guard activeSnapshot != snapshot else { return }
        activeSnapshot = snapshot
        if running { cancel(message: "会话或输入内容已改变，旧请求已取消；请重新生成。") }
    }
    public func cancel(message: String = "生成已取消，原记录与已有草稿保留。") {
        cancellation?.cancel(); task?.cancel(); ticket = nil; running = false; status = message
    }
    public func preflight(snapshot: MeetingSourceSnapshot, kind: IntelligenceRequestKind,
                          question: String, configuration: APIIntelligenceConfiguration) -> Bool {
        guard store != nil, unsavedDraft == nil else {
            error = "请先处理未保存草稿或读取错误，再生成新内容。"; return false
        }
        guard snapshot.sources.count <= 512 else {
            error = "当前会话超过 512 条来源上限，请按议题拆分记录后生成。原文不会被截断，未发送请求。"; return false
        }
        do {
            let job = snapshot.job(kind: kind, question: question)
            try configuration.validate(); try job.validate()
            guard try JSONEncoder().encode(job).count <= configuration.maximumInputBytes else {
                error = "当前会话超过 \(configuration.maximumInputBytes / 1000) KB 请求上限，请按议题拆分记录或取消附带资料。原文不会被截断，未发送请求。"
                return false
            }
            error = nil; return true
        } catch { self.error = Self.message(error); return false }
    }
    public func start(snapshot: MeetingSourceSnapshot, kind: IntelligenceRequestKind, question: String,
                      configuration: APIIntelligenceConfiguration,
                      credentials: any APICredentialProvider = KeychainBackendCredentialStore(),
                      transport: any APIHTTPTransport = URLSessionAPITransport()) {
        guard !running else { return }
        contextChanged(snapshot)
        guard preflight(snapshot: snapshot, kind: kind, question: question, configuration: configuration) else { return }
        error = nil
        let requestTicket = UUID(), token = APICancellationToken()
        ticket = requestTicket; cancellation = token; running = true; status = "正在生成…"
        task = Task {
            do {
                let job = snapshot.job(kind: kind, question: question)
                try job.validate()
                let adapter = try OpenAIChatIntelligenceAdapter(configuration: configuration,
                    credentials: credentials, transport: transport)
                try await adapter.updateCurrentBinding(job.binding)
                let result = try await adapter.perform(job, cancellationToken: token)
                guard ticket == requestTicket, activeSnapshot == snapshot, !token.isCancelled else { return }
                let record = MeetingDraft(createdAt: Date(), sessionTitle: snapshot.title,
                    sourceFingerprint: snapshot.fingerprint, endpointHost: configuration.baseURL.host ?? "",
                    modelID: configuration.modelID, job: result.job, content: result.generatedDraft)
                do { try store?.append(record); drafts = store?.drafts ?? []; status = "AI 草稿已保存并回读确认，请核对来源。" }
                catch {
                    unsavedDraft = record
                    self.error = "生成完成，但保存失败；可复制或导出草稿，或重试保存。"
                    status = "草稿尚未保存"
                }
            } catch {
                guard ticket == requestTicket else { return }
                self.error = Self.message(error); status = "生成未完成，原记录和已有草稿保留。"
            }
            if ticket == requestTicket { running = false; ticket = nil }
        }
    }
    public func retrySave() {
        guard let unsavedDraft, let store else { return }
        do {
            try store.append(unsavedDraft); drafts = store.drafts; self.unsavedDraft = nil
            error = nil; status = "AI 草稿已保存并回读确认。"
        } catch { self.error = "草稿保存仍失败，请复制或导出后重新打开。" }
    }
    public func reportConfigurationError() { error = "B 配置无效，请在设置中测试并保存地址、模型和密钥。未发送请求。" }
    public static func message(_ error: Error) -> String {
        guard let error = error as? APIIntelligenceError else { return "生成失败，请检查网络与 B 配置后重试。" }
        switch error {
        case .inputLimit: return "记录超过当前请求上限，请拆分会话或取消附带资料。未截断原文。"
        case .invalidJob: return "请先保存有效原文或随记；提问时请输入问题。"
        case .invalidConfiguration, .unsupportedProtocol: return "B 配置无效，请重新测试并保存。"
        case .missingCredential: return "无法取得 API 密钥，请检查钥匙串或重新保存密钥。"
        case .cancelled, .staleResponse: return "请求已取消或记录已改变，请重新生成。"
        case .httpRejected(let status): return "API 服务拒绝请求（HTTP \(status)），请检查 B 配置和额度。"
        case .timedOut: return "API 请求超时，请稍后重试。"
        case .invalidCitation: return "返回内容的来源引用无效，草稿未保存。"
        case .incompleteResponse: return "返回内容不完整，草稿未保存；可缩短输入后重试。"
        case .refused: return "API 服务未生成草稿。"
        case .transportFailure: return "无法连接 API 服务，请检查网络后重试。"
        default: return "服务返回内容格式不符合要求，草稿未保存，请重试或更换模型。"
        }
    }
}
