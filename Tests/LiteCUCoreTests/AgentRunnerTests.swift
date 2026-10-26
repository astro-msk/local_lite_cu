import Foundation
import Testing
@testable import LiteCUCore

@Suite
@MainActor
struct AgentRunnerTests {
    @Test
    func testActionIsFollowedByFreshObservationBeforeFinish() async throws {
        let driver = RecordingDesktop()
        let client = ScriptedClient(replies: [try step("open_app", ["bundle_id": .string("com.apple.Safari")]), try finish()])
        let runner = AgentRunner(driver: driver, client: client, configuration: configuration(maxSteps: 1))
        var completedSteps: [Int] = []
        runner.onStep = { completedSteps.append($0) }

        let result = try await runner.run(command: "Open Safari")

        #expect(result == "Verified completion.")
        #expect(driver.actions.map(\.name) == ["open_app"])
        #expect(driver.snapshotCount == 3)
        #expect(completedSteps == [1])
        let calls = await client.calls
        let executorCalls = calls.filter(\.structured)
        #expect(executorCalls.map(\.snapshotContext) == ["Observation 2, after 0 actions", "Observation 3, after 1 actions"])
        #expect(executorCalls.last?.prompt.contains("Action budget exhausted") == true)
        #expect(executorCalls.last?.prompt.contains("dispatch 1 succeeded") == true)
    }

    @Test
    func testDeniedApprovalDoesNotDispatchAnAction() async throws {
        let driver = RecordingDesktop()
        let client = ScriptedClient(replies: [try step("type_text", ["text": .string("hello")])])
        let runner = AgentRunner(driver: driver, client: client, configuration: configuration(approvalMode: .everyAction))
        var approvalCount = 0
        var workflow: [WorkflowNode] = []
        runner.onWorkflow = { workflow = $0 }
        runner.approve = { _ in approvalCount += 1; return false }

        do {
            _ = try await runner.run(command: "Type hello")
            Issue.record("A denied action must stop the run.")
        } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }

