import SwiftUI
import ClientRuntime

struct LegacyMigrationVisibilityView: View {
    @ObservedObject var model: ClientModel
    @StateObject private var reader: LegacyReadOnlyModel
    init(model: ClientModel) {
        self.model = model
        _reader = StateObject(wrappedValue: LegacyReadOnlyModel(source: model.store.fileURL))
    }
    var body: some View {
        if let report = model.incrementalMigrationReport {
            VStack(alignment: .leading, spacing: 8) {
                Text("增量可写 ≠ 旧档全部迁移").font(.headline)
                Text("已迁移会话 \(report.migratedSessions.count) 个 · 未迁移项 \(report.notMigratedCount) 个").textSelection(.enabled)
                Text("未迁移资料保留在旧档；以下入口仅查看，不可编辑或写回。").font(.caption)
                DisclosureGroup("逐项未迁移清单（\(report.notMigratedCount)）") {
                    ForEach(Array(report.entries.enumerated()), id: \.offset) { _, entry in
                        if case .notMigrated(let reason) = entry.disposition {
                            Text("\(entry.sessionID) · \(entry.item) · \(entry.identity) · \(reason)")
                                .font(.caption).textSelection(.enabled)
                        }
                    }
                }
                DisclosureGroup("查看旧档原文与采集记录（只读）") {
                    Text("来源：\(reader.source.path) · 仅查看").font(.caption).textSelection(.enabled)
                    Button("重新读取旧档") { reader.reload() }
                    if let failure = reader.failure { Text(failure).foregroundStyle(.red) }
                    if let archive = reader.archive {
                        ForEach(archive.sessions) { session in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("旧档：\(session.title) · \(session.id)").bold()
                                Text(session.notes).textSelection(.enabled)
                                ForEach(session.noteHistory) { note in
                                    Text("随记 r\(note.revision)：\(note.text)").textSelection(.enabled)
                                }
                                ForEach(session.segments) { segment in
                                    ForEach(segment.revisions) { revision in
                                        Text("\(segment.id) 原文 r\(revision.revision)：\(revision.text)").textSelection(.enabled)
                                    }
                                    ForEach(segment.translations) { translation in
                                        Text("译文 r\(translation.revision)：\(translation.text)").textSelection(.enabled)
                                    }
                                }
                                ForEach(session.captureAttempts) { attempt in
                                    Text("采集 \(attempt.id) · \(attempt.lifecycle) · \(attempt.failure ?? "无错误记录") · \(attempt.locale)")
                                    Text(attempt.history.joined(separator: " / ")).textSelection(.enabled)
                                }
                            }.padding(.vertical, 8)
                        }
                    }
                }.onAppear { reader.reload() }
            }.padding(12).background(Color.orange.opacity(0.08))
        } else if let block = model.incrementalMigrationBlock {
            Text("旧档迁移未就绪：\(block)").foregroundStyle(.red).textSelection(.enabled)
        }
    }
}
