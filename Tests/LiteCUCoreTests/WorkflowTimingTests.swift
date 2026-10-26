import Foundation
import Testing
@testable import LiteCUCore

@Suite @MainActor struct WorkflowTimingTests {
    @Test func elapsedIsStableAfterCompletionAndUnknownForOldHistory() {
        let start = Date(timeIntervalSince1970: 100)
        var node = WorkflowNode(kind: .planning, title: "Plan", startedAt: start)
        #expect(node.elapsed(at: start.addingTimeInterval(65)) == 65)
        node.status = .awaitingApproval
        #expect(node.elapsed(at: start.addingTimeInterval(90)) == 90)
        node.status = .complete
        #expect(node.elapsed(at: start.addingTimeInterval(200)) == nil)
        node.endedAt = start.addingTimeInterval(100)
        #expect(node.elapsed(at: start.addingTimeInterval(999)) == 100)
        node.endedAt = start.addingTimeInterval(-10)
        #expect(node.elapsed() == 0)
        #expect(WorkflowNode(kind: .result, title: "Old result", status: .complete).elapsed() == nil)
    }

    @Test func actionTimeIncludesApprovalWithoutRestartingItsClock() async throws {
        let clock = TimingClock()
        let driver = TimingDesktop(clock: clock)
        let client = TimingClient(replies: [try decision("type_text", ["text": .string("hello")]), try decision("finish")])
        let runner = AgentRunner(driver: driver, client: client,
                                 configuration: RunConfiguration(demo: false, useSubagents: false), now: { clock.date })
        var updates: [[WorkflowNode]] = []
        runner.onWorkflow = { updates.append($0) }
        runner.approve = { _ in clock.advance(65); return true }

        _ = try await runner.run(command: "Type hello")

        let nodes = try #require(updates.last)
        let action = try #require(nodes.first { $0.kind == .action })
        #expect(action.elapsed() == 67) // 65 seconds awaiting approval, then two dispatching.
        let versions = updates.compactMap { $0.first { $0.id == action.id } }
        #expect(Set(versions.compactMap(\.startedAt)).count == 1)
        #expect(versions.filter { !$0.status.isTerminal }.allSatisfy { $0.endedAt == nil })
        #expect(nodes.allSatisfy { $0.startedAt != nil && $0.endedAt != nil })
        #expect(nodes.first { $0.kind == .planning }?.elapsed() == 2)
        #expect(nodes.last?.elapsed() == 0)
    }

    @Test func questionTimeIncludesTimeSpentChoosingAnAnswer() async throws {
        let clock = TimingClock()
        let driver = TimingDesktop(clock: clock)
        let client = TimingClient(replies: [
            try decision("clarify", ["question": .string("Which page?"), "options": .array([.string("Docs"), .string("Examples")])]),
            try decision("finish")
        ])
        let runner = AgentRunner(driver: driver, client: client,
                                 configuration: RunConfiguration(demo: false, approvalMode: .fullAccess, useSubagents: false), now: { clock.date })
        var nodes: [WorkflowNode] = []
        runner.onWorkflow = { nodes = $0 }
        runner.clarify = { _ in clock.advance(125); return "Docs" }

        _ = try await runner.run(command: "Read a page")

        let question = try #require(nodes.first { $0.title == "Your input needed" })
        #expect(question.status == .complete)
        #expect(question.elapsed() == 125)
        #expect(nodes.allSatisfy { $0.endedAt != nil })
    }

    @Test(arguments: [WorkflowNodeStatus.failed, .stopped])
    func terminationFreezesPendingSteps(status: WorkflowNodeStatus) async throws {
        let clock = TimingClock()
        let driver = TimingDesktop(clock: clock, failExecution: status == .failed)
        let client = TimingClient(replies: [try decision("type_text", ["text": .string("hello")])])
        let runner = AgentRunner(driver: driver, client: client,
                                 configuration: RunConfiguration(demo: false, useSubagents: false), now: { clock.date })
        var nodes: [WorkflowNode] = []
        runner.onWorkflow = { nodes = $0 }
        runner.approve = { _ in clock.advance(5); return status != .stopped }

        await #expect(throws: (any Error).self) { try await runner.run(command: "Type hello") }

        let action = try #require(nodes.first { $0.kind == .action })
        #expect(action.status == status)
        #expect(action.elapsed(at: clock.date.addingTimeInterval(1_000)) == (status == .failed ? 7 : 5))
        #expect(nodes.allSatisfy { $0.endedAt != nil && $0.status.isTerminal })
    }

    private func decision(_ name: String, _ arguments: [String: JSONValue] = [:]) throws -> String {
        try JSONValue.object([
            "action": .string(name), "arguments": .object(arguments), "reason": .string("Test step"),
            "requires_confirmation": .bool(false), "result": .string(name == "finish" ? "Finished." : "")
        ]).encodedString()
    }
}

@MainActor private final class TimingClock {
    var date = Date(timeIntervalSince1970: 1_000)
    func advance(_ seconds: TimeInterval) { date.addTimeInterval(seconds) }
}

@MainActor private final class TimingDesktop: DesktopDriving {
    let clock: TimingClock
    let failExecution: Bool

    init(clock: TimingClock, failExecution: Bool = false) { self.clock = clock; self.failExecution = failExecution }

    func snapshot() async throws -> DesktopSnapshot {
        clock.advance(1)
        return DesktopSnapshot(imageDataURL: "", width: 1, height: 1, context: "Visible test content")
    }

    func execute(_ action: DesktopAction) async throws -> String {
        clock.advance(2)
        if failExecution { throw LiteCUError.message("Test dispatch failure") }
        return "Typed hello"
    }
}

private actor TimingClient: ModelClient {
    var replies: [String]
    init(replies: [String]) { self.replies = replies }

    func generate(instructions: String, prompt: String, snapshot: DesktopSnapshot?, schema: JSONValue?) async throws -> String {
        if schema == nil { return "Take the requested step and verify it." }
        return replies.removeFirst()
    }
}
