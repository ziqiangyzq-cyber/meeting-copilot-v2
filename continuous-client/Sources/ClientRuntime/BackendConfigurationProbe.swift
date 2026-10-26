import Foundation
import APIIntelligence

public protocol BackendConfigurationProbing {
    func test(settings: BackendAPISettings, secret: String) async throws
}

public struct BackendConfigurationProbe: BackendConfigurationProbing {
    private let transport: any APIHTTPTransport
    public init(transport: any APIHTTPTransport = URLSessionAPITransport()) {
        self.transport = transport
    }

    public func test(settings: BackendAPISettings, secret: String) async throws {
        guard let base = URL(string: settings.baseURL), !secret.isEmpty else {
            throw APIIntelligenceError.invalidConfiguration
        }
        try APIIntelligenceConfiguration(baseURL: base, modelID: settings.modelID,
                                        credentialReference: "CONFIGURATION_TEST").validate()
        var request = URLRequest(url: base.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + secret, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": settings.modelID,
            "messages": [["role": "user", "content": "Reply with OK only."]],
            "max_tokens": 64,
            "stream": false
        ])
        // The production transport rejects redirects and limits response size. No meeting text is sent.
        let response = try await transport.send(request, maximumResponseBytes: 65_536)
        guard (200...299).contains(response.statusCode) else {
            throw APIIntelligenceError.httpRejected(status: response.statusCode)
        }
        guard let object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              message["role"] as? String == "assistant",
              let content = message["content"] as? String,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIIntelligenceError.invalidResponse
        }
    }
}
