import Foundation

/// Explicit opt-in transport implementation. Constructing it performs no request.
/// Rejects all redirects to prevent credentials forwarding to another endpoint.
public final class URLSessionAPITransport: NSObject, APIHTTPTransport, URLSessionTaskDelegate, @unchecked Sendable {
    public override init() { super.init() }
    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                           completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    public func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> APIHTTPResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw APIIntelligenceError.invalidResponse }
        if response.expectedContentLength > maximumResponseBytes { throw APIIntelligenceError.responseLimit }
        var body = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard body.count < maximumResponseBytes else { throw APIIntelligenceError.responseLimit }
            body.append(byte)
        }
        return APIHTTPResponse(statusCode: response.statusCode, body: body)
    }
}

/// Single completion gate: timeout/cancel can finish even if injected transport ignores cancellation.
/// A late worker is cancelled and its result discarded; arbitrary injected code may still finish later.
private final class CompletionGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var result: Result<Value, any Error>?
    private var tasks: [Task<Void, Never>] = []
    func install(_ c: CheckedContinuation<Value, any Error>) {
        lock.lock()
        if let result { lock.unlock(); c.resume(with: result) }
        else { continuation = c; lock.unlock() }
    }
    func add(_ task: Task<Void, Never>) {
        lock.lock()
        if result != nil { lock.unlock(); task.cancel() }
        else { tasks.append(task); lock.unlock() }
    }
    func finish(_ result: Result<Value, any Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let c = continuation; continuation = nil
        let workers = tasks; tasks.removeAll()
        lock.unlock()
        workers.forEach { $0.cancel() }
        c?.resume(with: result)
    }
}

func boundedOperation<Value: Sendable>(timeoutSeconds: Double, token: APICancellationToken?,
                                     invalidation: APICancellationToken? = nil,
                                     operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
    let gate = CompletionGate<Value>()
    return try await withTaskCancellationHandler {
        try Task.checkCancellation()
        if token?.isCancelled == true { throw APIIntelligenceError.cancelled }
        if invalidation?.isCancelled == true { throw APIIntelligenceError.staleResponse }
        return try await withCheckedThrowingContinuation { c in
            gate.install(c)
            gate.add(Task {
                do { gate.finish(.success(try await operation())) }
                catch { gate.finish(.failure(error)) }
            })
            gate.add(Task {
                do {
                    try await Task.sleep(for: .seconds(timeoutSeconds))
                    gate.finish(.failure(APIIntelligenceError.timedOut))
                } catch { }
            })
            if let invalidation {
                gate.add(Task {
                    do {
                        while true {
                            if invalidation.isCancelled { gate.finish(.failure(APIIntelligenceError.staleResponse)); return }
                            try await Task.sleep(for: .milliseconds(10))
                        }
                    } catch { }
                })
            }
            if let token {
                gate.add(Task {
                    do {
                        while true {
                            if token.isCancelled { gate.finish(.failure(APIIntelligenceError.cancelled)); return }
                            try await Task.sleep(for: .milliseconds(10))
                        }
                    } catch { }
                })
            }
        }
    } onCancel: { gate.finish(.failure(APIIntelligenceError.cancelled)) }
}
