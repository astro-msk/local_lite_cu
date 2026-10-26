import Foundation

public protocol ModelClient: Sendable {
    func generate(instructions: String, prompt: String, snapshot: DesktopSnapshot?, schema: JSONValue?) async throws -> String
}

public struct OpenAIClient: ModelClient {
    private let model: String
    private let apiKey: String
    public init(model: String, apiKey: String) { self.model = model; self.apiKey = apiKey }

    public func generate(instructions: String, prompt: String, snapshot: DesktopSnapshot?, schema: JSONValue?) async throws -> String {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LiteCUError.message("Add an OpenAI API key in Settings, or choose Codex.")
        }
        var content: [JSONValue] = [.object(["type": .string("input_text"), "text": .string(prompt)])]
        if let snapshot {
            content.append(.object(["type": .string("input_image"), "image_url": .string(snapshot.imageDataURL), "detail": .string("high")]))
        }
        var body: [String: JSONValue] = [
            "model": .string(model), "instructions": .string(instructions),
            "input": .array([.object(["role": .string("user"), "content": .array(content)])]),
            "reasoning": .object(["effort": .string("low")]), "store": .bool(false),
            "max_output_tokens": .number(4000)
        ]
        if let schema {
            body["text"] = .object(["format": .object(["type": .string("json_schema"), "name": .string("desktop_step"), "strict": .bool(true), "schema": schema])])
        }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(JSONValue.object(body))
        let (data, response) = try await URLSession.shared.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw LiteCUError.message("No HTTP response from OpenAI.") }
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard (200..<300).contains(response.statusCode) else {
            throw LiteCUError.message("OpenAI \(response.statusCode): \(value["error"]["message"].string ?? "Request failed")")
        }
        guard value["status"].string == "completed" else { throw LiteCUError.message("The model response was incomplete. Try again with a smaller task.") }
        let output = (value["output"].array ?? []).flatMap { $0["content"].array ?? [] }
        if let refusal = output.first(where: { $0["type"].string == "refusal" }) {
            throw LiteCUError.message(refusal["refusal"].string ?? "The model declined this request.")
        }
        let text = output.filter { $0["type"].string == "output_text" }.compactMap { $0["text"].string }.joined(separator: "\n")
        guard !text.isEmpty else { throw LiteCUError.message("The model returned no text.") }
        return text
    }
}
