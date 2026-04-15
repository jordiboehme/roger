import Foundation

struct OllamaService: LLMService {
    let providerType: LLMProviderType = .ollama
    let baseURL: String
    let model: String

    init(baseURL: String = "http://localhost:11434", model: String = "llama3.2") {
        self.baseURL = baseURL
        self.model = model
    }

    var isAvailable: Bool {
        get async {
            guard let url = URL(string: "\(baseURL)/api/tags") else { return false }
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                return (response as? HTTPURLResponse)?.statusCode == 200
            } catch {
                return false
            }
        }
    }

    func processText(_ text: String, prompt: String) async throws -> String {
        guard let url = URL(string: "\(baseURL)/v1/chat/completions") else {
            throw LLMError.providerUnavailable("Invalid Ollama URL")
        }

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": prompt],
                ["role": "user", "content": text],
            ],
            "stream": false,
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
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
