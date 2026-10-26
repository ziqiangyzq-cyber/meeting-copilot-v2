import Foundation
import MeetingCopilotCore
import ClientRuntime
import IncrementalArchive
import ClientIncrementalBridge
import SpeechCore

// Material chunk checks. Two levels, because they prove different things:
//  * the projection/reopen level proves that an incomplete material is never presented as a complete document;
//  * the writer level proves gap/duplicate/identity rejections really reach disk that way.
// Every negative case runs on its own writer and directory: this archive is fail-closed, so a rejected
// submission poisons its writer for later submissions.
struct MaterialCheckFailure: Error { let message: String }
func materialRequire(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw MaterialCheckFailure(message: message) }
}

@MainActor let materialCheckConfigURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("text-mode-config.json")

enum MaterialChunkChecks {
    static func limits() throws -> CoreLimits {
        try CoreLimits(maxBufferedEvents: 64, maxBufferedBytes: 1 << 20, reorderTimeoutMs: 100, recoveryTimeoutMs: 2000)
    }
    static func directory(_ name: String) throws -> URL { try StorageEvolutionChecks.newDirectory(name) }

    // MARK: - projection level

    /// A material with only some chunks acknowledged must be visible as incomplete, and must NOT be handed to
    /// the LocalArchive as a whole document (an export would otherwise reproduce a truncated file as the file).
    @MainActor static func incompleteMaterialIsNeverPresentedAsComplete() throws {
        var projection = BridgeProjection(limits: try limits())
        let fence = ArchiveFence(sessionID: "s-material")
        let bits = Date(timeIntervalSinceReferenceDate: 700_000_500).timeIntervalSinceReferenceDate.bitPattern
        try projection.apply(ArchiveSubmission(expectedHead: 0, fence: fence, deltas: [
            .sessionBootstrap(ArchiveSessionBootstrap(title: "material", createdAtReferenceBits: bits, isDemo: false,
                                                      initialNotes: "", tags: []))]))
        let full = "第一段内容\n第二段内容\n第三段内容"
        let chunks = IncrementalPersistence.materialChunks(id: "m-1", fileName: "spec.md", text: full,
            sha256: String(repeating: "a", count: 64), importedAtReferenceBits: bits, maximumChunkBytes: 12)
        try materialRequire(chunks.count >= 3, "fixture really splits into \(chunks.count) chunks")

        try projection.apply(ArchiveSubmission(expectedHead: 1, fence: fence, deltas: [chunkDelta(chunks[0])]))
        var material = projection.sessions["s-material"]!.materials["m-1"]
        try materialRequire(material?.complete == false && material?.receivedChunks == 1, "partial material reports itself incomplete")
        try materialRequire(material?.text == chunks[0].text, "partial material exposes only the acknowledged chunk text")
        var archive = try LocalArchiveProjection.archive(projection)
        try materialRequire(archive.sessions[0].materials.isEmpty, "incomplete material must not become a whole LocalMaterial")

        for (offset, chunk) in chunks.dropFirst().enumerated() {
            try projection.apply(ArchiveSubmission(expectedHead: UInt64(offset + 2), fence: fence, deltas: [chunkDelta(chunk)]))
        }
        material = projection.sessions["s-material"]!.materials["m-1"]
        try materialRequire(material?.complete == true && material?.receivedChunks == UInt64(chunks.count), "material reports complete only after the last chunk")
        try materialRequire(material?.text == full, "concatenated chunk text equals the original")
        archive = try LocalArchiveProjection.archive(projection)
        try materialRequire(archive.sessions[0].materials.count == 1, "complete material becomes exactly one LocalMaterial")
        try materialRequire(archive.sessions[0].materials[0].text == full, "reconstructed material text is the full original")
        try materialRequire(archive.sessions[0].materials[0].id == "m-1" && archive.sessions[0].materials[0].sha256 == String(repeating: "a", count: 64),
                            "material identity and digest are preserved, not regenerated")
        print("PASS material incomplete/completed projection state")
    }

