import Foundation
import Testing
@testable import LiteCUCore

@Suite
@MainActor
struct ClarificationTests {
    @Test(arguments: ApprovalMode.allCases)
    func pausesForAnswerThenContinuesWithFreshObservationWithoutSpendingActionBudget(mode: ApprovalMode) async throws {
        let desktop = ClarificationDesktop()
        let client = ClarificationClient(replies: [try question(), try action("open_url", ["url": .string("https://example.com/docs")]), try finish()])
        let runner = AgentRunner(driver: desktop, client: client, configuration: RunConfiguration(demo: false, approvalMode: mode, useSubagents: false, maxSteps: 1))
        let gate = ClarificationGate()
        runner.clarify = { await gate.receive($0) }
        var approvals = 0
        runner.approve = { _ in approvals += 1; return true }
        var nodes: [WorkflowNode] = []
        var steps: [Int] = []
        var stage = ""
        runner.onWorkflow = { nodes = $0 }
        runner.onStep = { steps.append($0) }
        runner.onStage = { stage = $0 }

        let run = Task { try await runner.run(command: "Open the documentation I mean") }
        await gate.waitUntilAsked()

        #expect(gate.request == ClarificationRequest(question: "Which documentation do you want?", options: ["API reference", "Getting started"]))
        #expect(desktop.actions.isEmpty)
        #expect(desktop.snapshotCount == 2)
        #expect(steps.isEmpty)
        #expect(stage == "Awaiting input")
        #expect(nodes.last?.title == "Your input needed")
        #expect(nodes.last?.status == .awaitingApproval)
        let pausedCalls = await client.calls
        #expect(pausedCalls.filter(\.structured).count == 1)
        let questionID = try #require(nodes.last?.id)

        gate.answer("  Research documentation  ")
        let result = try await run.value

        #expect(result == "Finished from the observed page.")
        #expect(desktop.actions.map(\.name) == ["open_url"])
        #expect(steps == [1])
        #expect(approvals == (mode == .everyAction ? 1 : 0))
        #expect(nodes.first { $0.id == questionID }?.status == .complete)
        #expect(nodes.first { $0.id == questionID }?.notes.contains("Your answer: Research documentation") == true)
        #expect(nodes.contains { $0.title == "Observe after your answer" })
        let calls = await client.calls
        let structured = calls.filter(\.structured)
        #expect(structured.map(\.snapshot) == ["View 2", "View 3", "View 4"])
        #expect(structured[1].prompt.contains("Which documentation do you want?"))
        #expect(structured[1].prompt.contains("Research documentation"))
        #expect(structured[2].prompt.contains("Action budget exhausted"))
    }

    @Test
    func decliningQuestionStopsWithoutDispatchOrAnotherCapture() async throws {
        let desktop = ClarificationDesktop()
        let client = ClarificationClient(replies: [try question()])
        let runner = runner(desktop, client)
        var nodes: [WorkflowNode] = []
        runner.onWorkflow = { nodes = $0 }
        runner.clarify = { _ in nil }

        await #expect(throws: CancellationError.self) { try await runner.run(command: "Choose a page") }

        #expect(desktop.actions.isEmpty)
        #expect(desktop.snapshotCount == 2)
        #expect(nodes.first { $0.title == "Your input needed" }?.status == .stopped)
        #expect(nodes.last?.status == .stopped)
    }

    @Test
    func cancellationRejectsAnAnswerDeliveredAfterStop() async throws {
        let desktop = ClarificationDesktop()
        let client = ClarificationClient(replies: [try question(), try action("open_url", ["url": .string("https://example.com")])])
        let runner = runner(desktop, client)
        let gate = ClarificationGate()
        runner.clarify = { await gate.receive($0) }
        var nodes: [WorkflowNode] = []
        runner.onWorkflow = { nodes = $0 }
        let run = Task { try await runner.run(command: "Choose a page") }
        await gate.waitUntilAsked()

        run.cancel()
        gate.answer("API reference")
        await #expect(throws: CancellationError.self) { try await run.value }

        #expect(desktop.actions.isEmpty)
        #expect(desktop.snapshotCount == 2)
        #expect(nodes.first { $0.title == "Your input needed" }?.status == .stopped)
        #expect(!nodes.contains { $0.notes.contains("Your answer: API reference") })
        let calls = await client.calls
        #expect(calls.filter(\.structured).count == 1)
    }

    @Test(arguments: ["", " \n ", String(repeating: "a", count: 2001)])
    func invalidAnswersCannotContinue(answer: String) async throws {
        let desktop = ClarificationDesktop()
        let client = ClarificationClient(replies: [try question()])
        let runner = runner(desktop, client)
        runner.clarify = { _ in answer }
        var nodes: [WorkflowNode] = []
        runner.onWorkflow = { nodes = $0 }

        await #expect(throws: (any Error).self) { try await runner.run(command: "Choose a page") }

        #expect(desktop.actions.isEmpty)
        #expect(desktop.snapshotCount == 2)
        #expect(nodes.last?.status == .failed)
    }

    @Test
    func clarificationCountIsBoundedIndependentlyOfActions() async throws {
        let desktop = ClarificationDesktop()
        let client = ClarificationClient(replies: Array(repeating: try question(), count: AgentRunner.maximumClarifications + 1))
        let runner = runner(desktop, client)
        var asked = 0
        runner.clarify = { _ in asked += 1; return "API reference" }

        await #expect(throws: (any Error).self) { try await runner.run(command: "Choose a page") }

        #expect(asked == AgentRunner.maximumClarifications)
        #expect(desktop.actions.isEmpty)
        #expect(desktop.snapshotCount == 2 + AgentRunner.maximumClarifications)
        let calls = await client.calls
        #expect(calls.filter(\.structured).last?.prompt.contains("Clarifications remaining: 0.") == true)
    }

