import Foundation
import ClientRuntime
import MeetingCopilotCore
import APIIntelligence

struct CheckError: Error { let message: String }
func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    guard value() else { throw CheckError(message: message) }
}
struct TestCredential: APICredentialProvider {
    func credential(for reference: String) async throws -> String { "fixture-secret-never-persist" }
}
actor TestTransport: APIHTTPTransport {
    enum Mode { case good, invalidCitation, unauthorized, delayed }
    let mode: Mode
    var jobs: [APIIntelligenceJob] = []
    init(_ mode: Mode) { self.mode = mode }
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> APIHTTPResponse {
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let messages = body["messages"] as! [[String: String]]
        let job = try JSONDecoder().decode(APIIntelligenceJob.self, from: Data(messages[1]["content"]!.utf8))
        jobs.append(job)
        if mode == .delayed { try? await Task.sleep(nanoseconds: 180_000_000) }
        if mode == .unauthorized { return APIHTTPResponse(statusCode: 401, body: Data()) }
        let citation = mode == .invalidCitation ? "UNKNOWN" : job.sources[0].citationID
        let content = DerivedIntelligenceContent(kind: job.kind, draft: "会议草稿：请核对来源", citationIDs: [citation],
            actionItems: job.kind == .actionItems ? [.init(text: "确认样板", owner: nil, dueDate: nil, citationIDs: [citation])] : [])
        struct Bound: Encodable { let jobID: String; let binding: RevisionBinding; let content: DerivedIntelligenceContent }
        let bound = try JSONEncoder().encode(Bound(jobID: job.jobID, binding: job.binding, content: content))
        let envelope: [String: Any] = ["choices": [["message": ["role": "assistant", "content": String(decoding: bound, as: UTF8.self)], "finish_reason": "stop"]]]
        return APIHTTPResponse(statusCode: 200, body: try JSONSerialization.data(withJSONObject: envelope))
    }
}

@main struct MeetingIntelligenceChecks {
    @MainActor static func wait(_ model: MeetingIntelligenceModel) async throws {
        let deadline = Date().addingTimeInterval(4)
        while model.running && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        try require(!model.running, "request did not settle")
    }
    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/meeting-intelligence-checks-" + UUID().uuidString)
        let configuration = APIIntelligenceConfiguration(baseURL: URL(string: "https://fixture.invalid/v1")!, modelID: "fixture-model", credentialReference: "FIXTURE")
        var session = LocalSession(title: "验收会议", notes: "金额尚未确认", segments: [
            LocalSegment(id: "seg-1", revisions: [.init(revision: 1, text: "We need to confirm the sample.")]),
            LocalSegment(id: "seg-partial", revisions: [.init(revision: 1, text: "未完成", status: "partial")])])
        session.materials = [LocalMaterial(fileName: "background.md", text: "本地资料", sha256: "fixture")]
        let original = session
        let model = MeetingIntelligenceModel(directory: directory)
        let snapshot = MeetingSourceSnapshot(session: session, includeMaterials: false)
        try require(snapshot.sources.count == 2 && !snapshot.sources.contains { $0.text == "未完成" }, "sources should omit partial and unselected materials")
        let transport = TestTransport(.good)
        for kind in [IntelligenceRequestKind.minutes, .actionItems, .questionAnswer] {
            model.start(snapshot: snapshot, kind: kind, question: "哪些事项确定？", configuration: configuration, credentials: TestCredential(), transport: transport)
            try await wait(model)
            try require(model.error == nil, "generation failed")
        }
        try require(model.drafts.count == 3 && session == original, "generation must preserve all original data")
        let reloaded = MeetingIntelligenceModel(directory: directory)
        try require(reloaded.drafts == model.drafts, "saved drafts did not reopen exactly")
        let disk = try String(contentsOf: directory.appendingPathComponent("meeting-drafts.json"), encoding: .utf8)
        try require(!disk.contains("fixture-secret-never-persist"), "secret persisted")
        try require(model.drafts.last!.markdown.contains("未明确") == false, "question should not invent actions")
        try require(model.drafts[1].markdown.contains("负责人：未明确") && model.drafts[1].markdown.contains("[T1]"), "action owner/citation missing")
        print("PASS minutes/actions/question generation, original preservation, persisted reopen, no secret, citation export")