    /// Splitting must never cut a UTF-8 scalar: a chunk boundary inside an emoji would corrupt the text.
    static func chunkingNeverSplitsAScalar() throws {
        let text = "😀示例词SampleTerm😀密封胶😀"
        let chunks = IncrementalPersistence.materialChunks(id: "m-2", fileName: "u.md", text: text,
            sha256: String(repeating: "b", count: 64), importedAtReferenceBits: 0, maximumChunkBytes: 5)
        try materialRequire(chunks.map(\.text).joined() == text, "scalar-safe splitting preserves the exact text")
        try materialRequire(chunks.allSatisfy { $0.text.utf8.count <= 5 }, "no chunk exceeds the byte budget")
        try materialRequire(chunks.allSatisfy { !$0.text.unicodeScalars.isEmpty }, "no empty chunk is produced while content remains")
        try materialRequire(chunks.enumerated().allSatisfy { $0.element.chunkIndex == $0.offset && $0.element.chunkCount == chunks.count },
                            "chunk indices/count are self-describing")
        // An empty material is still one identifiable chunk, never zero chunks.
        let empty = IncrementalPersistence.materialChunks(id: "m-3", fileName: "e.md", text: "",
            sha256: String(repeating: "c", count: 64), importedAtReferenceBits: 0)
        try materialRequire(empty.count == 1 && empty[0].chunkCount == 1 && empty[0].text.isEmpty, "empty material is one empty chunk, not zero chunks")
        print("PASS material scalar-safe chunking")
    }

    // MARK: - writer level (each negative on its own directory)

    static func chunkDelta(_ chunk: IncrementalPersistence.MaterialChunk) -> ArchiveDelta {
        .materialChunk(materialID: chunk.materialID, fileName: chunk.fileName, sha256: chunk.sha256,
                       importedAtReferenceBits: chunk.importedAtReferenceBits,
                       chunkIndex: UInt64(chunk.chunkIndex), chunkCount: UInt64(chunk.chunkCount), text: chunk.text)
    }
    static func openedWriter(_ name: String, session: String) async throws -> (IncrementalArchiveWriter, UInt64, URL) {
        let dir = try directory(name)
        let writer = try await IncrementalArchiveWriter.open(directory: dir, limits: ArchiveLimits())
        let ack = try await TypedTombstoneChecks.submit(writer, ArchiveSubmission(id: UUID(), expectedHead: 0,
            fence: ArchiveFence(sessionID: session), deltas: [.sessionOpened(title: "material")], durability: .fsync))
        return (writer, ack.token.plannedCommitSequence, dir)
    }
    static func expectFailure(_ expected: ArchiveFailure, _ body: () async throws -> Void, label: String) async throws {
        do {
            try await body()
            throw MaterialCheckFailure(message: "\(label): rejected submission was accepted")
        } catch let failure as ArchiveFailure {
            try materialRequire(failure == expected, "\(label): unexpected failure \(failure)")
        }
    }
    static func chunksOnDisk(_ dir: URL) async throws -> [String: Int] {
        let recovery = try await IncrementalArchiveWriter.inspect(directory: dir)
        var counts: [String: Int] = [:]
        for record in recovery.records {
            for delta in record.submission.deltas {
                if case .materialChunk(let id, _, _, _, _, _, _) = delta { counts[id, default: 0] += 1 }
            }
        }
        return counts
    }
    static func chunk(_ id: String, index: Int, count: Int, text: String, sha: String = String(repeating: "d", count: 64),
                      fileName: String = "n.md", bits: UInt64 = 0) -> ArchiveDelta {
        .materialChunk(materialID: id, fileName: fileName, sha256: sha, importedAtReferenceBits: bits,
                       chunkIndex: UInt64(index), chunkCount: UInt64(count), text: text)
    }
    static func submit(_ writer: IncrementalArchiveWriter, head: UInt64, session: String, delta: ArchiveDelta) async throws -> UInt64 {
        try await TypedTombstoneChecks.submit(writer, ArchiveSubmission(id: UUID(), expectedHead: head,
            fence: ArchiveFence(sessionID: session), deltas: [delta], durability: .fsync)).token.plannedCommitSequence
    }

