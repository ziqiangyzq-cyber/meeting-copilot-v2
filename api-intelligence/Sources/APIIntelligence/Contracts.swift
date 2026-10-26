import Foundation

public enum APIIntelligenceError: Error, Equatable, Sendable {
    case invalidConfiguration
    case unsupportedProtocol(String)
    case invalidJob
    case inputLimit
    case missingCredential
    case transportFailure
    case httpRejected(status: Int)
    case responseLimit
    case invalidResponse
    case incompleteResponse
    case refused
    case invalidCitation
    case cancelled
    case timedOut
    case staleResponse
    case unsupportedCapability(String)
}

/// Stores a credential reference, never its secret value. Wire compatibility remains unverified.
public struct APIIntelligenceConfiguration: Sendable {
    public let baseURL: URL
    public let modelID: String
    public let credentialReference: String
    public let protocolID: String
    public let timeoutSeconds: Double
    public let maximumInputBytes: Int
    public let maximumResponseBytes: Int
    public let maximumOutputTokens: Int
    public let requestJSONMode: Bool
    public init(baseURL: URL, modelID: String, credentialReference: String,
                protocolID: String = "openai-chat-completions", timeoutSeconds: Double = 30,
                maximumInputBytes: Int = 128_000, maximumResponseBytes: Int = 256_000,
                maximumOutputTokens: Int = 2_000, requestJSONMode: Bool = false) {
        self.baseURL = baseURL; self.modelID = modelID; self.credentialReference = credentialReference
        self.protocolID = protocolID; self.timeoutSeconds = timeoutSeconds
        self.maximumInputBytes = maximumInputBytes; self.maximumResponseBytes = maximumResponseBytes
        self.maximumOutputTokens = maximumOutputTokens; self.requestJSONMode = requestJSONMode
    }
    public func validate() throws {
        guard protocolID == "openai-chat-completions" else { throw APIIntelligenceError.unsupportedProtocol(protocolID) }
        guard baseURL.scheme == "https", baseURL.host != nil,
              baseURL.user == nil, baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil,
              !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !credentialReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              timeoutSeconds.isFinite, timeoutSeconds > 0, timeoutSeconds <= 300,
              maximumInputBytes > 0, maximumInputBytes <= 2_000_000,
              maximumResponseBytes > 0, maximumResponseBytes <= 4_000_000,
              maximumOutputTokens > 0, maximumOutputTokens <= 16_000
        else { throw APIIntelligenceError.invalidConfiguration }
    }
}

public struct RevisionBinding: Codable, Equatable, Sendable {
    public let sessionID: String
    public let transcriptRevision: Int
    public let noteRevision: Int
    public init(sessionID: String, transcriptRevision: Int, noteRevision: Int) {
        self.sessionID = sessionID; self.transcriptRevision = transcriptRevision; self.noteRevision = noteRevision
    }
}
public struct CitationSnapshot: Codable, Equatable, Sendable {
    public let citationID: String
    public let sourceID: String
    public let sourceRevision: Int
    public let text: String
    public init(citationID: String, sourceID: String, sourceRevision: Int, text: String) {
        self.citationID = citationID; self.sourceID = sourceID; self.sourceRevision = sourceRevision; self.text = text
    }
}
public enum IntelligenceRequestKind: String, Codable, Sendable { case minutes, actionItems, questionAnswer }
public struct APIIntelligenceJob: Codable, Equatable, Sendable {
    public let jobID: String
    public let binding: RevisionBinding
    public let kind: IntelligenceRequestKind
    public let originalNotes: String
    public let sources: [CitationSnapshot]
    public let language: String
    public let question: String?
    public init(jobID: String, binding: RevisionBinding, kind: IntelligenceRequestKind,
                originalNotes: String, sources: [CitationSnapshot], language: String, question: String? = nil) {
        self.jobID = jobID; self.binding = binding; self.kind = kind; self.originalNotes = originalNotes
        self.sources = sources; self.language = language; self.question = question
    }
    public func validate() throws {
        guard !jobID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !binding.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              binding.transcriptRevision >= 0, binding.noteRevision >= 0,
              !language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !sources.isEmpty, sources.count <= 512,
              sources.allSatisfy({ !$0.citationID.isEmpty && !$0.sourceID.isEmpty && $0.sourceRevision >= 0 && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              Set(sources.map(\.citationID)).count == sources.count
        else { throw APIIntelligenceError.invalidJob }
        if kind == .questionAnswer {
            guard let question, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw APIIntelligenceError.invalidJob }
        } else if question != nil { throw APIIntelligenceError.invalidJob }
    }
}
public struct DerivedActionItem: Codable, Equatable, Sendable {
    public let text: String
    public let owner: String?
    public let dueDate: String?
    public let citationIDs: [String]
    public init(text: String, owner: String?, dueDate: String?, citationIDs: [String]) {
        self.text = text; self.owner = owner; self.dueDate = dueDate; self.citationIDs = citationIDs
    }
}
public struct DerivedIntelligenceContent: Codable, Equatable, Sendable {
    public let kind: IntelligenceRequestKind
    public let draft: String
    public let citationIDs: [String]
    public let actionItems: [DerivedActionItem]
    public init(kind: IntelligenceRequestKind, draft: String, citationIDs: [String], actionItems: [DerivedActionItem]) {
        self.kind = kind; self.draft = draft; self.citationIDs = citationIDs; self.actionItems = actionItems
    }
}
public struct APIIntelligenceResult: Codable, Equatable, Sendable {
    public let job: APIIntelligenceJob
    public let generatedDraft: DerivedIntelligenceContent
}

/// App should implement this with its secure credential store. No saved secret is read by this package.
public protocol APICredentialProvider: Sendable {
    func credential(for reference: String) async throws -> String
}
public struct APIHTTPResponse: Sendable {
    public let statusCode: Int
    public let body: Data
    public init(statusCode: Int, body: Data) { self.statusCode = statusCode; self.body = body }
}
public protocol APIHTTPTransport: Sendable {
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> APIHTTPResponse
}
public final class APICancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

/// Extension contracts only. No reranking/embeddings provider is selected or connected.
public struct RetrievalCandidate: Codable, Equatable, Sendable {
    public let source: CitationSnapshot
    public let location: String
    public init(source: CitationSnapshot, location: String) { self.source = source; self.location = location }
}
public struct RankedCitation: Codable, Equatable, Sendable {
    public let citationID: String
    public let score: Double
    public init(citationID: String, score: Double) { self.citationID = citationID; self.score = score }
}
public protocol LocalContextLookup: Sendable {
    func lookup(query: String, binding: RevisionBinding) async throws -> [RetrievalCandidate]
}
public protocol OptionalAPIReranker: Sendable {
    func rerank(query: String, candidates: [RetrievalCandidate], binding: RevisionBinding) async throws -> [RankedCitation]
}
public protocol OptionalAPIEmbedder: Sendable {
    func embed(texts: [String], binding: RevisionBinding) async throws -> [[Double]]
}
public struct UnconfiguredAPIReranker: OptionalAPIReranker {
    public init() {}
    public func rerank(query: String, candidates: [RetrievalCandidate], binding: RevisionBinding) async throws -> [RankedCitation] {
        throw APIIntelligenceError.unsupportedCapability("rerank_not_configured")
    }
}
public struct UnconfiguredAPIEmbedder: OptionalAPIEmbedder {
    public init() {}
    public func embed(texts: [String], binding: RevisionBinding) async throws -> [[Double]] {
        throw APIIntelligenceError.unsupportedCapability("embedding_not_configured")
    }
}