        #expect(approvalCount == 1)
        #expect(driver.actions.isEmpty)
        #expect(driver.snapshotCount == 2)
        #expect(workflow.map(\.kind) == [.input, .planning, .action, .result])
        #expect(workflow.first { $0.kind == .action }?.status == .stopped)
        #expect(workflow.last?.status == .stopped)
    }

    @Test
    func testSensitiveModeHonorsModelRequiredConfirmation() async throws {
        let driver = RecordingDesktop()
        let client = ScriptedClient(replies: [try step("press_key", ["key": .string("return")], requiresConfirmation: true)])
        let runner = AgentRunner(driver: driver, client: client, configuration: configuration(approvalMode: .sensitiveActions))
        var requestedApproval = false
        runner.approve = { _ in requestedApproval = true; return false }

        do {
            _ = try await runner.run(command: "Submit the form")
            Issue.record("Required confirmation must be respected.")
        } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }

        #expect(requestedApproval)
        #expect(driver.actions.isEmpty)
    }

    @Test(arguments: ApprovalMode.allCases, [false, true])
    func testApprovalModeControlsLiveActionPrompts(mode: ApprovalMode, modelRequiresConfirmation: Bool) async throws {
        let driver = RecordingDesktop()
        let client = ScriptedClient(replies: [
            try step("type_text", ["text": .string("hello")], requiresConfirmation: modelRequiresConfirmation),
            try finish()
        ])
        let config = RunConfiguration(demo: false, approvalMode: mode, useSubagents: false, maxSteps: 1)
        let runner = AgentRunner(driver: driver, client: client, configuration: config)
        var approvalCount = 0
        runner.approve = { _ in approvalCount += 1; return true }

        let result = try await runner.run(command: "Type hello")

        let expectedPrompts = mode == .everyAction || (mode == .sensitiveActions && modelRequiresConfirmation) ? 1 : 0
        #expect(approvalCount == expectedPrompts)
        #expect(driver.actions.map(\.name) == ["type_text"])
        #expect(result == "Verified completion.")
    }

    @Test(arguments: ApprovalMode.allCases)
    func testReadOnlyActionsAndDemoNeverAskForApproval(mode: ApprovalMode) async throws {
        for demo in [false, true] {
            let driver = RecordingDesktop()
            let name = demo ? "type_text" : "observe"
            let args: [String: JSONValue] = demo ? ["text": .string("Simulated text")] : [:]
            let client = ScriptedClient(replies: [try step(name, args, requiresConfirmation: true), try finish()])
            let config = RunConfiguration(demo: demo, approvalMode: mode, useSubagents: false, maxSteps: 1)
            let runner = AgentRunner(driver: driver, client: client, configuration: config)
            var approvalCount = 0
            runner.approve = { _ in approvalCount += 1; return false }

            _ = try await runner.run(command: "Inspect the page")

            #expect(approvalCount == 0)
            #expect(driver.actions.count == 1)
        }
    }

    @Test
    func testFullAccessStillRejectsInvalidActionsBeforeDispatch() async throws {
        let invalidActions: [DesktopAction] = [
            DesktopAction(name: "run_script", arguments: .object(["command": .string("pwd")])),
            DesktopAction(name: "open_url", arguments: .object(["url": .string("file:///etc/passwd")])),
            DesktopAction(name: "click", arguments: .object(["y": .number(20), "button": .string("left"), "double": .bool(false)]))
        ]
        for invalid in invalidActions {
            let driver = RecordingDesktop()
            let client = ScriptedClient(replies: [try step(invalid.name, invalid.arguments.object ?? [:], requiresConfirmation: true)])
            let config = RunConfiguration(demo: false, approvalMode: .fullAccess, useSubagents: false)
            let runner = AgentRunner(driver: driver, client: client, configuration: config)
            var workflow: [WorkflowNode] = []
            runner.onWorkflow = { workflow = $0 }
            var approvalCount = 0
            runner.approve = { _ in approvalCount += 1; return true }

            await #expect(throws: (any Error).self) { try await runner.run(command: "Perform the requested action") }

            #expect(driver.actions.isEmpty)
            #expect(approvalCount == 0)
            #expect(!workflow.contains { $0.kind == .action })
            #expect(workflow.last?.status == .failed)
        }
    }

    @Test
    func testCancellationBeforeRunDoesNotCaptureOrCallModel() async throws {
        let driver = RecordingDesktop()
        let client = ScriptedClient(replies: [try finish()])
        let runner = AgentRunner(driver: driver, client: client, configuration: configuration())
        let task = Task { try await runner.run(command: "Open Safari") }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("A cancelled run must not start.")
        } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }

        #expect(driver.snapshotCount == 0)
        #expect(driver.actions.isEmpty)
        let calls = await client.calls
        #expect(calls.isEmpty)
    }

    @Test
    func testCancellationDuringModelRequestCancelsRequestAndDoesNotAct() async throws {
        let driver = RecordingDesktop()
        let client = CancellationClient()
        let runner = AgentRunner(driver: driver, client: client, configuration: configuration())
        var workflow: [WorkflowNode] = []
        runner.onWorkflow = { workflow = $0 }
        let task = Task { try await runner.run(command: "Open Safari") }
        await client.waitUntilRequestBegins()
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Cancellation must interrupt the model request.")
        } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }

        #expect(driver.actions.isEmpty)
        let modelWasCancelled = await client.wasCancelled
        #expect(modelWasCancelled)
        #expect(workflow.map(\.kind) == [.input, .planning, .result])
        #expect(workflow.first { $0.kind == .planning }?.status == .stopped)
        #expect(workflow.last?.status == .stopped)
    }

    @Test
    func testCancellationImmediatelyAfterApprovalStillPreventsDispatch() async throws {
        let driver = RecordingDesktop()
        let client = ScriptedClient(replies: [try step("press_key", ["key": .string("return")])])
        let runner = AgentRunner(driver: driver, client: client, configuration: configuration(approvalMode: .everyAction))
        runner.approve = { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return true
        }
        let task = Task { try await runner.run(command: "Submit") }

        do {
            _ = try await task.value
            Issue.record("A cancelled task must not dispatch even after approval returned true.")
        } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }

        #expect(driver.actions.isEmpty)
    }

    @Test
    func testBudgetAllowsFinalResultButNeverAnotherAction() async throws {
        let driver = RecordingDesktop()
        let client = ScriptedClient(replies: [
            try step("press_key", ["key": .string("tab")]),
            try step("press_key", ["key": .string("return")])
        ])
        let runner = AgentRunner(driver: driver, client: client, configuration: configuration(maxSteps: 1))
        var workflow: [WorkflowNode] = []
        runner.onWorkflow = { workflow = $0 }

        do {
            _ = try await runner.run(command: "Move through the form")
            Issue.record("The second action exceeds the action budget.")
        } catch {
            #expect(error.localizedDescription.contains("1-action limit"))
        }

        #expect(driver.actions.map { $0.arguments["key"].string } == ["tab"])
        #expect(driver.snapshotCount == 3)
        let calls = await client.calls
        #expect(calls.filter(\.structured).count == 2)
        #expect(workflow.filter { $0.kind == .action }.count == 1)
        #expect(workflow.last?.status == .failed)
    }

    @Test
    func testThirdIdenticalActionStopsEvenWhenReasonChanges() async throws {
        let driver = RecordingDesktop()
        let client = ScriptedClient(replies: try (1...3).map {
            try step("press_key", ["key": .string("tab")], reason: "Different reason \($0)")
        })
        let runner = AgentRunner(driver: driver, client: client, configuration: configuration(maxSteps: 10))

        do {
            _ = try await runner.run(command: "Find the field")
            Issue.record("Three identical actions must stop the loop.")
        } catch {
            #expect(error.localizedDescription.contains("repeated identical actions"))
        }

        #expect(driver.actions.count == 2)
        #expect(driver.snapshotCount == 4)
    }

    @Test
    func testParallelAssistantsReceiveSameObservationAndCannotDispatchActions() async throws {
        let driver = RecordingDesktop()
        let client = ScriptedClient(replies: [try finish()], overlapPlanningCalls: true)
        var config = configuration()
        config.useSubagents = true
        let runner = AgentRunner(driver: driver, client: client, configuration: config)
        var planningUpdates: [WorkflowNode] = []
        runner.onWorkflow = { nodes in
            if let planning = nodes.first(where: { $0.kind == .planning }) { planningUpdates.append(planning) }
        }

        _ = try await runner.run(command: "Inspect the page")

        let calls = await client.calls
        let assistants = calls.filter { $0.instructions.contains("read-only planning assistant") }
        #expect(assistants.count == 2)
        #expect(assistants.allSatisfy { !$0.structured && $0.instructions.contains("Do not perform actions or invoke any tools") })
        #expect(Set(assistants.map(\.snapshotContext)) == ["Observation 1, after 0 actions"])
        let concurrentPlanners = await client.maximumConcurrentPlanners
        #expect(concurrentPlanners == 2)
        #expect(driver.actions.isEmpty)
        #expect(driver.snapshotCount == 2)
        let coordinator = calls.first { $0.instructions.contains("You are the coordinator") }
        #expect(coordinator?.prompt.contains("Route planner:") == true)
        #expect(coordinator?.prompt.contains("Verifier:") == true)
        let advisorCounts = planningUpdates.map { node in
            node.notes.filter { $0.hasPrefix("Route planner:") || $0.hasPrefix("Verifier:") }.count
        }
        #expect(advisorCounts.contains(1))
        #expect(advisorCounts.contains(2))
        #expect(planningUpdates.last?.status == .complete)
    }

    @Test
    func testWorkflowShowsActualActionObservationOrderAndApprovalTransitions() async throws {
        let driver = RecordingDesktop()
        let client = ScriptedClient(replies: [
            try step("type_text", ["text": .string("hello")], reason: "Fill the visible search field"),
            try step("press_key", ["key": .string("return")], reason: "Search for the entered text"),
            try finish()
        ])
        let runner = AgentRunner(driver: driver, client: client, configuration: configuration(approvalMode: .everyAction))
        var updates: [(nodes: [WorkflowNode], dispatched: Int)] = []
        runner.onWorkflow = { updates.append(($0, driver.actions.count)) }
        runner.approve = { _ in
            #expect(updates.last?.nodes.last?.status == .awaitingApproval)
            return true
        }

        _ = try await runner.run(command: "Search for hello")

        let nodes = try #require(updates.last?.nodes)
        #expect(nodes.map(\.kind) == [.input, .planning, .action, .observation, .action, .observation, .result])
        #expect(nodes.allSatisfy { $0.status == .complete })
        #expect(Set(nodes.map(\.id)).count == nodes.count)
        let actions = nodes.filter { $0.kind == .action }
        #expect(actions.map(\.title) == ["Type text", "Press keys"])
        #expect(actions[0].detail.contains("Fill the visible search field"))
        #expect(actions[0].detail.contains("dispatch 1 succeeded"))
        #expect(actions[0].notes.contains("Text: hello"))
        for action in actions {
            let statuses = updates.compactMap { $0.nodes.first { $0.id == action.id }?.status }
                .reduce(into: [WorkflowNodeStatus]()) { if $0.last != $1 { $0.append($1) } }
            #expect(statuses == [.active, .awaitingApproval, .active, .complete])
        }
        for update in updates {
            let completedActions = update.nodes.filter { $0.kind == .action && $0.status == .complete }.count
            #expect(completedActions <= update.dispatched)
        }
        let observations = nodes.filter { $0.kind == .observation }
        #expect(observations.map(\.detail) == ["Visible app after 1 actions", "Visible app after 2 actions"])
        #expect(observations[0].notes.contains("Next: Search for the entered text"))
        #expect(nodes.last?.detail == "Verified completion.")
    }

    @Test
    func testWorkflowKeepsCompletedActionWhenObservationIsCancelled() async throws {
        let driver = RecordingDesktop()
        let client = CancellationClient(firstAction: try step("type_text", ["text": .string("hello")]))
        let runner = AgentRunner(driver: driver, client: client, configuration: configuration())
        var workflow: [WorkflowNode] = []
        runner.onWorkflow = { workflow = $0 }
        let task = Task { try await runner.run(command: "Type hello and verify it") }
        await client.waitUntilRequestBegins()
        #expect(workflow.last?.kind == .observation)
        #expect(workflow.last?.status == .active)
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }

        #expect(driver.actions.count == 1)
        #expect(workflow.map(\.kind) == [.input, .planning, .action, .observation, .result])
        #expect(workflow.first { $0.kind == .action }?.status == .complete)
        #expect(workflow.first { $0.kind == .observation }?.status == .stopped)
        #expect(workflow.last?.status == .stopped)
    }

    @Test(arguments: [false, true])
    func testWorkflowFailureReflectsWhetherDispatchCompleted(failsDuringObservation: Bool) async throws {
        let driver = RecordingDesktop()
        driver.failOnExecution = !failsDuringObservation
        driver.failOnSnapshot = failsDuringObservation ? 3 : nil
        let client = ScriptedClient(replies: [try step("type_text", ["text": .string("hello")])])
        let runner = AgentRunner(driver: driver, client: client, configuration: configuration())
        var workflow: [WorkflowNode] = []
        runner.onWorkflow = { workflow = $0 }

        await #expect(throws: (any Error).self) { try await runner.run(command: "Type hello") }

        #expect(workflow.first { $0.kind == .action }?.status == (failsDuringObservation ? .complete : .failed))
        #expect(driver.actions.count == (failsDuringObservation ? 1 : 0))
        if failsDuringObservation {
            #expect(workflow.first { $0.kind == .observation }?.status == .failed)
        } else {
            #expect(!workflow.contains { $0.kind == .observation })
        }
        #expect(workflow.last?.kind == .result)
        #expect(workflow.last?.status == .failed)
        #expect(!workflow.contains { $0.status == .active || $0.status == .awaitingApproval })
    }

    @Test
    func testExplicitObservationIsNotDisplayedAsDesktopInput() async throws {
        let driver = RecordingDesktop()
        driver.includeSummary = false
        let client = ScriptedClient(replies: [try step("observe", reason: "Read the current page"), try finish()])
        let runner = AgentRunner(driver: driver, client: client, configuration: configuration())
        var workflow: [WorkflowNode] = []
        runner.onWorkflow = { workflow = $0 }

        _ = try await runner.run(command: "Inspect this page")

        #expect(workflow.map(\.kind) == [.input, .planning, .observation, .result])
        let observation = try #require(workflow.first { $0.kind == .observation })
        #expect(observation.detail == "Captured current desktop")
        #expect(observation.action?.name == "observe")
        #expect(observation.status == .complete)
    }

    private func configuration(approvalMode: ApprovalMode = .sensitiveActions, maxSteps: Int = 8) -> RunConfiguration {
        RunConfiguration(demo: false, approvalMode: approvalMode, useSubagents: false, maxSteps: maxSteps)
    }

    private func step(_ name: String, _ arguments: [String: JSONValue] = [:], reason: String = "Take the next step", requiresConfirmation: Bool = false) throws -> String {
        try JSONValue.object([
            "action": .string(name), "arguments": .object(arguments), "reason": .string(reason),
            "requires_confirmation": .bool(requiresConfirmation), "result": .string("")
        ]).encodedString()
    }

    private func finish() throws -> String {
        try JSONValue.object([
            "action": .string("finish"), "arguments": .object([:]), "reason": .string("The latest observation verifies success"),
            "requires_confirmation": .bool(false), "result": .string("Verified completion.")
        ]).encodedString()
    }
}

