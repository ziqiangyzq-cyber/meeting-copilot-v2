import SwiftUI
import AppKit
import ClientRuntime
import MeetingCopilotCore

struct FloatingWindowHook: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { view.window?.level = .floating }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { view.window?.level = .floating }
}
struct ClientHUD: View {
    @ObservedObject var model: ClientModel
    @ObservedObject var asrSettings: ASRSettingsModel
    @Environment(\.openWindow) private var openWindow
    private var recentSegments: [LocalSegment] { Array((model.selected?.segments ?? []).suffix(3)) }
    private var updateToken: String {
        recentSegments.map { "\($0.id):\($0.current?.revision ?? 0):\($0.currentTranslations.count)" }.joined(separator: "|")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("随行字幕 · \(model.translationTargetName)", systemImage: "captions.bubble")
                Spacer()
                Text(model.captureActive ? "\(model.audioInputName) · 监听中" : "已停止")
                    .foregroundStyle(model.captureActive ? Color.green : Color.secondary)
            }.font(.caption)
            Text(model.selected?.title ?? "未选择会话").font(.headline)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if recentSegments.isEmpty {
                            Text("等待语音原文…").foregroundStyle(.secondary)
                            Text("每段识别完成后显示原文与译文；短句可点击停止。").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(recentSegments) { segment in
                            VStack(alignment: .leading, spacing: 6) {
                                if let source = segment.current {
                                    Text(segment.channelKind == "mic" ? "麦克风" : (segment.channelKind == "system" ? "电脑声音" : "原文"))
                                        .font(.caption).foregroundStyle(.secondary)
                                    let display = model.translationPresentation(sessionID: model.selection ?? "", segment: segment)
                                    if !display.isOriginal {
                                        Text(source.text).font(.callout).foregroundStyle(.secondary)
                                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                    }
                                    if let text = display.text {
                                        Text(text).font(.title3).textSelection(.enabled)
                                            .fixedSize(horizontal: false, vertical: true)
                                    } else {
                                        Text(display.status).foregroundStyle(display.isFailure ? Color.red : Color.secondary)
                                        if display.isFailure, let sessionID = model.selection {
                                            Button("重试翻译") { model.translateSegment(sessionID: sessionID, segmentID: segment.id) }
                                        }
                                    }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).id(segment.id)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: updateToken) { _, _ in
                    if let id = recentSegments.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
                .onAppear {
                    if let id = recentSegments.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            Divider()
            QuickNoteView(model: model)
            Toggle("自动翻译", isOn: $model.translateFinal).toggleStyle(.checkbox).font(.caption)
                .onChange(of: model.translateFinal) { _, enabled in
                    if enabled { model.translateMissingCurrentSegments() }
                }
            HStack {
                Button("开始") { Task { await model.startSelectedAudio() } }
                    .disabled(!asrSettings.readyForCapture || (asrSettings.services.usesNetworkASR && !asrSettings.services.contentSendingEnabled) || model.captureActive || model.selection == nil || !model.loaded || model.error != nil)
                Button("停止") { model.stopCapture() }.disabled(!model.captureActive || model.captureStopping)
                Button("补译") { model.translateMissingCurrentSegments() }.disabled(model.selection == nil)
                Spacer()
                Button("设置") { openWindow(id: "settings") }
                Button("主窗口") {
                    if let window = NSApp.windows.first(where: { $0.title == "Meeting Copilot" }) {
                        window.makeKeyAndOrderFront(nil)
                    } else { openWindow(id: "main") }
                }
            }.controlSize(.small)
            if asrSettings.services.usesNetworkASR && !asrSettings.services.contentSendingEnabled {
                Text("网络转写：先在主窗口允许发送内容，再开始。").font(.caption).foregroundStyle(.secondary)
            }
            Text(model.captureStatus).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Text("声音来源：\(model.audioInputName)，可在主窗口更换。").font(.caption).foregroundStyle(.secondary)
            if let error = model.error { Text(error).foregroundStyle(.red).font(.caption) }
        }.padding(20).frame(width: 500, height: 465).background(FloatingWindowHook())
            .background(MeetingCopilotTheme.background)
            .tint(MeetingCopilotTheme.accent)
            .preferredColorScheme(.light)
    }
}
