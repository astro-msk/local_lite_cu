import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var number: Double? { if case .number(let v) = self { return v }; return nil }
    public var object: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }
    public var array: [JSONValue]? { if case .array(let v) = self { return v }; return nil }
    public var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
    public subscript(_ key: String) -> JSONValue { object?[key] ?? .null }
    public func encodedString() throws -> String { String(decoding: try JSONEncoder().encode(self), as: UTF8.self) }
}

public struct DesktopSnapshot: Sendable {
    public let imageDataURL: String
    public let width: Int
    public let height: Int
    public let context: String
    public init(imageDataURL: String, width: Int, height: Int, context: String) {
        self.imageDataURL = imageDataURL; self.width = width; self.height = height; self.context = context
    }
}

public struct DesktopAction: Equatable, Sendable {
    public let name: String
    public let arguments: JSONValue
    public init(name: String, arguments: JSONValue) { self.name = name; self.arguments = arguments }
    public var summary: String { arguments["reason"].string ?? name.replacingOccurrences(of: "_", with: " ") }
    public var isReadOnly: Bool { name == "observe" || name == "wait" }
}

@MainActor public protocol DesktopDriving: AnyObject {
    func snapshot() async throws -> DesktopSnapshot
    func execute(_ action: DesktopAction) async throws -> String
}

public struct RunConfiguration: Sendable {
    public var model: String
    public var apiKey: String
    public var demo: Bool
    public var confirmActions: Bool
    public var useSubagents: Bool
    public var maxSteps: Int
    public init(model: String = "gpt-6.1-sol", apiKey: String = "", demo: Bool = true, confirmActions: Bool = true, useSubagents: Bool = true, maxSteps: Int = 12) {
        self.model = model; self.apiKey = apiKey; self.demo = demo; self.confirmActions = confirmActions; self.useSubagents = useSubagents; self.maxSteps = maxSteps
    }
}

public struct RunEvent: Identifiable, Sendable {
    public let id = UUID()
    public let date = Date()
    public let role: String
    public let message: String
    public init(_ role: String, _ message: String) { self.role = role; self.message = message }
}

public enum LiteCUError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}
