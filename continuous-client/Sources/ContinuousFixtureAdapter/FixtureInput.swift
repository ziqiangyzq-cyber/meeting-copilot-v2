import Foundation

struct FixtureInput: Decodable {
    struct TaskHypotheses: Decodable {
        let partials: [String]
        let final: String?
    }
    let caseId: String?
    let sampleRate: Double
    let blockFrames: Int
    let budget: Int
    let samples: [Float]
    let taskHypotheses: [TaskHypotheses]
    let finalOrder: [Int]
    let firstAppendThrow: Bool?
    let hostStartSeconds: Double?
    let finishDeadlineSeconds: Double?
    let timeoutMs: Int?
    let queueCapacityBlocks: Int?
    let maxRetiringTasks: Int?
    let typedBefore: String?
    let typedDuring: String?
    let textModeConfig: String?

    func validate() throws {
        guard sampleRate.isFinite, sampleRate > 0, sampleRate <= 384_000, sampleRate.rounded(.towardZero) == sampleRate,
              blockFrames > 0, blockFrames <= 65536, budget >= blockFrames,
              !samples.isEmpty, samples.count <= 262144, samples.count % blockFrames == 0,
              samples.allSatisfy({ $0.isFinite }), !taskHypotheses.isEmpty, taskHypotheses.count <= 64,
              Set(finalOrder).count == finalOrder.count, finalOrder.allSatisfy({ taskHypotheses.indices.contains($0) }),
              (timeoutMs ?? 5000) > 0, (timeoutMs ?? 5000) <= 60000,
              (finishDeadlineSeconds ?? 2).isFinite, (finishDeadlineSeconds ?? 2) > 0,
              (finishDeadlineSeconds ?? 2) <= 60,
              (hostStartSeconds ?? 12).isFinite, (hostStartSeconds ?? 12) >= 0,
              (1...65536).contains(queueCapacityBlocks ?? max(8, samples.count / blockFrames)),
              (1...64).contains(maxRetiringTasks ?? max(2, taskHypotheses.count)) else {
            throw AdapterFailure("INVALID_INPUT_CONFIGURATION")
        }
        if firstAppendThrow == true, samples.count < blockFrames * 2 {
            throw AdapterFailure("FIRST_APPEND_THROW_REQUIRES_TWO_INPUT_BLOCKS")
        }
    }
    static func decode(_ data: Data) throws -> FixtureInput {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let input = try decoder.decode(FixtureInput.self, from: data)
        try input.validate(); return input
    }
}
struct AdapterFailure: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}
