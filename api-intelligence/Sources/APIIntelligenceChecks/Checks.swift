import Foundation
import CryptoKit
import APIIntelligence

private struct CheckFailure: Error { let label: String }
private func require(_ value: Bool, _ label: String) throws { if !value { throw CheckFailure(label: label) } }
@MainActor private func expect(_ error: APIIntelligenceError, _ block: () async throws -> Void) async throws {
    do { try await block(); throw CheckFailure(label: "expected_\(error)") }
    catch let actual as APIIntelligenceError { try require(actual == error, "wrong_error_\(actual)") }
}
private struct FixtureCredentials: APICredentialProvider {
    let missing: Bool
    func credential(for reference: String) async throws -> String {
        if missing { return "" }
        guard reference == "fixture-reference" else { throw APIIntelligenceError.missingCredential }
        return "synthetic-placeholder-not-a-secret"
    }
}
private actor MockTransport: APIHTTPTransport {
    enum Mode: Sendable {
        case success, invalidCitation, wrongRevision, badSchema, incomplete, refusal, badEnvelope
        case http(Int), oversize, late(Double)
    }
    let mode: Mode
    var calls = 0
    var requestContractOK = true
    var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ mode: Mode = .success) { self.mode = mode }
    func waitUntilCalled() async {
        if calls > 0 { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> APIHTTPResponse {
        calls += 1
        waiters.forEach { $0.resume() }; waiters.removeAll()
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as! [String: Any]
        let messages = body["messages"] as! [[String: String]]
        let job = try JSONDecoder().decode(APIIntelligenceJob.self, from: Data(messages[1]["content"]!.utf8))
        requestContractOK = requestContractOK && request.httpMethod == "POST" &&
            request.url?.absoluteString == "https://api.example.invalid/v1/chat/completions" &&
            body["model"] as? String == "unverified-model" && body["stream"] as? Bool == false &&
            request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-placeholder-not-a-secret" &&
            messages[0]["role"] == "system" && messages[1]["role"] == "user"
        if case .late(let delay) = mode {
            // Deliberately ignores Task cancellation. Proves timeout returns without waiting on it.
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) { continuation.resume() }
            }
        }
        if case .http(let code) = mode { return .init(statusCode: code, body: Data("DO_NOT_LOG_SERVER_BODY".utf8)) }
        if case .oversize = mode { return .init(statusCode: 200, body: Data(repeating: 65, count: maximumResponseBytes + 1)) }
        if case .badEnvelope = mode { return .init(statusCode: 200, body: Data("not JSON".utf8)) }
        var binding = job.binding
        if case .wrongRevision = mode {
            binding = .init(sessionID: binding.sessionID, transcriptRevision: binding.transcriptRevision + 1, noteRevision: binding.noteRevision)
        }
        let ids = { if case .invalidCitation = mode { return ["not-supplied"] }; return [job.sources[0].citationID] }()
        let actions: [DerivedActionItem] = job.kind == .actionItems ? [.init(text: "预算待确认", owner: nil, dueDate: nil, citationIDs: ids)] : []
        struct Payload: Encodable { let jobID: String; let binding: RevisionBinding; let content: DerivedIntelligenceContent }
        let content = DerivedIntelligenceContent(kind: job.kind, draft: "合成API协议检查稿，非真实生成", citationIDs: ids, actionItems: actions)
        var text = String(decoding: try JSONEncoder().encode(Payload(jobID: job.jobID, binding: binding, content: content)), as: UTF8.self)
        if case .badSchema = mode { text = "{\"draft\":\"unbound\"}" }
        var finish = "stop"
        if case .incomplete = mode { finish = "length" }
        var message: [String: Any] = ["role": "assistant", "content": text]
        if case .refusal = mode { message["refusal"] = "fixture refusal" }
        let envelope: [String: Any] = ["choices": [["message": message, "finish_reason": finish]]]
        return .init(statusCode: 200, body: try JSONSerialization.data(withJSONObject: envelope))
    }
}