    @Test
    func answeringDoesNotResetAnExhaustedActionBudget() async throws {
        let desktop = ClarificationDesktop()
        let client = ClarificationClient(replies: [
            try action("open_url", ["url": .string("https://example.com")]),
            try question(),
            try action("open_url", ["url": .string("https://example.com/docs")])
        ])
        let runner = runner(desktop, client)
        var asked = 0
        runner.clarify = { _ in asked += 1; return "API reference" }

        await #expect(throws: (any Error).self) { try await runner.run(command: "Find a page") }

        #expect(asked == 1)
        #expect(desktop.actions.count == 1)
        let calls = await client.calls
        #expect(calls.filter(\.structured).last?.prompt.contains("Action budget exhausted") == true)
    }

    @Test
    func failedRefreshAfterAnswerCannotDispatchFromOldObservation() async throws {
        let desktop = ClarificationDesktop()
        desktop.failOnSnapshot = 3
        let client = ClarificationClient(replies: [try question(), try action("open_url", ["url": .string("https://example.com")])])
        let runner = runner(desktop, client)
        runner.clarify = { _ in "API reference" }
        var nodes: [WorkflowNode] = []
        runner.onWorkflow = { nodes = $0 }

        await #expect(throws: (any Error).self) { try await runner.run(command: "Choose a page") }

        #expect(desktop.actions.isEmpty)
        #expect(nodes.first { $0.title == "Your input needed" }?.status == .complete)
        #expect(nodes.first { $0.title == "Observe after your answer" }?.status == .failed)
        let calls = await client.calls
        #expect(calls.filter(\.structured).count == 1)
    }

    @Test
    func executionEnvironmentReachesAllPlannersAndBrowserActionLoop() async throws {
        let desktop = ClarificationDesktop()
        desktop.executionInstructions = "Use only background browser elements from this observation."
        let client = ClarificationClient(replies: [
            try action("browser_type", ["element_id": .string("fresh:1"), "text": .string("hello")]),
            try action("browser_click", ["element_id": .string("next:2")]),
            try action("browser_scroll", ["direction": .string("down"), "amount": .number(2)]),
            try finish()
        ])
        let runner = AgentRunner(driver: desktop, client: client, configuration: RunConfiguration(demo: false, approvalMode: .fullAccess, useSubagents: true, maxSteps: 3))

        _ = try await runner.run(command: "Search the page")

        #expect(desktop.actions.map(\.name) == ["browser_type", "browser_click", "browser_scroll"])
        let calls = await client.calls
        #expect(calls.count == 7)
        #expect(calls.allSatisfy { $0.instructions.contains(desktop.executionInstructions) })
    }

    private func runner(_ desktop: ClarificationDesktop, _ client: ClarificationClient) -> AgentRunner {
        AgentRunner(driver: desktop, client: client, configuration: RunConfiguration(demo: false, approvalMode: .fullAccess, useSubagents: false, maxSteps: 1))
    }

    private func question() throws -> String {
        try action("clarify", ["question": .string("Which documentation do you want?"), "options": .array([.string("API reference"), .string("Getting started")])])
    }

    private func action(_ name: String, _ arguments: [String: JSONValue]) throws -> String {
        try JSONValue.object(["action": .string(name), "arguments": .object(arguments), "reason": .string("Continue the requested task"), "requires_confirmation": .bool(false), "result": .string("")]).encodedString()
    }

    private func finish() throws -> String {
        try JSONValue.object(["action": .string("finish"), "arguments": .object([:]), "reason": .string("Read the current page"), "requires_confirmation": .bool(false), "result": .string("Finished from the observed page.")]).encodedString()
    }
}

@MainActor
private final class ClarificationGate {
    private(set) var request: ClarificationRequest?
    private var continuation: CheckedContinuation<String?, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func receive(_ request: ClarificationRequest) async -> String? {
        self.request = request
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }

    func waitUntilAsked() async {
        if request != nil { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func answer(_ value: String?) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: value)
    }
}

@MainActor
private final class ClarificationDesktop: DesktopDriving {
    var executionInstructions = ""
    private(set) var snapshotCount = 0
    private(set) var actions: [DesktopAction] = []
    var failOnSnapshot: Int?

    func snapshot() async throws -> DesktopSnapshot {
        try Task.checkCancellation()
        snapshotCount += 1
        if snapshotCount == failOnSnapshot { throw LiteCUError.message("Fresh observation unavailable") }
        return DesktopSnapshot(imageDataURL: "", width: 100, height: 80, context: "View \(snapshotCount)", summary: "Page \(snapshotCount)")
    }

    func execute(_ action: DesktopAction) async throws -> String {
        try Task.checkCancellation()
        actions.append(action)
        return "Dispatched \(action.name)"
    }
}

private actor ClarificationClient: ModelClient {
    struct Call: Sendable {
        let instructions: String
        let prompt: String
        let snapshot: String
        let structured: Bool
    }
    private var replies: [String]
    private(set) var calls: [Call] = []

    init(replies: [String]) { self.replies = replies }

    func generate(instructions: String, prompt: String, snapshot: DesktopSnapshot?, schema: JSONValue?) async throws -> String {
        try Task.checkCancellation()
        calls.append(Call(instructions: instructions, prompt: prompt, snapshot: snapshot?.context ?? "", structured: schema != nil))
        guard schema != nil else { return "1. Resolve the user's choice.\n2. Open the selected page and verify it." }
        guard !replies.isEmpty else { throw LiteCUError.message("No scripted decision remains") }
        return replies.removeFirst()
    }
}