    /// A gap (chunk 1 before chunk 0) must be refused: stitching out-of-order chunks would silently corrupt text.
    static func rejectsGap() async throws {
        let (writer, head, dir) = try await openedWriter("material-negative-gap", session: "s-gap")
        try await expectFailure(.fence("material chunk must start at index 0"), {
            _ = try await submit(writer, head: head, session: "s-gap", delta: chunk("m-gap", index: 1, count: 3, text: "second"))
        }, label: "gap")
        let counts = try await chunksOnDisk(dir)
        try materialRequire(counts["m-gap"] == nil, "a gapped first chunk leaves no material record on disk")
        print("PASS negative: material chunk gap rejected, log unchanged")
    }

    /// The same chunk twice must be refused, and the acknowledged chunk count must not advance.
    static func rejectsDuplicateChunk() async throws {
        let (writer, head, dir) = try await openedWriter("material-negative-duplicate", session: "s-dup")
        let next = try await submit(writer, head: head, session: "s-dup", delta: chunk("m-dup", index: 0, count: 2, text: "first"))
        try await expectFailure(.fence("material chunk identity/gap/complete"), {
            _ = try await submit(writer, head: next, session: "s-dup", delta: chunk("m-dup", index: 0, count: 2, text: "first"))
        }, label: "duplicate chunk")
        let counts = try await chunksOnDisk(dir)
        try materialRequire(counts["m-dup"] == 1, "duplicate rejection leaves exactly one acknowledged chunk")
        print("PASS negative: duplicate material chunk rejected, single chunk retained")
    }

    /// A chunk whose identity/digest/import date changed mid-material must be refused, never merged.
    static func rejectsIdentityChange() async throws {
        let (writer, head, dir) = try await openedWriter("material-negative-identity", session: "s-id")
        let next = try await submit(writer, head: head, session: "s-id", delta: chunk("m-id", index: 0, count: 2, text: "first"))
        try await expectFailure(.fence("material chunk identity/gap/complete"), {
            _ = try await submit(writer, head: next, session: "s-id",
                                 delta: chunk("m-id", index: 1, count: 2, text: "second", sha: String(repeating: "e", count: 64)))
        }, label: "identity change")
        let counts = try await chunksOnDisk(dir)
        try materialRequire(counts["m-id"] == 1, "identity conflict leaves the original chunk only")
        print("PASS negative: material chunk identity change rejected")
    }

    /// A complete material accepts nothing further: it must not silently grow after the last chunk.
    static func rejectsChunkAfterComplete() async throws {
        let (writer, head, dir) = try await openedWriter("material-negative-complete", session: "s-done")
        let next = try await submit(writer, head: head, session: "s-done", delta: chunk("m-done", index: 0, count: 1, text: "whole"))
        try await expectFailure(.fence("material chunk identity/gap/complete"), {
            _ = try await submit(writer, head: next, session: "s-done", delta: chunk("m-done", index: 0, count: 2, text: "more"))
        }, label: "chunk after complete")
        let counts = try await chunksOnDisk(dir)
        try materialRequire(counts["m-done"] == 1, "a complete material accepts no further chunk")
        print("PASS negative: chunk after completion rejected")
    }