@MainActor
private final class RecordingDesktop: DesktopDriving {
    private(set) var snapshotCount = 0
    private(set) var actions: [DesktopAction] = []
    var includeSummary = true
    var failOnExecution = false
    var failOnSnapshot: Int?

    func snapshot() async throws -> DesktopSnapshot {
        try Task.checkCancellation()
        snapshotCount += 1
        if snapshotCount == failOnSnapshot { throw LiteCUError.message("The test desktop could not capture its next view.") }
        return DesktopSnapshot(imageDataURL: "data:image/png;base64,test-\(snapshotCount)", width: 100, height: 80,
                               context: "Observation \(snapshotCount), after \(actions.count) actions",
                               summary: includeSummary ? "Visible app after \(actions.count) actions" : "")
    }

    func execute(_ action: DesktopAction) async throws -> String {
        try Task.checkCancellation()
        if failOnExecution { throw LiteCUError.message("The test desktop rejected the action before sending input.") }
        actions.append(action)
        return "dispatch \(actions.count) succeeded"
    }
}

private actor ScriptedClient: ModelClient {
    struct Call: Sendable {
        let instructions: String
        let prompt: String
        let snapshotContext: String
        let structured: Bool
    }
    private var replies: [String]
    private let overlapPlanningCalls: Bool
    private var concurrentPlanners = 0
    private(set) var maximumConcurrentPlanners = 0
    private(set) var calls: [Call] = []

    init(replies: [String], overlapPlanningCalls: Bool = false) {
        self.replies = replies
        self.overlapPlanningCalls = overlapPlanningCalls
    }

    func generate(instructions: String, prompt: String, snapshot: DesktopSnapshot?, schema: JSONValue?) async throws -> String {
        try Task.checkCancellation()
        calls.append(Call(instructions: instructions, prompt: prompt, snapshotContext: snapshot?.context ?? "missing", structured: schema != nil))
        if schema == nil {
            if overlapPlanningCalls && instructions.contains("read-only planning assistant") {
                concurrentPlanners += 1
                maximumConcurrentPlanners = max(maximumConcurrentPlanners, concurrentPlanners)
                defer { concurrentPlanners -= 1 }
                try await Task.sleep(for: .milliseconds(30))
            }
            return "Inspect the app, take the requested action, verify the next screenshot."
        }
        guard !replies.isEmpty else { throw LiteCUError.message("The test model has no remaining scripted responses.") }
        return replies.removeFirst()
    }
}

private actor CancellationClient: ModelClient {
    private(set) var wasCancelled = false
    private var started = false
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstAction: String?

    init(firstAction: String? = nil) { self.firstAction = firstAction }

    func waitUntilRequestBegins() async {
        if started { return }
        await withCheckedContinuation { requestWaiters.append($0) }
    }

    func generate(instructions: String, prompt: String, snapshot: DesktopSnapshot?, schema: JSONValue?) async throws -> String {
        guard schema != nil else { return "Open the requested app, then verify it." }
        if let firstAction {
            self.firstAction = nil
            return firstAction
        }
        started = true
        requestWaiters.forEach { $0.resume() }
        requestWaiters.removeAll()
        do {
            try await Task.sleep(for: .seconds(10))
        } catch {
            wasCancelled = error is CancellationError
            throw error
        }
        throw LiteCUError.message("The test did not cancel its pending request.")
    }
}
