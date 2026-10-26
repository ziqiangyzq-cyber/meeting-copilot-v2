import Foundation
import Darwin
import SpeechCore

// Local skeleton model, not the complete speech event contract.
public struct SourceRevision: Codable, Equatable, Identifiable {
    public var id: Int { revision }
    public var revision: Int
    public var text: String
    public var status: String
    public var startNS: String
    public var endNS: String
    public var channelID: String?
    public var streamID: String?
    public var sourceSpans: [SourceAudioSpan]?
    public var sourceLanguage: String?
    public init(revision: Int, text: String, status: String = "final", startNS: String = "0", endNS: String = "1000000000", channelID: String? = nil, streamID: String? = nil, sourceSpans: [SourceAudioSpan]? = nil, sourceLanguage: String? = nil) {
        self.revision = revision; self.text = text; self.status = status; self.startNS = startNS; self.endNS = endNS
        self.channelID = channelID; self.streamID = streamID; self.sourceSpans = sourceSpans; self.sourceLanguage = sourceLanguage
    }
}
public struct LocalTranslation: Codable, Equatable, Identifiable {
    public var id: String
    public var revision: Int
    public var sourceRevision: Int
    public var sourceText: String
    public var targetLanguage: String
    public var text: String
    public init(id: String = UUID().uuidString, revision: Int, sourceRevision: Int, sourceText: String, targetLanguage: String, text: String) {
        self.id = id; self.revision = revision; self.sourceRevision = sourceRevision; self.sourceText = sourceText; self.targetLanguage = targetLanguage; self.text = text
    }
}
public struct LocalSegment: Codable, Equatable, Identifiable {
    public var id: String
    public var channelKind: String
    public var revisions: [SourceRevision]
    public var translations: [LocalTranslation]
    public var current: SourceRevision? { revisions.max { $0.revision < $1.revision } }
    public var currentTranslations: [LocalTranslation] {
        guard let current, current.status != "partial" else { return [] }
        let matching = translations.filter { $0.sourceRevision == current.revision && $0.sourceText == current.text }
        return Dictionary(grouping: matching, by: \.targetLanguage).values.compactMap { versions in
            versions.max { $0.revision < $1.revision }
        }.sorted { $0.targetLanguage < $1.targetLanguage }
    }
    public init(id: String = UUID().uuidString, channelKind: String = "synthetic", revisions: [SourceRevision], translations: [LocalTranslation] = []) {
        self.id = id; self.channelKind = channelKind; self.revisions = revisions; self.translations = translations
    }
    public mutating func appendRevision(_ revision: SourceRevision) throws {
        let next = (current?.revision ?? 0) + 1
        guard revision.revision == next, ["partial", "final", "corrected"].contains(revision.status) else { throw StoreError.invalidRevision }
        if let old = current {
            guard (old.status == "partial" && ["partial", "final"].contains(revision.status)) || (["final", "corrected"].contains(old.status) && revision.status == "corrected") else { throw StoreError.invalidRevision }
        } else if revision.status == "corrected" { throw StoreError.invalidRevision }
        revisions.append(revision)
    }
}
public struct NoteVersion: Codable, Equatable, Identifiable {
    public var id: Int { revision }
    public var revision: Int
    public var text: String
    public var savedAt: Date
    public init(revision: Int, text: String, savedAt: Date) { self.revision = revision; self.text = text; self.savedAt = savedAt }
}
public struct LocalMaterial: Codable, Equatable, Identifiable {
    public var id: String
    public var fileName: String
    public var text: String
    public var sha256: String
    public var importedAt: Date
    public init(fileName: String, text: String, sha256: String) { id = UUID().uuidString; self.fileName = fileName; self.text = text; self.sha256 = sha256; importedAt = Date() }
    /// Explicit identity/date for reconstruction from a store that already recorded them (id and import date
    /// are part of the material's auditable identity; regenerating them on reopen would silently change it).
    public init(id: String, fileName: String, text: String, sha256: String, importedAt: Date) {
        self.id = id; self.fileName = fileName; self.text = text; self.sha256 = sha256; self.importedAt = importedAt
    }
}
public struct LocalCaptureBlock: Codable, Equatable {
    public var frameStart: Int, frameEnd: Int, mappingRevision: Int
    public var startNS: String, endNS: String
    public var hostSeconds: Double?, samplePosition: Int64?, sampleRate: Double
    public var presentationSeconds: Double?, receivedUptime: Double
    public init(frameStart: Int, frameEnd: Int, mappingRevision: Int, startNS: String, endNS: String,
                hostSeconds: Double?, samplePosition: Int64?, sampleRate: Double, presentationSeconds: Double?, receivedUptime: Double) {
        self.frameStart = frameStart; self.frameEnd = frameEnd; self.mappingRevision = mappingRevision
        self.startNS = startNS; self.endNS = endNS; self.hostSeconds = hostSeconds; self.samplePosition = samplePosition
        self.sampleRate = sampleRate; self.presentationSeconds = presentationSeconds; self.receivedUptime = receivedUptime
    }
}
public struct LocalCaptureTask: Codable, Equatable, Identifiable {
    public var id: String { segmentID }
    public var streamID: String, segmentID: String
    public var firstObservedBy: String
    public var finalObserved: Bool = false
    public var sourceBlocks: [LocalCaptureBlock]? = nil
    public init(streamID: String, segmentID: String, firstObservedBy: String) {
        self.streamID = streamID; self.segmentID = segmentID; self.firstObservedBy = firstObservedBy
    }
}
public struct LocalCaptureAttempt: Codable, Equatable, Identifiable {
    public var id: String
    public var channelID: String, streamID: String, segmentID: String, locale: String
    public var lifecycle: String
    public var failure: String?
    public var deviceStarted: Bool, audioObserved: Bool, asrObserved: Bool
    public var history: [String]
    public var mode: String? = nil
    public var generationID: String? = nil
    public var tasks: [LocalCaptureTask]? = nil
    public var canonicalMetadata: LocalCanonicalMetadata? = nil
    /// Which recogniser actually ran this attempt, recorded at the moment the attempt is created. Optional so
    /// older records (and records written before this field existed) decode unchanged and read as "unknown".
    public var engineVersion: String? = nil
    public var modelVersion: String? = nil
    public var sourceKind: String? = nil
    public var sourceURL: String? = nil
    public var allTaskIdentities: [LocalCaptureTask] {
        tasks ?? (streamID.isEmpty || segmentID.isEmpty ? [] : [LocalCaptureTask(streamID: streamID, segmentID: segmentID, firstObservedBy: "legacy")])
    }
    public init(id: String, channelID: String, streamID: String, segmentID: String, locale: String,
                engineVersion: String? = nil, modelVersion: String? = nil) {
        self.id = id; self.channelID = channelID; self.streamID = streamID; self.segmentID = segmentID; self.locale = locale
        lifecycle = "prepared"; failure = nil; deviceStarted = false; audioObserved = false; asrObserved = false; history = []
        // Recorded as given. nil means "unrecorded", never a guessed engine name.
        self.engineVersion = engineVersion; self.modelVersion = modelVersion
    }
}
public struct LocalSession: Codable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var createdAt: Date
    public var isDemo: Bool
    public var notes: String
    public var tags: [String]
    public var noteHistory: [NoteVersion]
    public var segments: [LocalSegment]
    public var speechJournal: [Data] = []
    public var materials: [LocalMaterial] = []
    public var captureAttempts: [LocalCaptureAttempt] = []
    public var tombstone: LocalTombstone? = nil
    private enum CodingKeys: String, CodingKey { case id, title, createdAt, isDemo, notes, tags, noteHistory, segments, speechJournal, materials, captureAttempts, tombstone }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); title = try c.decode(String.self, forKey: .title)
        createdAt = try c.decode(Date.self, forKey: .createdAt); isDemo = try c.decode(Bool.self, forKey: .isDemo)
        notes = try c.decode(String.self, forKey: .notes); tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        noteHistory = try c.decode([NoteVersion].self, forKey: .noteHistory); segments = try c.decode([LocalSegment].self, forKey: .segments)
        speechJournal = try c.decodeIfPresent([Data].self, forKey: .speechJournal) ?? []
        materials = try c.decodeIfPresent([LocalMaterial].self, forKey: .materials) ?? []
        captureAttempts = try c.decodeIfPresent([LocalCaptureAttempt].self, forKey: .captureAttempts) ?? []
        tombstone = try c.decodeIfPresent(LocalTombstone.self, forKey: .tombstone)
    }
    public init(id: String = UUID().uuidString, title: String, isDemo: Bool = false, notes: String = "", tags: [String] = [], segments: [LocalSegment] = []) {
        self.id = id; self.title = title; self.createdAt = Date(); self.isDemo = isDemo; self.notes = notes; self.tags = tags; self.noteHistory = []; self.segments = segments
    }
    public init(id: String, title: String, createdAt: Date, isDemo: Bool, notes: String, tags: [String],
                noteHistory: [NoteVersion], segments: [LocalSegment], speechJournal: [Data], captureAttempts: [LocalCaptureAttempt],
                materials: [LocalMaterial] = [], tombstone: LocalTombstone? = nil) {
        self.id = id; self.title = title; self.createdAt = createdAt; self.isDemo = isDemo; self.notes = notes
        self.tags = tags; self.noteHistory = noteHistory; self.segments = segments; self.speechJournal = speechJournal
        self.captureAttempts = captureAttempts; self.materials = materials; self.tombstone = tombstone
    }
    public var chronologicalSegments: [LocalSegment] {
        segments.sorted {
            let left = UInt64($0.current?.startNS ?? "0") ?? 0
            let right = UInt64($1.current?.startNS ?? "0") ?? 0
            return left == right ? $0.id < $1.id : left < right
        }
    }
    public mutating func editNotes(_ text: String) {
        guard notes != text else { return }
        notes = text
        noteHistory.append(NoteVersion(revision: (noteHistory.last?.revision ?? 0) + 1, text: text, savedAt: Date()))
    }
    public static func demonstration() -> LocalSession {
        let source = "This is a synthetic demo. No microphone is active."
        let segment = LocalSegment(revisions: [SourceRevision(revision: 1, text: source)], translations: [LocalTranslation(revision: 1, sourceRevision: 1, sourceText: source, targetLanguage: "zh-Hans", text: "这是自拟演示。麦克风未启动。")])
        return LocalSession(title: "演示会话 · 自拟数据", isDemo: true, notes: "演示随记：确认保存后，可以重开检查。", segments: [segment])
    }
}
public struct LocalArchive: Codable, Equatable {
    public var schemaVersion: Int = 1
    public var generation: Int = 0
    public var sessions: [LocalSession] = []
    public init() {}
}
public enum StoreError: Error, LocalizedError {
    case unsupportedSchema, conflict, busy, invalidRevision
    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema: return "文件版本不支持，已停止写入，请保留原文件。"
        case .conflict: return "文件已被另一实例修改。本次内容尚未保存，请复制随记后重新打开。"
        case .busy: return "另一实例正在保存，请重试。"
        case .invalidRevision: return "无效的原文修订，原记录未改变。"
        }
    }
}
public final class ArchiveStore {
    public let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("sessions.json")
        encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
    }
    public func load() throws -> LocalArchive {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return LocalArchive() }
        let archive = try decoder.decode(LocalArchive.self, from: Data(contentsOf: fileURL))
        guard archive.schemaVersion == 1 else { throw StoreError.unsupportedSchema }
        return archive
    }
    // Atomic replacement plus last-good backup; acknowledged only after exact readback.
    public func save(_ candidate: LocalArchive) throws -> LocalArchive {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lockPath = fileURL.appendingPathExtension("lock").path
        let fd = Darwin.open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw StoreError.busy }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw StoreError.busy }
        defer { flock(fd, LOCK_UN) }
        let disk = try load() // Corrupt/unknown files are never replaced by empty data.
        guard candidate.generation == disk.generation else { throw StoreError.conflict }
        var next = candidate; next.generation += 1
        let data = try encoder.encode(next)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try Data(contentsOf: fileURL).write(to: fileURL.appendingPathExtension("backup"), options: .atomic)
        }
        try data.write(to: fileURL, options: .atomic)
        let reloaded = try load()
        guard reloaded == next else { throw CocoaError(.fileReadCorruptFile) }
        return reloaded
    }
}

public enum EngineAvailability: Equatable { case unavailable(String) }
public protocol AudioEngineAdapter {
    var availability: EngineAvailability { get }
    // Future adapters must validate the authoritative speech contract before subscribing.
    func start(sessionID: String) throws
    func stop() throws
}
public struct UnavailableEngine: AudioEngineAdapter {
    public init() {}
    public var availability: EngineAvailability { .unavailable("无引擎 · 未接入采集、识别或翻译") }
    public func start(sessionID: String) throws { throw NSError(domain: "MeetingCopilot.Engine", code: 1, userInfo: [NSLocalizedDescriptionKey: "无引擎，未开始录音"] ) }
    public func stop() throws {}
}