    /// A zero-chunk material is not a material: it would be indistinguishable from "never submitted".
    static func rejectsZeroChunkCount() async throws {
        let (writer, head, dir) = try await openedWriter("material-negative-zerocount", session: "s-zero")
        try await expectFailure(.invalidInput("material identity/date"), {
            _ = try await submit(writer, head: head, session: "s-zero", delta: chunk("m-zero", index: 0, count: 0, text: "x"))
        }, label: "zero chunk count")
        let counts = try await chunksOnDisk(dir)
        try materialRequire(counts.isEmpty, "a rejected zero-chunk material writes nothing")
        print("PASS negative: zero-chunk material rejected at admission")
    }

    // MARK: - real ClientModel path

    /// The real import path: a material goes through the model's own chunking and the store's own ledger, then
    /// a fresh model reopens the store and must reconstruct the exact material.
    @MainActor static func modelMaterialSurvivesReopen() async throws {
        let dir = try directory("material-model-reopen")
        let model = ClientModel(directory: dir, configURL: materialCheckConfigURL)
        model.archive.sessions = [LocalSession(id: "mat", title: "资料会话")]; model.selection = "mat"
        let enabled = await model.enableIncrementalPersistence(limits: try limits())
        try materialRequire(enabled, "material fixture opens the incremental store")
        _ = try await model.incremental!.awaitQuiescence()
        let text = "示例资料：SampleTerm 密封胶 😀 USD 2,450.75\n第二行 Unicode ✓"
        let material = LocalMaterial(fileName: "spec.md", text: text, sha256: String(repeating: "f", count: 64))
        model.archive.sessions[0].materials.append(material)
        let chunks = model.incrementalMaterialChunks(session: "mat", material: material)
        try materialRequire(model.incrementalSubmitMaterial(session: "mat", chunks: chunks), "material chunks were admitted")
        _ = try await model.incremental!.awaitQuiescence()
        let durable = model.incremental!.durableMaterialChunks(session: "mat", materialID: material.id)
        try materialRequire(durable?.received == durable?.total, "every chunk became durable (received \(durable?.received ?? -1)/\(durable?.total ?? -1))")
        try materialRequire(model.incrementalCloseReadiness().sessions["mat"]?.materials ?? 0 == 0, "an acknowledged material is not still caller-pending")
        let closed = await model.closeIncrementalPersistence()
        try materialRequire(closed.closed, "material store closes: \(closed.reason ?? "nil")")

        let reopened = ClientModel(directory: dir, configURL: materialCheckConfigURL)
        let restored = await reopened.enableIncrementalPersistence(limits: try limits())
        try materialRequire(restored, "material store reopens")
        try materialRequire(reopened.archive.sessions[0].materials == [material], "reopen reconstructs the exact material id/name/sha/date/text")
        let exported = String(decoding: try NoteOperations.exportData(reopened.archive.sessions[0], format: .markdown), as: UTF8.self)
        try materialRequire(exported.contains(text), "export carries the full material text")
        print("PASS material real model path survives close+reopen")
    }

