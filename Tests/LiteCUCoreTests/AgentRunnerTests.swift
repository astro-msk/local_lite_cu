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
        let runner = AgentRunner(driver: driver, client: client, configuration: configuration(confirmActions: true))
        var approvalCount = 0
        runner.approve = { _ in approvalCount += 1; return false }

        do {
            _ = try await runner.run(command: "Type hello")
            Issue.record("A denied action must stop the run.")
        } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }

        #expect(approvalCount == 1)
        #expect(driver.actions.isEmpty)
        #expect(driver.snapshotCount == 2)
    }

    @Test
    func testModelRequiredConfirmationOverridesDisabledPerActionApproval() async throws {
        let driver = RecordingDesktop()
        let client = ScriptedClient(replies: [try step("press_key", ["key": .string("return")], requiresConfirmation: true)])
        let runner = AgentRunner(driver: driver, client: client, configuration: configuration(confirmActions: false))
        var requestedApproval = false
        runner.approve = { _ in requestedApproval = true; return false }

        do {
            _ = try await runner.run(command: "Submit the form")
            Issue.record("Required confirmation must be respected.")
        } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }

        #expect(requestedApproval)
        #expect(driver.actions.isEmpty)
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
    }

    @Test
    func testCancellationImmediatelyAfterApprovalStillPreventsDispatch() async throws {
        let driver = RecordingDesktop()
        let client = ScriptedClient(replies: [try step("press_key", ["key": .string("return")])])
        let runner = AgentRunner(driver: driver, client: client, configuration: configuration(confirmActions: true))
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
    }

    private func configuration(confirmActions: Bool = false, maxSteps: Int = 8) -> RunConfiguration {
        RunConfiguration(demo: false, confirmActions: confirmActions, useSubagents: false, maxSteps: maxSteps)
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

    func snapshot() async throws -> DesktopSnapshot {
        try Task.checkCancellation()
        snapshotCount += 1
        return DesktopSnapshot(imageDataURL: "data:image/png;base64,test-\(snapshotCount)", width: 100, height: 80,
                               context: "Observation \(snapshotCount), after \(actions.count) actions")
    }

    func execute(_ action: DesktopAction) async throws -> String {
        try Task.checkCancellation()
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

    func waitUntilRequestBegins() async {
        if started { return }
        await withCheckedContinuation { requestWaiters.append($0) }
    }

    func generate(instructions: String, prompt: String, snapshot: DesktopSnapshot?, schema: JSONValue?) async throws -> String {
        guard schema != nil else { return "Open the requested app, then verify it." }
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
