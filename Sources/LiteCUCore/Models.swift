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
    public let summary: String
    public init(imageDataURL: String, width: Int, height: Int, context: String, summary: String = "") {
        self.imageDataURL = imageDataURL; self.width = width; self.height = height; self.context = context; self.summary = summary
    }
}

public struct DesktopAction: Equatable, Sendable {
    public let name: String
    public let arguments: JSONValue
    public init(name: String, arguments: JSONValue) { self.name = name; self.arguments = arguments }
    public var summary: String { arguments["reason"].string ?? name.replacingOccurrences(of: "_", with: " ") }
    public var isReadOnly: Bool { name == "observe" || name == "wait" }
}

public struct ClarificationRequest: Equatable, Sendable {
    public let question: String
    public let options: [String]

    public init(question: String, options: [String]) {
        self.question = question
        self.options = options
    }
}

public enum WorkflowNodeKind: String, Equatable, Sendable {
    case input, planning, action, observation, result
}

public enum WorkflowNodeStatus: String, Equatable, Sendable {
    case active, awaitingApproval, complete, stopped, failed

    public var isTerminal: Bool {
        self == .complete || self == .stopped || self == .failed
    }
}

public struct WorkflowNode: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var kind: WorkflowNodeKind
    public var title: String
    public var detail: String
    public var notes: [String]
    public var status: WorkflowNodeStatus
    public var action: DesktopAction?
    public var startedAt: Date?
    public var endedAt: Date?

    public init(id: UUID = UUID(), kind: WorkflowNodeKind, title: String, detail: String = "", notes: [String] = [], status: WorkflowNodeStatus = .active, action: DesktopAction? = nil, startedAt: Date? = nil, endedAt: Date? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.detail = detail; self.notes = notes; self.status = status; self.action = action
        self.startedAt = startedAt; self.endedAt = endedAt
    }

    /// Wall time includes waiting for approvals or answers. Older saved nodes may
    /// have no timestamps; their duration remains unknown instead of growing.
    public func elapsed(at date: Date = Date()) -> TimeInterval? {
        guard let startedAt, let end = endedAt ?? (status.isTerminal ? nil : date) else { return nil }
        return max(0, end.timeIntervalSince(startedAt))
    }
}

@MainActor public protocol DesktopDriving: AnyObject {
    var executionInstructions: String { get }
    func snapshot() async throws -> DesktopSnapshot
    func execute(_ action: DesktopAction) async throws -> String
}

public extension DesktopDriving {
    var executionInstructions: String { "" }
}

public enum ApprovalMode: String, CaseIterable, Identifiable, Sendable {
    case everyAction = "Every action"
    case sensitiveActions = "Sensitive actions"
    case fullAccess = "Full access"

    public var id: String { rawValue }
}

public struct RunConfiguration: Sendable {
    public var model: String
    public var apiKey: String
    public var demo: Bool
    public var approvalMode: ApprovalMode
    public var useSubagents: Bool
    public var maxSteps: Int
    public init(model: String = "gpt-6.1-sol", apiKey: String = "", demo: Bool = true, approvalMode: ApprovalMode = .everyAction, useSubagents: Bool = true, maxSteps: Int = 12) {
        self.model = model; self.apiKey = apiKey; self.demo = demo; self.approvalMode = approvalMode; self.useSubagents = useSubagents; self.maxSteps = maxSteps
    }

    /// Preserves the original toggle's semantics: false still confirms sensitive actions.
    public init(model: String = "gpt-6.1-sol", apiKey: String = "", demo: Bool = true, confirmActions: Bool, useSubagents: Bool = true, maxSteps: Int = 12) {
        self.init(model: model, apiKey: apiKey, demo: demo, approvalMode: confirmActions ? .everyAction : .sensitiveActions, useSubagents: useSubagents, maxSteps: maxSteps)
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