private actor HeldCredentials: APICredentialProvider {
    var started = false
    var calls = 0
    private var waiters: [CheckedContinuation<String, Never>] = []
    func credential(for reference: String) async throws -> String {
        started = true; calls += 1
        return await withCheckedContinuation { waiters.append($0) }
    }
    func release() { waiters.forEach { $0.resume(returning: "synthetic-placeholder-not-a-secret") }; waiters.removeAll() }
}
private actor HeldLookup: LocalContextLookup {
    var started = false
    private var waiter: CheckedContinuation<[RetrievalCandidate], Never>?
    func lookup(query: String, binding: RevisionBinding) async throws -> [RetrievalCandidate] {
        started = true
        return await withCheckedContinuation { waiter = $0 }
    }
    func release(_ values: [RetrievalCandidate]) { waiter?.resume(returning: values); waiter = nil }
}
private actor CountingReranker: OptionalAPIReranker {
    var calls = 0
    func rerank(query: String, candidates: [RetrievalCandidate], binding: RevisionBinding) async throws -> [RankedCitation] {
        calls += 1
        return candidates.map { RankedCitation(citationID: $0.source.citationID, score: 1) }
    }
}

private struct FixtureLookup: LocalContextLookup {
    let values: [RetrievalCandidate]
    func lookup(query: String, binding: RevisionBinding) async throws -> [RetrievalCandidate] { values }
}
private struct FixtureReranker: OptionalAPIReranker {
    let invalid: Bool
    func rerank(query: String, candidates: [RetrievalCandidate], binding: RevisionBinding) async throws -> [RankedCitation] {
        candidates.map { RankedCitation(citationID: invalid ? "not-supplied" : $0.source.citationID, score: 1) }
    }
}

