import Foundation

public struct DecidedStep: Sendable {
    public let action: DesktopAction?
    public let clarification: ClarificationRequest?
    public let result: String
    public let requiresConfirmation: Bool

    public static func parse(_ text: String) throws -> DecidedStep {
        guard let data = text.data(using: .utf8), let json = try? JSONDecoder().decode(JSONValue.self, from: data),
              let name = json["action"].string, let reason = json["reason"].string,
              let result = json["result"].string, let confirmation = json["requires_confirmation"].bool,
              var args = json["arguments"].object else {
            throw LiteCUError.message("The model returned an invalid action. Nothing was executed.")
        }
        if name == "finish" {
            guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LiteCUError.message("The model returned an empty result.") }
            return DecidedStep(action: nil, clarification: nil, result: result, requiresConfirmation: false)
        }
        if name == "clarify" {
            let request = try ActionPolicy.clarification(from: args)
            return DecidedStep(action: nil, clarification: request, result: "", requiresConfirmation: false)
        }
        args["reason"] = .string(reason)
        let action = DesktopAction(name: name, arguments: .object(args))
        try ActionPolicy.validate(action)
        return DecidedStep(action: action, clarification: nil, result: result, requiresConfirmation: confirmation)
    }
}

public enum ActionPolicy {
    public static let names = ["observe", "open_app", "open_url", "click", "type_text", "press_key", "scroll", "browser_click", "browser_type", "browser_scroll", "wait", "clarify", "finish"]

    public static func clarification(from arguments: [String: JSONValue]) throws -> ClarificationRequest {
        guard let rawQuestion = arguments["question"]?.string,
              let values = arguments["options"]?.array, (2...4).contains(values.count) else {
            throw LiteCUError.message("A clarification needs a question and 2–4 options. Nothing was executed.")
        }
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, question.count <= 500 else {
            throw LiteCUError.message("The clarification question must contain 1–500 characters.")
        }
        var options: [String] = []
        for value in values {
            guard let rawOption = value.string else { throw LiteCUError.message("Clarification options must be text.") }
            let option = rawOption.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !option.isEmpty, option.count <= 120 else {
                throw LiteCUError.message("Each clarification option must contain 1–120 characters.")
            }
            options.append(option)
        }
        guard Set(options.map { $0.lowercased() }).count == options.count else {
            throw LiteCUError.message("Clarification options must be distinct.")
        }
        return ClarificationRequest(question: question, options: options)
    }
    public static func validate(_ action: DesktopAction) throws {
        func string(_ key: String, limit: Int = 4000) throws -> String {
            guard let value = action.arguments[key].string, !value.isEmpty, value.count <= limit else {
                throw LiteCUError.message("Invalid \(key) for \(action.name).")
            }
            return value
        }
        func number(_ key: String, range: ClosedRange<Double>) throws -> Double {
            guard let value = action.arguments[key].number, value.isFinite, range.contains(value) else { throw LiteCUError.message("Invalid \(key) for \(action.name).") }
            return value
        }
        switch action.name {
        case "observe": break
        case "open_app":
            let id = try string("bundle_id", limit: 200)
            guard id.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]+$", options: .regularExpression) != nil else { throw LiteCUError.message("Invalid app bundle identifier.") }
        case "open_url":
            let raw = try string("url")
            // Model citation delimiters are not part of a navigable address.
            guard !raw.unicodeScalars.contains(where: { (0xE200...0xE205).contains($0.value) }) else {
                throw LiteCUError.message("The URL contains model citation markers. Nothing was opened; retry with the exact address.")
            }
            guard let url = URL(string: raw), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
                  url.user == nil, url.password == nil else { throw LiteCUError.message("Only HTTP and HTTPS URLs without embedded credentials are supported.") }
        case "click":
            _ = try number("x", range: 0...10000); _ = try number("y", range: 0...10000)
            guard ["left", "right"].contains(try string("button")), action.arguments["double"].bool != nil else { throw LiteCUError.message("Invalid mouse button or click count.") }
        case "type_text": _ = try string("text")
        case "browser_click": _ = try string("element_id", limit: 100)
        case "browser_type":
            _ = try string("element_id", limit: 100)
            _ = try string("text")
        case "press_key": _ = try string("key", limit: 60)
        case "scroll", "browser_scroll":
            if action.name == "scroll" {
                _ = try number("x", range: 0...10000); _ = try number("y", range: 0...10000)
            }
            guard ["up", "down", "left", "right"].contains(try string("direction")) else { throw LiteCUError.message("Invalid scroll direction.") }
            let amount = try number("amount", range: 1...10)
            guard amount.rounded() == amount else { throw LiteCUError.message("Scroll amount must be a whole number.") }
        case "wait": _ = try number("seconds", range: 0...3)
        default: throw LiteCUError.message("Unsupported desktop action: \(action.name).")
        }
    }

    public static let schema: JSONValue = {
        func optional(_ type: String) -> JSONValue { .object(["type": .array([.string(type), .string("null")])]) }
        let fields: [String: JSONValue] = ["x": optional("number"), "y": optional("number"), "button": optional("string"), "double": optional("boolean"), "text": optional("string"), "key": optional("string"), "url": optional("string"), "bundle_id": optional("string"), "direction": optional("string"), "amount": optional("integer"), "seconds": optional("number"), "element_id": optional("string"), "question": optional("string"), "options": .object(["type": .array([.string("array"), .string("null")]), "items": .object(["type": .string("string")])])]
        return .object([
            "type": .string("object"), "additionalProperties": .bool(false),
            "properties": .object([
                "action": .object(["type": .string("string"), "enum": .array(names.map(JSONValue.string))]),
                "reason": .object(["type": .string("string")]),
                "result": .object(["type": .string("string")]),
                "requires_confirmation": .object(["type": .string("boolean")]),
                "arguments": .object(["type": .string("object"), "properties": .object(fields), "required": .array(fields.keys.sorted().map(JSONValue.string)), "additionalProperties": .bool(false)])
            ]),
            "required": .array(["action", "reason", "result", "requires_confirmation", "arguments"].map(JSONValue.string))
        ])
    }()
}