    /// A refused chunk must stay visibly caller-side pending, and a close must never claim success over it.
    @MainActor static func refusedChunkIsNeverSilentlyDropped() async throws {
        let dir = try directory("material-model-refused")
        let model = ClientModel(directory: dir, configURL: materialCheckConfigURL)
        model.archive.sessions = [LocalSession(id: "refused", title: "拒绝")]
        model.selection = "refused"
        let budget = BridgeLimits(maximumAdmittedCount: 1, maximumReservedBytes: 8 * 1024 * 1024)
        let enabled = await model.enableIncrementalPersistence(limits: try limits(), budget: budget)
        try materialRequire(enabled, "refused-material fixture opens")
        _ = try await model.incremental!.awaitQuiescence()
        let text = String(repeating: "资料内容 ", count: 4_000)   // multi-chunk, larger than one ledger entry
        let material = LocalMaterial(fileName: "big.md", text: text, sha256: String(repeating: "0a", count: 32))
        model.archive.sessions[0].materials.append(material)
        let chunks = model.incrementalMaterialChunks(session: "refused", material: material)
        try materialRequire(chunks.count >= 2, "fixture really needs \(chunks.count) chunks")
        let allAdmitted = model.incrementalSubmitMaterial(session: "refused", chunks: chunks)
        try materialRequire(!allAdmitted, "a multi-chunk material cannot fully enter a one-entry ledger")
        try materialRequire(model.incremental!.lastFailure?.contains("LEDGER_BUDGET_FULL") == true,
                            "the refusal names the real reason: \(model.incremental!.lastFailure ?? "nil")")
        let pending = model.incrementalCloseReadiness()
        try materialRequire((pending.sessions["refused"]?.materials ?? 0) == 1, "the refused material stays caller-side pending")
        try materialRequire(model.archive.sessions[0].materials[0].text == text, "caller keeps the exact material text, never truncated")

        let closeResult = await model.closeIncrementalPersistence()
        if closeResult.closed {
            let reopened = ClientModel(directory: dir, configURL: materialCheckConfigURL)
            let restored = await reopened.enableIncrementalPersistence(limits: try limits())
            try materialRequire(restored && reopened.archive.sessions[0].materials == [material],
                                "a closed store reopens with the exact material, never truncated")
            print("PASS refused material chunk: bounded preflight drained it, reopen exact")
        } else {
            try materialRequire(!model.incremental!.isClosed && materialCheckIsCallerSide(closeResult.reason ?? ""),
                                "a false close keeps the store usable and reports the real reason: \(closeResult.reason ?? "nil")")
            try materialRequire(model.archive.sessions[0].materials == [material], "false close retains the material unchanged")
            print("PASS refused material chunk: close stayed false with reason \(closeResult.reason ?? "nil"), content retained")
        }
    }
    static func materialCheckIsCallerSide(_ reason: String) -> Bool {
        reason.contains("LEDGER_BUDGET_FULL") || reason.contains("未提交内容") || reason.contains("caller")
    }
    /// A normal-size material (well inside the 2 MiB import cap) really reaches the incremental path: it splits
    /// into many chunks under the default ledger budget and reopens byte-exact. This is the case the old
    /// one-size-fits-all refusal blocked, so it is asserted separately from the tiny fixture above.
    @MainActor static func normalSizeMaterialReachesIncrementalPath() async throws {
        let dir = try directory("material-model-normal-size")
        let model = ClientModel(directory: dir, configURL: materialCheckConfigURL)
        model.archive.sessions = [LocalSession(id: "normal", title: "正常资料")]; model.selection = "normal"
        let enabled = await model.enableIncrementalPersistence(limits: try limits())
        try materialRequire(enabled, "normal-size fixture opens")
        _ = try await model.incremental!.awaitQuiescence()
        // ~96 KB of real Chinese/emoji content: far under the 2 MiB import cap, far over one 12 KB chunk.
        var text = ""
        for line in 0..<1_200 { text += "第\(line)行 示例 SampleTerm 密封胶 😀 USD 2,450.75 ✓\n" }
        try materialRequire(text.utf8.count > 48_000, "fixture is a genuinely normal-size file (\(text.utf8.count) bytes)")
        let material = LocalMaterial(fileName: "full-spec.md", text: text, sha256: String(repeating: "1b", count: 32))
        model.archive.sessions[0].materials.append(material)
        let chunks = model.incrementalMaterialChunks(session: "normal", material: material)
        try materialRequire(chunks.count > 4, "normal-size material really splits into \(chunks.count) chunks")
        try materialRequire(model.incrementalSubmitMaterial(session: "normal", chunks: chunks), "all \(chunks.count) chunks admitted under the default budget")
        _ = try await model.incremental!.awaitQuiescence()
        let durable = model.incremental!.durableMaterialChunks(session: "normal", materialID: material.id)
        try materialRequire(durable?.received == chunks.count && durable?.total == chunks.count,
                            "every chunk durable (\(durable?.received ?? -1)/\(durable?.total ?? -1))")
        let closed = await model.closeIncrementalPersistence()
        try materialRequire(closed.closed, "normal-size material store closes: \(closed.reason ?? "nil")")
        let reopened = ClientModel(directory: dir, configURL: materialCheckConfigURL)
        let restored = await reopened.enableIncrementalPersistence(limits: try limits())
        try materialRequire(restored, "normal-size store reopens")
        try materialRequire(reopened.archive.sessions[0].materials == [material],
                            "reopened material is byte-exact (\(reopened.archive.sessions[0].materials.first?.text.utf8.count ?? -1) vs \(text.utf8.count) bytes)")
        print("PASS normal-size material (\(chunks.count) chunks, \(text.utf8.count) bytes) survives the incremental path")
    }

