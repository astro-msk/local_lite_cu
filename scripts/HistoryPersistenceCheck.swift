import Foundation
import LiteCUCore

/// Uses a fresh temporary directory and never opens the app's real history.
@main struct HistoryPersistenceCheck {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("litecu-history-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RunHistoryStore(directory: directory)
        let start = Date(timeIntervalSince1970: 1_700_000_000.125)
        let end = start.addingTimeInterval(73.375)
        let nodes = [
            WorkflowNode(kind: .input, title: "Your command", detail: "Open a page", status: .complete,
                         startedAt: start, endedAt: start),
            WorkflowNode(kind: .planning, title: "Your input needed", detail: "Which page?",
                         notes: ["Option: Docs", "Option: Examples", "Your answer: Docs"], status: .complete,
                         startedAt: start, endedAt: start.addingTimeInterval(65)),
            WorkflowNode(kind: .action, title: "Open website", detail: "Opened the docs", notes: ["Task tab"], status: .complete,
                         action: DesktopAction(name: "open_url", arguments: .object(["url": .string("https://example.com/docs")])),
                         startedAt: start.addingTimeInterval(65), endedAt: end),
            WorkflowNode(kind: .result, title: "Result", detail: "Docs are visible.", status: .complete,
                         startedAt: end, endedAt: end)
        ]
        let modern = SavedRun(command: "Open a page", startedAt: start, modelName: "gpt-6.1-sol", backend: "Codex",
                              demoMode: false, stage: "Complete", result: "Docs are visible.", nodes: nodes,
                              stepCount: 1, maxSteps: 12, executionTarget: "Background Arc", endedAt: end)
        try store.save([modern])
        try require(try store.load() == [modern], "Modern run did not round-trip exactly.")

        // Model the original version-1 format by removing every newly added field.
        var document = try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as! [String: Any]
        var records = document["runs"] as! [[String: Any]]
        records[0].removeValue(forKey: "endedAt")
        records[0].removeValue(forKey: "executionTarget")
        var oldNodes = records[0]["nodes"] as! [[String: Any]]
        for index in oldNodes.indices {
            oldNodes[index].removeValue(forKey: "startedAt")
            oldNodes[index].removeValue(forKey: "endedAt")
        }
        records[0]["nodes"] = oldNodes
        document["runs"] = records
        let oldJSON = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        try oldJSON.write(to: store.fileURL, options: .atomic)

        var expectedLegacy = modern
        expectedLegacy.executionTarget = "Desktop"
        expectedLegacy.endedAt = nil
        expectedLegacy.nodes = modern.nodes.map { node in
            var legacy = node; legacy.startedAt = nil; legacy.endedAt = nil
            return legacy
        }
        let legacy = try store.load()
        try require(legacy == [expectedLegacy], "Old history lost content or did not use compatible defaults.")
        try require(try Data(contentsOf: store.fileURL) == oldJSON, "Reading old history unexpectedly rewrote it.")
        try require(legacy[0].nodes.allSatisfy { $0.elapsed() == nil }, "Old history invented elapsed durations.")

        var next = modern
        next.id = UUID(); next.startedAt = end.addingTimeInterval(60); next.endedAt = end.addingTimeInterval(120)
        try store.save(legacy + [next])
        try require(try store.load() == [next, expectedLegacy], "Saving a new timed run lost or changed old history.")
        print("History persistence passed: timestamp/target round-trip, original-format load without rewriting, and mixed old/new save.")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "HistoryPersistenceCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
}
