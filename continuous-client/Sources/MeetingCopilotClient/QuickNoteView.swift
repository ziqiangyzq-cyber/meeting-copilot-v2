import SwiftUI
import ClientRuntime

struct QuickNoteView: View {
    @ObservedObject var model: ClientModel
    @State private var drafts: [String: String] = [:]
    private var text: String {
        get { drafts[model.selection ?? ""] ?? "" }
        nonmutating set { drafts[model.selection ?? ""] = newValue }
    }
    private func save() {
        guard model.selected != nil, model.loaded, model.error == nil,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.appendTimedNote(text)
        if model.error == nil { text = "" }
    }
    var body: some View {
        HStack(spacing: 8) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(model.quickNoteTimeLabel(at: context.date))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            TextField("随记一句话…", text: Binding(get: { text }, set: { text = $0 }))
                .textFieldStyle(.roundedBorder).onSubmit(save)
            Button { save() } label: { Image(systemName: "plus.circle.fill") }
                .help("添加带时间的随记").accessibilityLabel("添加随记")
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    model.selected == nil || !model.loaded || model.error != nil)
        }.controlSize(.small)
    }
}