    /// The default (non-incremental) path must be untouched: same reader, same 2 MiB cap, same whole-file save.
    @MainActor static func defaultMaterialPathIsUnchanged() async throws {
        let dir = try directory("material-default-path")
        let store = ArchiveStore(directory: dir)
        var archive = LocalArchive()
        var session = LocalSession(id: "default", title: "默认路径"); session.editNotes("随记")
        archive.sessions = [session]
        archive = try store.save(archive)
        let text = "默认路径资料 SampleTerm 😀\n第二行"
        archive.sessions[0].materials.append(LocalMaterial(fileName: "d.md", text: text, sha256: String(repeating: "2c", count: 32)))
        archive = try store.save(archive)
        let reopened = try ArchiveStore(directory: dir).load()
        try materialRequire(reopened.sessions[0].materials.count == 1 && reopened.sessions[0].materials[0].text == text,
                            "default path still saves and reads back a whole material in one snapshot")
        let exported = String(decoding: try NoteOperations.exportData(reopened.sessions[0], format: .markdown), as: UTF8.self)
        try materialRequire(exported.contains(text), "default path export carries the material text")
        // The 2 MiB input guard itself: an unsupported extension is refused, not silently accepted.
        let badURL = dir.appendingPathComponent("nope.pdf")
        try Data("x".utf8).write(to: badURL)
        do {
            _ = try MaterialImport.read(badURL, maxBytes: 2 * 1024 * 1024)
            throw MaterialCheckFailure(message: "unsupported extension was accepted")
        } catch is MaterialCheckFailure { throw MaterialCheckFailure(message: "unsupported extension was accepted") }
        catch { /* expected refusal */ }
        let bigURL = dir.appendingPathComponent("big.txt")
        try Data(repeating: 0x61, count: 2 * 1024 * 1024 + 1).write(to: bigURL)
        do {
            _ = try MaterialImport.read(bigURL, maxBytes: 2 * 1024 * 1024)
            throw MaterialCheckFailure(message: "over-cap file was accepted")
        } catch is MaterialCheckFailure { throw MaterialCheckFailure(message: "over-cap file was accepted") }
        catch { /* expected refusal */ }
        print("PASS default material path unchanged (whole-file save, TXT/MD only, 2 MiB cap enforced)")
    }
}

@MainActor func runMaterialChunkChecks() async throws {
    try MaterialChunkChecks.incompleteMaterialIsNeverPresentedAsComplete()
    try MaterialChunkChecks.chunkingNeverSplitsAScalar()
    try await MaterialChunkChecks.rejectsGap()
    try await MaterialChunkChecks.rejectsDuplicateChunk()
    try await MaterialChunkChecks.rejectsIdentityChange()
    try await MaterialChunkChecks.rejectsChunkAfterComplete()
    try await MaterialChunkChecks.rejectsZeroChunkCount()
    try await MaterialChunkChecks.modelMaterialSurvivesReopen()
    try await MaterialChunkChecks.normalSizeMaterialReachesIncrementalPath()
    try await MaterialChunkChecks.refusedChunkIsNeverSilentlyDropped()
    try await MaterialChunkChecks.defaultMaterialPathIsUnchanged()
}
