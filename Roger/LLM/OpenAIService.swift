import Foundation

struct OpenAIService: LLMService {
    let providerType: LLMProviderType = .openai
    let model: String

    init(model: String = "gpt-4o") {
        self.model = model
    }

    var isAvailable: Bool {
        get async {
            KeychainManager.loadAPIKey(for: .openai) != nil
        }
    }

    func processText(_ text: String, prompt: String) async throws -> String {
        guard let apiKey = KeychainManager.loadAPIKey(for: .openai) else {
            throw LLMError.apiKeyMissing(.openai)
        }

        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw LLMError.providerUnavailable("Invalid API URL")
        }

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": prompt],
                ["role": "user", "content": text],
            ],
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            throw LLMError.invalidResponse
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
