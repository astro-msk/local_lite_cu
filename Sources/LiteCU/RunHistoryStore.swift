import Foundation
import LiteCUCore

struct SavedRun: Identifiable, Equatable, Sendable {
    var id: UUID
    var command: String
    var startedAt: Date
    var endedAt: Date?
    var modelName: String
    var backend: String
    var demoMode: Bool
    var stage: String
    var result: String
    var nodes: [WorkflowNode]
    var stepCount: Int
    var maxSteps: Int
    var executionTarget: String

    init(id: UUID = UUID(), command: String, startedAt: Date = Date(), modelName: String,
         backend: String, demoMode: Bool, stage: String, result: String = "",
         nodes: [WorkflowNode] = [], stepCount: Int = 0, maxSteps: Int = 12, executionTarget: String = "Desktop", endedAt: Date? = nil) {
        self.id = id
        self.command = command
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.modelName = modelName
        self.backend = backend
        self.demoMode = demoMode
        self.stage = stage
        self.result = result
        self.nodes = nodes
        self.stepCount = stepCount
        self.maxSteps = maxSteps
        self.executionTarget = executionTarget
    }
}

/// Stores only run descriptions and graph nodes. Screenshots and API-key settings are excluded.
struct RunHistoryStore {
    static let maximumRuns = 100
    let fileURL: URL

    init(directory: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let folder = directory ?? support.appendingPathComponent("local.litecu.app", isDirectory: true)
        fileURL = folder.appendingPathComponent("runs.json", isDirectory: false)
    }

    func load() throws -> [SavedRun] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return newestRuns(try readDocument())
    }

    func save(_ runs: [SavedRun]) throws {
        // A failed load must not let the next completed run replace unreadable history silently.
        if FileManager.default.fileExists(atPath: fileURL.path) { _ = try readDocument() }
        do {
            let document = HistoryDocument(version: 1, runs: newestRuns(runs).map(RunRecord.init))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .millisecondsSince1970
            let data = try encoder.encode(document)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw HistoryError.write(error.localizedDescription)
        }
    }

    private func readDocument() throws -> [SavedRun] {
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let document = try decoder.decode(HistoryDocument.self, from: Data(contentsOf: fileURL))
            guard document.version == 1 else { throw HistoryError.unsupportedVersion(document.version) }
            return try document.runs.map { try $0.savedRun() }
        } catch let error as HistoryError {
            throw error
        } catch {
            throw HistoryError.read(error.localizedDescription)
        }
    }

    private func newestRuns(_ runs: [SavedRun]) -> [SavedRun] {
        let ordered = runs.enumerated().sorted {
            $0.element.startedAt == $1.element.startedAt ? $0.offset < $1.offset : $0.element.startedAt > $1.element.startedAt
        }
        var seen: Set<UUID> = []
        var newest: [SavedRun] = []
        for (_, run) in ordered where seen.insert(run.id).inserted {
            newest.append(run)
            if newest.count == Self.maximumRuns { break }
        }
        return newest
    }
}

private enum HistoryError: LocalizedError {
    case read(String)
    case write(String)
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .read(let detail):
            return "Could not read previous runs. The existing runs.json file was left unchanged. \(detail)"
        case .write(let detail):
            return "Could not save this run to previous runs. The current result is still available in this chat. \(detail)"
        case .unsupportedVersion(let version):
            return "Previous runs use history format \(version), which this version of Lite CU cannot read. The existing runs.json file was left unchanged."
        }
    }
}

private struct HistoryDocument: Codable {
    let version: Int
    let runs: [RunRecord]
}

private struct RunRecord: Codable {
    let id: UUID
    let command: String
    let startedAt: Date
    let endedAt: Date?
    let modelName: String
    let backend: String
    let demoMode: Bool
    let stage: String
    let result: String
    let nodes: [NodeRecord]
    let stepCount: Int
    let maxSteps: Int
    let executionTarget: String?

    init(_ run: SavedRun) {
        id = run.id
        command = run.command
        startedAt = run.startedAt
        endedAt = run.endedAt
        modelName = run.modelName
        backend = run.backend
        demoMode = run.demoMode
        stage = run.stage
        result = run.result
        nodes = run.nodes.map(NodeRecord.init)
        stepCount = run.stepCount
        maxSteps = run.maxSteps
        executionTarget = run.executionTarget
    }

    func savedRun() throws -> SavedRun {
        SavedRun(id: id, command: command, startedAt: startedAt, modelName: modelName, backend: backend,
                 demoMode: demoMode, stage: stage, result: result, nodes: try nodes.map { try $0.node() },
                 stepCount: stepCount, maxSteps: maxSteps, executionTarget: executionTarget ?? "Desktop", endedAt: endedAt)
    }
}

private struct NodeRecord: Codable {
    let id: UUID
    let kind: String
    let title: String
    let detail: String
    let notes: [String]
    let status: String
    let action: ActionRecord?
    let startedAt: Date?
    let endedAt: Date?

    init(_ node: WorkflowNode) {
        id = node.id
        kind = node.kind.rawValue
        title = node.title
        detail = node.detail
        notes = node.notes
        status = node.status.rawValue
        action = node.action.map(ActionRecord.init)
        startedAt = node.startedAt
        endedAt = node.endedAt
    }

    func node() throws -> WorkflowNode {
        guard let kind = WorkflowNodeKind(rawValue: kind), let status = WorkflowNodeStatus(rawValue: status) else {
            throw HistoryError.read("A saved workflow step has an unrecognized type or status.")
        }
        return WorkflowNode(id: id, kind: kind, title: title, detail: detail, notes: notes, status: status,
                            action: action.map { DesktopAction(name: $0.name, arguments: $0.arguments) }, startedAt: startedAt, endedAt: endedAt)
    }
}

private struct ActionRecord: Codable {
    let name: String
    let arguments: JSONValue

    init(_ action: DesktopAction) {
        name = action.name
        arguments = action.arguments
    }
}
