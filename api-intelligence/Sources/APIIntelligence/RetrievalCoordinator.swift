import Foundation

public struct RetrievedContext: Sendable {
    public let binding: RevisionBinding
    public let candidates: [RetrievalCandidate]
    public let reranked: Bool
}

/// Orchestrates an injected LOCAL lookup, never treats a chat prompt as retrieval.
/// Supply a real LocalContextLookup bridge separately; this package does not search user files itself.
public struct ContextRetrievalCoordinator: Sendable {
    private let local: any LocalContextLookup
    private let reranker: (any OptionalAPIReranker)?
    private let timeoutSeconds: Double
    public init(local: any LocalContextLookup, optionalReranker: (any OptionalAPIReranker)? = nil,
                timeoutSeconds: Double = 30) throws {
        guard timeoutSeconds.isFinite, timeoutSeconds > 0, timeoutSeconds <= 300 else {
            throw APIIntelligenceError.invalidConfiguration
        }
        self.local = local; self.reranker = optionalReranker; self.timeoutSeconds = timeoutSeconds
    }
    public func retrieve(query: String, binding: RevisionBinding,
                         cancellationToken: APICancellationToken? = nil) async throws -> RetrievedContext {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, query.utf8.count <= 8_192,
              !binding.sessionID.isEmpty, binding.transcriptRevision >= 0, binding.noteRevision >= 0 else {
            throw APIIntelligenceError.invalidJob
        }
        let local = self.local
        let reranker = self.reranker
        let candidates = try await boundedOperation(timeoutSeconds: timeoutSeconds, token: cancellationToken) {
            let values = try await local.lookup(query: query, binding: binding)
            try Task.checkCancellation()
            if cancellationToken?.isCancelled == true { throw APIIntelligenceError.cancelled }
            guard !values.isEmpty, values.count <= 512,
                  values.allSatisfy({ !$0.location.isEmpty && !$0.source.citationID.isEmpty && !$0.source.sourceID.isEmpty && $0.source.sourceRevision >= 0 && !$0.source.text.isEmpty }),
                  Set(values.map { $0.source.citationID }).count == values.count else {
                throw APIIntelligenceError.invalidResponse
            }
            guard let reranker else { return values }
            let ranking = try await reranker.rerank(query: query, candidates: values, binding: binding)
            let known = Set(values.map { $0.source.citationID })
            guard ranking.count == values.count, Set(ranking.map(\.citationID)) == known,
                  ranking.allSatisfy({ $0.score.isFinite }) else { throw APIIntelligenceError.invalidCitation }
            let byID = Dictionary(uniqueKeysWithValues: values.map { ($0.source.citationID, $0) })
            return ranking.sorted { $0.score > $1.score }.map { byID[$0.citationID]! }
        }
        if Task.isCancelled || cancellationToken?.isCancelled == true { throw APIIntelligenceError.cancelled }
        return RetrievedContext(binding: binding, candidates: candidates, reranked: reranker != nil)
    }
}
