import Foundation
import CryptoKit
import Darwin
@preconcurrency import Speech

func clockNS() -> UInt64 {
    var info = mach_timebase_info_data_t(); mach_timebase_info(&info)
    let t = mach_absolute_time()
    return (t / UInt64(info.denom)) * UInt64(info.numer) + (t % UInt64(info.denom)) * UInt64(info.numer) / UInt64(info.denom)
}
@MainActor final class Worker {
    let input: [String: Any]
    var task: SFSpeechRecognitionTask?
    var recognizer: SFSpeechRecognizer?
    var continuation: CheckedContinuation<Int32, Never>?
    var timer: Task<Void, Never>?
    var text = ""
    var tokens: [[String: Any]] = []
    init(_ input: [String: Any]) { self.input = input }
    func emit(_ kind: String, _ extra: [String: Any] = [:]) {
        var m: [String: Any] = ["kind": kind, "runId": input["runId"]!, "workerId": input["workerId"]!, "audioSHA": input["audioSHA"]!, "locale": input["locale"]!, "pid": ProcessInfo.processInfo.processIdentifier, "monoNS": clockNS(), "clock": "mach_absolute_time_ns"]
        m.merge(extra) { _, new in new }
        if let data = try? JSONSerialization.data(withJSONObject: m, options: [.sortedKeys]) {
            FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
        }
    }
    func finish(_ outcome: String, code: Int32, error: String? = nil) {
        guard let c = continuation else { return }
        continuation = nil; timer?.cancel(); timer = nil
        var extras: [String: Any] = ["outcome": outcome, "text": text, "tokens": tokens]
        if let error { extras["error"] = error }
        emit("terminal", extras)
        task?.cancel(); task = nil; recognizer = nil
        c.resume(returning: code)
    }
    func run() async -> Int32 {
        await withCheckedContinuation { c in
            continuation = c
            guard SFSpeechRecognizer.authorizationStatus() == .authorized else { finish("authorization_missing", code: 77); return }
            guard let locale = input["locale"] as? String,
                  let r = SFSpeechRecognizer(locale: Locale(identifier: locale)), r.supportsOnDeviceRecognition, r.isAvailable else { finish("unavailable", code: 2); return }
            recognizer = r
            let req = SFSpeechURLRecognitionRequest(url: URL(fileURLWithPath: input["audioPath"] as! String))
            req.requiresOnDeviceRecognition = true; req.shouldReportPartialResults = true
            req.contextualStrings = input["terms"] as? [String] ?? []
            if let p = input["addsPunctuation"] as? Bool { req.addsPunctuation = p }
            emit("task_create_before")
            task = r.recognitionTask(with: req) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let tokens = result?.bestTranscription.segments.map { ["text": $0.substring, "startSeconds": $0.timestamp, "durationSeconds": $0.duration, "confidence": $0.confidence] as [String: Any] }
                let final = result?.isFinal ?? false
                let err = error.map { let e = $0 as NSError; return "\(e.domain):\(e.code)" }
                // Convert to Sendable data before crossing the actor boundary.
                let tokenData = tokens.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.continuation != nil else { self.emit("late_callback_discarded"); return }
                    self.emit("callback", ["isFinal": final])
                    if let text { self.text = text }
                    if let tokenData, let decoded = try? JSONSerialization.jsonObject(with: tokenData) as? [[String: Any]] { self.tokens = decoded }
                    if final { self.finish("final", code: 0) }
                    else if let err { self.finish("error", code: 2, error: err) }
                    else { self.emit("partial", ["text": self.text, "tokens": self.tokens]) }
                }
            }
            emit("task_create_return")
            let seconds = input["timeoutSeconds"] as! Double
            timer = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } catch { return }
                self?.finish("timeout", code: 2, error: "FINAL_DEADLINE_EXCEEDED")
            }
        }
    }
}
@main struct IndependentSpeechWorker {
    @MainActor static func main() async {
        if CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "--authorize-once" {
            let raw = await withCheckedContinuation { (c: CheckedContinuation<Int, Never>) in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0.rawValue) } }
            print("authorization_status_raw=\(raw)"); exit(raw == 3 ? 0 : 77)
        }
        do {
            guard CommandLine.arguments.count == 1, let line = readLine(), let data = line.data(using: .utf8),
                  let input = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  input["kind"] as? String == "prepare", input["syntheticAudioAuthorized"] as? Bool == true,
                  let path = input["audioPath"] as? String, path.hasPrefix("/"),
                  let sha = input["audioSHA"] as? String,
                  let locale = input["locale"] as? String, ["zh-CN", "zh-Hans-CN", "en-US"].contains(locale),
                  let timeout = input["timeoutSeconds"] as? Double, timeout.isFinite, timeout > 0, timeout <= 3600,
                  let run = input["runId"] as? String, !run.isEmpty,
                  let id = input["workerId"] as? String, !id.isEmpty else { exit(64) }
            let actual = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: path))).map { String(format: "%02x", $0) }.joined()
            guard actual == sha else { exit(65) }
            let w = Worker(input)
            w.emit("ready", ["authorizationRaw": SFSpeechRecognizer.authorizationStatus().rawValue])
            guard let start = readLine(), let d = start.data(using: .utf8), let msg = try JSONSerialization.jsonObject(with: d) as? [String: Any],
                  msg["kind"] as? String == "start", msg["runId"] as? String == run, msg["audioSHA"] as? String == sha, msg["workerId"] as? String == id else { exit(65) }
            w.emit("start_received")
            exit(await w.run())
        } catch { fputs("worker input/audio error\n", stderr); exit(65) }
    }
}
