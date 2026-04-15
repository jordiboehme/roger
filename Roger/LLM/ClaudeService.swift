import Foundation

struct ClaudeService: LLMService {
    let providerType: LLMProviderType = .claude
    let model: String

    init(model: String = "claude-sonnet-4-20250514") {
        self.model = model
    }

    var isAvailable: Bool {
        get async {
            KeychainManager.loadAPIKey(for: .claude) != nil
        }
    }

    func processText(_ text: String, prompt: String) async throws -> String {
        guard let apiKey = KeychainManager.loadAPIKey(for: .claude) else {
            throw LLMError.apiKeyMissing(.claude)
        }

        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw LLMError.providerUnavailable("Invalid API URL")
        }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "system": prompt,
            "messages": [
                ["role": "user", "content": text],
            ],
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 120

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.requestFailed("HTTP \(httpResponse.statusCode): \(body)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String
        else {
            throw LLMError.invalidResponse
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