        model.start(snapshot: snapshot, kind: .minutes, question: "", configuration: configuration, credentials: TestCredential(), transport: TestTransport(.invalidCitation))
        try await wait(model)
        try require(model.drafts.count == 3 && model.error?.contains("引用无效") == true, "invalid citation accepted")
        model.start(snapshot: snapshot, kind: .minutes, question: "", configuration: configuration, credentials: TestCredential(), transport: TestTransport(.unauthorized))
        try await wait(model)
        try require(model.drafts.count == 3 && model.error?.contains("401") == true, "HTTP error should not overwrite draft")
        print("PASS invalid citation and HTTP failure retain previous drafts")

        model.start(snapshot: snapshot, kind: .minutes, question: "", configuration: configuration, credentials: TestCredential(), transport: TestTransport(.delayed))
        try await Task.sleep(nanoseconds: 30_000_000)
        session.segments[0].revisions.append(.init(revision: 2, text: "Changed source", status: "corrected"))
        model.contextChanged(MeetingSourceSnapshot(session: session, includeMaterials: false))
        try await Task.sleep(nanoseconds: 250_000_000)
        try require(model.drafts.count == 3 && !model.running, "late result overwrote changed source")
        model.start(snapshot: snapshot, kind: .minutes, question: "", configuration: configuration, credentials: TestCredential(), transport: TestTransport(.delayed))
        try await Task.sleep(nanoseconds: 30_000_000)
        model.contextChanged(MeetingSourceSnapshot(session: LocalSession(title: "Other session"), includeMaterials: false))
        try await Task.sleep(nanoseconds: 250_000_000)
        try require(model.drafts.count == 3, "late result bound to wrong session")
        model.start(snapshot: snapshot, kind: .minutes, question: "", configuration: configuration, credentials: TestCredential(), transport: TestTransport(.delayed))
        model.cancel()
        try await Task.sleep(nanoseconds: 250_000_000)
        try require(model.drafts.count == 3, "cancelled generation persisted")
        print("PASS transcript edit, session switch and cancellation discard late result")

        let withMaterials = MeetingSourceSnapshot(session: session, includeMaterials: true)
        try require(withMaterials.sources.contains { $0.citationID == "M1" }, "selected materials not included")
        let conflict = MeetingIntelligenceModel(directory: directory)
        model.start(snapshot: withMaterials, kind: .minutes, question: "", configuration: configuration, credentials: TestCredential(), transport: transport)
        try await wait(model)
        conflict.start(snapshot: withMaterials, kind: .minutes, question: "", configuration: configuration, credentials: TestCredential(), transport: transport)
        try await wait(conflict)
        try require(conflict.unsavedDraft != nil && conflict.error?.contains("保存失败") == true, "save conflict must expose copyable unsaved result")
        let corruptDirectory = directory.appendingPathComponent("corrupt")
        try FileManager.default.createDirectory(at: corruptDirectory, withIntermediateDirectories: true)
        try Data("invalid original".utf8).write(to: corruptDirectory.appendingPathComponent("meeting-drafts.json"))
        let corrupt = MeetingIntelligenceModel(directory: corruptDirectory)
        corrupt.start(snapshot: snapshot, kind: .minutes, question: "", configuration: configuration, credentials: TestCredential(), transport: transport)
        try require(!corrupt.running && corrupt.error != nil, "corrupt archive should block generation")
        let preserved = try String(contentsOf: corruptDirectory.appendingPathComponent("meeting-drafts.json"), encoding: .utf8)
        try require(preserved == "invalid original", "corrupt original overwritten")
        print("PASS opt-in materials, conflict preserves copyable draft, corrupt archive preserved")
        let beforeLimitCalls = await transport.jobs.count
        let tiny = APIIntelligenceConfiguration(baseURL: configuration.baseURL, modelID: "fixture-model",
            credentialReference: "FIXTURE", maximumInputBytes: 32)
        model.start(snapshot: snapshot, kind: .minutes, question: "", configuration: tiny, credentials: TestCredential(), transport: transport)
        try require(!model.running && model.error?.contains("不会被截断") == true, "oversized input should be rejected before request")
        let many = LocalSession(title: "长会议", segments: (0..<513).map { LocalSegment(id: "long-\($0)", revisions: [.init(revision: 1, text: "会议原文 \($0)")]) })
        model.start(snapshot: MeetingSourceSnapshot(session: many, includeMaterials: false), kind: .minutes,
            question: "", configuration: configuration, credentials: TestCredential(), transport: transport)
        try require(!model.running && model.error?.contains("512") == true, "source cap should have clear message")
        let afterLimitCalls = await transport.jobs.count
        try require(beforeLimitCalls == afterLimitCalls, "limit rejection sent request")
        print("PASS long meeting byte/source limits reject locally without truncation or request")
        print("MEETING_INTELLIGENCE_CHECKS_COMPLETE")
    }
}