@main struct APIIntelligenceChecks {
    static func main() async throws {
        guard CommandLine.arguments.count == 2, CommandLine.arguments[1].hasPrefix("/") else {
            throw CheckFailure(label: "usage: APIIntelligenceChecks /absolute/writable/acceptance-dir")
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("synthetic-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let binding = RevisionBinding(sessionID: "synthetic-session", transcriptRevision: 4, noteRevision: 2)
        let source = CitationSnapshot(citationID: "source-001:rev4:line2", sourceID: "source-001", sourceRevision: 4, text: "不要取消合同，预算与负责人待确认。")
        func job(_ kind: IntelligenceRequestKind = .minutes) -> APIIntelligenceJob {
            .init(jobID: UUID().uuidString, binding: binding, kind: kind, originalNotes: "原始合成笔记不得改写。",
                  sources: [source], language: "zh", question: kind == .questionAnswer ? "负责人确认了吗？" : nil)
        }
        let original = job()
        let fixture = root.appendingPathComponent("original-snapshot.json")
        try JSONEncoder().encode(original).write(to: fixture, options: [.withoutOverwriting])
        func hash() throws -> String { SHA256.hash(data: try Data(contentsOf: fixture)).map { String(format: "%02x", $0) }.joined() }
        let before = try hash()
        func config(timeout: Double = 1, protocolID: String = "openai-chat-completions") -> APIIntelligenceConfiguration {
            .init(baseURL: URL(string: "https://api.example.invalid/v1")!, modelID: "unverified-model",
                  credentialReference: "fixture-reference", protocolID: protocolID, timeoutSeconds: timeout)
        }
        func adapter(_ mock: MockTransport, timeout: Double = 1, missing: Bool = false) async throws -> OpenAIChatIntelligenceAdapter {
            let value = try OpenAIChatIntelligenceAdapter(configuration: config(timeout: timeout), credentials: FixtureCredentials(missing: missing), transport: mock)
            try await value.updateCurrentBinding(binding)
            return value
        }
        var passed: [String] = []
        let success = MockTransport()
        let normal = try await adapter(success)
        for kind in [IntelligenceRequestKind.minutes, .actionItems, .questionAnswer] {
            let input = job(kind)
            let output = try await normal.perform(input)
            try require(output.job == input && output.generatedDraft.kind == kind, "bound_snapshot_result")
            try require(output.generatedDraft.citationIDs == [source.citationID], "citation_binding")
            if kind == .actionItems { try require(output.generatedDraft.actionItems[0].owner == nil && output.generatedDraft.actionItems[0].dueDate == nil, "unknown_owner_date") }
        }
        let requestOK = await success.requestContractOK
        try require(requestOK, "wire_request_contract")
        passed.append("minutes_actions_qa_bound_snapshots_and_mock_wire")
        try await expect(.unsupportedProtocol("responses")) { _ = try OpenAIChatIntelligenceAdapter(configuration: config(protocolID: "responses"), credentials: FixtureCredentials(missing: false), transport: success) }
        passed.append("unsupported_protocol_explicit")
        let invalid = APIIntelligenceJob(jobID: "", binding: binding, kind: .questionAnswer, originalNotes: "", sources: [], language: "zh")
        try await expect(.invalidJob) { _ = try await normal.perform(invalid) }
        let tiny = APIIntelligenceConfiguration(baseURL: config().baseURL, modelID: "unverified-model", credentialReference: "fixture-reference", maximumInputBytes: 1)
        let limited = try OpenAIChatIntelligenceAdapter(configuration: tiny, credentials: FixtureCredentials(missing: false), transport: success)
        try await limited.updateCurrentBinding(binding)
        try await expect(.inputLimit) { _ = try await limited.perform(original) }
        passed.append("bad_input_and_input_limit")
        let noCredentialMock = MockTransport()
        let missing = try await adapter(noCredentialMock, missing: true)
        try await expect(.missingCredential) { _ = try await missing.perform(original) }
        let missingCalls = await noCredentialMock.calls
        try require(missingCalls == 0, "missing_credential_no_send")
        passed.append("missing_credential_no_send")
        for (mode, expected) in [(MockTransport.Mode.invalidCitation, APIIntelligenceError.invalidCitation),
                                 (.wrongRevision, .staleResponse), (.badSchema, .invalidResponse),
                                 (.incomplete, .incompleteResponse), (.refusal, .refused),
                                 (.badEnvelope, .invalidResponse), (.oversize, .responseLimit),
                                 (.http(429), .httpRejected(status: 429)), (.http(302), .httpRejected(status: 302))] {
            let value = try await adapter(MockTransport(mode))
            try await expect(expected) { _ = try await value.perform(original) }
        }
        passed.append("invalid_citation_revision_schema_partial_refusal_size_http")
        let preToken = APICancellationToken(); preToken.cancel()
        let preMock = MockTransport()
        let pre = try await adapter(preMock)
        try await expect(.cancelled) { _ = try await pre.perform(original, cancellationToken: preToken) }
        let preCalls = await preMock.calls
        try require(preCalls == 0, "pre_cancel_no_send")
        passed.append("pre_cancel_zero_send")
        let midMock = MockTransport(.late(0.15))
        let mid = try await adapter(midMock)
        let midToken = APICancellationToken()
        let midTask = Task { try await mid.perform(original, cancellationToken: midToken) }
        await midMock.waitUntilCalled(); midToken.cancel()
        try await expect(.cancelled) { _ = try await midTask.value }
        passed.append("inflight_cancel_noncooperative_late_transport")
        let taskMock = MockTransport(.late(0.15))
        let taskAdapter = try await adapter(taskMock)
        let cancelledTask = Task { try await taskAdapter.perform(original) }
        await taskMock.waitUntilCalled(); cancelledTask.cancel()
        try await expect(.cancelled) { _ = try await cancelledTask.value }
        passed.append("task_cancel")
        let timeoutMock = MockTransport(.late(0.15))
        let short = try await adapter(timeoutMock, timeout: 0.015)
        let start = Date()
        try await expect(.timedOut) { _ = try await short.perform(original) }
        try require(Date().timeIntervalSince(start) < 0.12, "timeout_did_not_wait_for_late_worker")
        passed.append("timeout_discards_late_result")
        let staleMock = MockTransport(.late(0.05))
        let stale = try await adapter(staleMock)
        let staleTask = Task { try await stale.perform(original) }
        await staleMock.waitUntilCalled()
        try await stale.updateCurrentBinding(.init(sessionID: binding.sessionID, transcriptRevision: 5, noteRevision: 3))
        try await expect(.staleResponse) { _ = try await staleTask.value }
        passed.append("revision_update_rejects_late_response")
        let supersedeMock = MockTransport(.late(0.05))
        let supersede = try await adapter(supersedeMock)
        let old = Task { try await supersede.perform(original) }
        await supersedeMock.waitUntilCalled()
        _ = try await supersede.perform(job())
        try await expect(.staleResponse) { _ = try await old.value }
        passed.append("new_job_rejects_old_job")
        for mode in ["revision", "deactivate", "token", "task", "timeout", "supersede"] {
            let held = HeldCredentials(), mock = MockTransport()
            let token = APICancellationToken()
            let value = try OpenAIChatIntelligenceAdapter(configuration: config(timeout: mode == "timeout" ? 0.02 : 1), credentials: held, transport: mock)
            try await value.updateCurrentBinding(binding)
            let pending = Task { try await value.perform(original, cancellationToken: token) }
            while !(await held.started) { await Task.yield() }
            let expected: APIIntelligenceError
            switch mode {
            case "revision":
                try await value.updateCurrentBinding(.init(sessionID: binding.sessionID, transcriptRevision: 5, noteRevision: 2)); expected = .staleResponse
            case "deactivate": await value.deactivate(); expected = .staleResponse
            case "token": token.cancel(); expected = .cancelled
            case "task": pending.cancel(); expected = .cancelled
            case "timeout": expected = .timedOut
            default:
                // A new request supersedes the held one, even if its own credential is absent.
                let newer = Task { try await value.perform(job(), cancellationToken: token) }
                while await held.calls < 2 { await Task.yield() }
                newer.cancel()
                _ = try? await newer.value
                expected = .staleResponse
            }
            try await expect(expected) { _ = try await pending.value }
            await held.release()
            try await Task.sleep(for: .milliseconds(30))
            let sends = await mock.calls
            try require(sends == 0, "held_credentials_\(mode)_must_never_send")
        }
        passed.append("credential_wait_revision_deactivate_token_task_timeout_supersede_zero_send")
        try await expect(.unsupportedCapability("rerank_not_configured")) { _ = try await UnconfiguredAPIReranker().rerank(query: "合成", candidates: [], binding: binding) }
        try await expect(.unsupportedCapability("embedding_not_configured")) { _ = try await UnconfiguredAPIEmbedder().embed(texts: ["合成"], binding: binding) }
        passed.append("rerank_embedding_unconfigured_fail_closed")
        let candidate = RetrievalCandidate(source: source, location: "synthetic-file:line2")
        let lookup = FixtureLookup(values: [candidate])
        let localOnly = try ContextRetrievalCoordinator(local: lookup)
        let retrieved = try await localOnly.retrieve(query: "合成", binding: binding)
        try require(retrieved.binding == binding && retrieved.candidates == [candidate] && !retrieved.reranked, "local_lookup_contract")
        let rerank = try ContextRetrievalCoordinator(local: lookup, optionalReranker: FixtureReranker(invalid: false))
        let ranked = try await rerank.retrieve(query: "合成", binding: binding)
        try require(ranked.reranked && ranked.candidates == [candidate], "rerank_contract")
        let badRanking = try ContextRetrievalCoordinator(local: lookup, optionalReranker: FixtureReranker(invalid: true))
        try await expect(.invalidCitation) { _ = try await badRanking.retrieve(query: "合成", binding: binding) }
        let emptyLookup = try ContextRetrievalCoordinator(local: FixtureLookup(values: []))
        try await expect(.invalidResponse) { _ = try await emptyLookup.retrieve(query: "合成", binding: binding) }
        passed.append("injected_local_lookup_and_optional_rerank_contract_only")
        for timeoutCase in [true, false] {
            let held = HeldLookup(), counting = CountingReranker(), token = APICancellationToken()
            let retrieval = try ContextRetrievalCoordinator(local: held, optionalReranker: counting, timeoutSeconds: timeoutCase ? 0.02 : 1)
            let pending = Task { try await retrieval.retrieve(query: "合成", binding: binding, cancellationToken: token) }
            while !(await held.started) { await Task.yield() }
            if !timeoutCase { token.cancel() }
            try await expect(timeoutCase ? .timedOut : .cancelled) { _ = try await pending.value }
            await held.release([candidate])
            try await Task.sleep(for: .milliseconds(30))
            let calls = await counting.calls
            try require(calls == 0, "late_lookup_must_not_rerank")
        }
        passed.append("noncooperative_lookup_timeout_cancel_no_late_rerank")
        try await Task.sleep(for: .milliseconds(180))
        let after = try hash()
        try require(before == after, "original_snapshot_sha256_changed")
        passed.append("original_snapshot_sha256_unchanged")
        let output: [String: Any] = ["passed": true, "checks": passed, "check_count": passed.count,
            "original_fixture": fixture.path, "sha256_before": before, "sha256_after": after,
            "real_api_calls": 0, "real_credentials_read": 0,
            "scope": "Offline injected transport and synthetic credentials only; no URLSession transport instantiated; API compatibility and model output quality not verified"]
        print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
