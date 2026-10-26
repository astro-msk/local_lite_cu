import AppKit
import Combine
import LiteCUCore

enum ExecutionTarget: String, CaseIterable, Identifiable {
    case desktop = "Desktop"
    case backgroundArc = "Background Arc"

    var id: String { rawValue }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var command = ""
    @Published var modelName = "gpt-6.1-sol"
    @Published var backend = "Codex"
    @Published var codexPath = CodexClient.discoverBinary() ?? "" {
        didSet {
            guard codexPath != oldValue else { return }
            codexConnectionChecked = false
            codexStatus = "Check this executable's Codex sign-in."
        }
    }
    @Published var codexStatus = "Uses your existing Codex sign-in"
    @Published var isCheckingCodex = false
    @Published var codexConnectionChecked = false
    @Published var demoMode = true
    @Published var executionTarget: ExecutionTarget = .desktop
    @Published var arcStatus = "Allow Automation for Arc, then enable Allow JavaScript from Apple Events in Arc."
    @Published var isCheckingArc = false
    @Published var isTestingArcPage = false
    @Published var arcConnectionChecked = false
    @Published var approvalMode: ApprovalMode = .everyAction
    @Published var useSubagents = true
    @Published var maxSteps = 12
    @Published var apiKeyInput = ""
    @Published var keySaved = false
    @Published var isRunning = false
    @Published var isStopping = false
    @Published var currentRunStartedAt: Date?
    @Published var currentRunEndedAt: Date?
    @Published var stage = "Ready"
    @Published var events: [RunEvent] = []
    @Published var workflowNodes: [WorkflowNode] = []
    @Published var plan = ""
    @Published var result = ""
    @Published var pendingAction: DesktopAction?
    @Published var pendingClarification: ClarificationRequest?
    @Published var errorMessage: String?
    @Published var keyMessage: String?
    @Published var stepCount = 0
    @Published var showSettings = false
    @Published var accessibilityGranted = false
    @Published var screenRecordingGranted = false
    @Published var savedRuns: [SavedRun] = []
    @Published var selectedRunID: UUID?
    @Published var historyError: String?
    let speech = SpeechController()
    private let desktop = MacDesktopDriver()
    private let arc = ArcBrowserDriver()
    private var task: Task<Void, Never>?
    private var arcTestTask: Task<Void, Never>?
    private var voiceStartTask: Task<Void, Never>?
    private var voiceStartID: UUID?
    private var approval: CheckedContinuation<Bool, Never>?
    private var clarification: CheckedContinuation<String?, Never>?
    private let historyStore = RunHistoryStore()
    private var activeRunID: UUID?
    private var runStartedAt = Date()
    private var subscriptions = Set<AnyCancellable>()

    var modelConnectionReady: Bool {
        if backend == "Codex" { return codexConnectionChecked }
        return keySaved || !(ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? "").isEmpty
    }

    var modelConnectionSummary: String {
        if backend == "Codex" {
            if codexPath.isEmpty { return "Choose a Codex executable in Settings." }
            if isCheckingCodex { return "Checking your Codex sign-in…" }
            return codexConnectionChecked ? "Codex sign-in checked. Ready for a live task." : "Check your Codex sign-in in Settings before your first live task."
        }
        return modelConnectionReady ? "API key available. Ready for a live task." : "Add an OpenAI API key in Settings."
    }

    init() {
        do { savedRuns = try historyStore.load() }
        catch { historyError = error.localizedDescription }
        keySaved = KeychainStore.load() != nil
        refreshPermissions()
        speech.$transcript.dropFirst().sink { [weak self] text in
            guard let self, !self.isRunning, self.selectedRunID == nil, !text.isEmpty else { return }
            self.command = text
        }.store(in: &subscriptions)
        speech.onFinalTranscript = { [weak self] in self?.receiveFinalTranscript($0) }
        desktop.onEmergencyStop = { [weak self] in self?.stop() }
        desktop.startEmergencyStopMonitor()
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.stop() }.store(in: &subscriptions)
    }

    func run() {
        guard !isRunning, selectedRunID == nil else { return }
        guard !isCheckingArc else { errorMessage = "Wait for the Arc setup check to finish, then run your task."; return }
        guard voiceStartID == nil && !speech.isStarting && !speech.isListening && !speech.isFinishing else {
            errorMessage = "Stop dictation and wait for the transcript before running your task."
            return
        }
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { errorMessage = "Type a command or use the microphone."; return }
        refreshPermissions()
        if !demoMode && executionTarget == .desktop && (!accessibilityGranted || !screenRecordingGranted) {
            errorMessage = "Live desktop control needs Accessibility and Screen Recording. Enable them in Settings, then try again."
            showSettings = true; return
        }
        let config = RunConfiguration(model: modelName, apiKey: KeychainStore.load() ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? "", demo: demoMode, approvalMode: approvalMode, useSubagents: useSubagents, maxSteps: maxSteps)
        let client: any ModelClient
        if demoMode { client = DemoModelClient() }
        else if backend == "Codex" {
            guard !codexPath.isEmpty else { errorMessage = "Choose the Codex executable in Settings."; showSettings = true; return }
            client = CodexClient(model: modelName, binaryPath: codexPath)
        } else {
            guard !config.apiKey.isEmpty else { errorMessage = "Add an API key in Settings or choose Codex."; showSettings = true; return }
            client = OpenAIClient(model: modelName, apiKey: config.apiKey)
        }
        let target = executionTarget
        let driver: any DesktopDriving
        if config.demo { driver = DemoDesktopDriver() }
        else if target == .backgroundArc { driver = arc }
        else { driver = desktop }
        let runner = AgentRunner(driver: driver, client: client, configuration: config)
        activeRunID = UUID(); runStartedAt = Date()
        currentRunStartedAt = runStartedAt; currentRunEndedAt = nil
        events = [RunEvent("user", command)]
        plan = ""; result = ""; errorMessage = nil; pendingAction = nil; pendingClarification = nil; stepCount = 0; workflowNodes = []
        isRunning = true; isStopping = false; stage = "Planning"
        runner.onEvent = { [weak self] in self?.events.append($0) }
        runner.onWorkflow = { [weak self] in self?.workflowNodes = $0 }
        runner.onStage = { [weak self] nextStage in
            guard let self, !self.isStopping else { return }
            self.stage = nextStage
        }
        runner.onPlan = { [weak self] in self?.plan = $0 }
        runner.onStep = { [weak self] in self?.stepCount = $0 }
        runner.approve = { [weak self] action in
            guard let self, !Task.isCancelled, !self.isStopping else { return false }
            return await withCheckedContinuation { continuation in
                self.pendingAction = action
                self.approval = continuation
                NSApp.unhide(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        runner.clarify = { [weak self] request in
            guard let self, !Task.isCancelled, !self.isStopping else { return nil }
            return await withCheckedContinuation { continuation in
                self.pendingClarification = request
                self.clarification = continuation
                NSApp.unhide(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        let submittedCommand = command
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isRunning = false; self.isStopping = false; self.pendingAction = nil; self.pendingClarification = nil; self.task = nil
                self.approval?.resume(returning: false); self.approval = nil
                self.clarification?.resume(returning: nil); self.clarification = nil
                self.currentRunEndedAt = Date()
                self.saveCurrentRun()
                self.activeRunID = nil
                if config.demo || target == .desktop {
                    NSApp.unhide(nil); NSApp.activate(ignoringOtherApps: true)
                }
            }
            do {
                if !config.demo {
                    if target == .backgroundArc {
                        self.arc.prepareForRun()
                    } else {
                        self.desktop.prepareForRun()
                        NSApp.hide(nil)
                        try await Task.sleep(for: .milliseconds(650))
                    }
                }
                let completedResult = try await runner.run(command: submittedCommand)
                try Task.checkCancellation()
                self.result = completedResult
                self.stage = "Complete"
            } catch is CancellationError {
                self.stage = "Stopped"
                self.events.append(RunEvent("system", "Stopped. No further actions will run."))
            } catch {
                if Task.isCancelled { self.stage = "Stopped" }
                else {
                    self.stage = "Failed"
                    self.errorMessage = error.localizedDescription
                    self.events.append(RunEvent("system", error.localizedDescription))
                }
            }
        }
    }

    var canStartNewChat: Bool {
        !isRunning && voiceStartID == nil && !speech.isStarting && !speech.isListening && !speech.isFinishing
    }

    func newChat() {
        guard canStartNewChat else { return }
        selectedRunID = nil
        currentRunStartedAt = nil; currentRunEndedAt = nil
        command = ""; workflowNodes = []; events = []; plan = ""; result = ""
        errorMessage = nil; pendingAction = nil; pendingClarification = nil; stepCount = 0; stage = "Ready"
    }

    func openRun(_ run: SavedRun) {
        guard canStartNewChat else { return }
        selectedRunID = run.id
        currentRunStartedAt = run.startedAt; currentRunEndedAt = run.endedAt
        command = run.command; workflowNodes = run.nodes; result = run.result
        stage = run.stage; stepCount = run.stepCount; errorMessage = nil
        pendingAction = nil; pendingClarification = nil
        events = []; plan = run.nodes.first(where: { $0.kind == .planning })?.detail ?? ""
    }

    private func saveCurrentRun() {
        guard let id = activeRunID else { return }
        let run = SavedRun(id: id, command: command, startedAt: runStartedAt,
                           modelName: modelName, backend: backend, demoMode: demoMode,
                           stage: stage, result: result, nodes: workflowNodes,
                           stepCount: stepCount, maxSteps: maxSteps, executionTarget: executionTarget.rawValue, endedAt: currentRunEndedAt)
        savedRuns.removeAll { $0.id == id }
        savedRuns.insert(run, at: 0)
        savedRuns = Array(savedRuns.prefix(100))
        do { try historyStore.save(savedRuns); historyError = nil }
        catch { historyError = error.localizedDescription }
    }

    func stop() {
        arcTestTask?.cancel()
        voiceStartTask?.cancel()
        voiceStartTask = nil; voiceStartID = nil
        speech.abort()
        if isRunning { isStopping = true; stage = "Stopping" }
        task?.cancel()
        let continuation = approval; approval = nil; pendingAction = nil
        continuation?.resume(returning: false)
        let answerContinuation = clarification; clarification = nil; pendingClarification = nil
        answerContinuation?.resume(returning: nil)
    }
    func approve() {
        guard let continuation = approval else { return }
        approval = nil; pendingAction = nil
        // Keep Lite CU foreground until the driver restores the exact observed app.
        // Hiding here first could activate an unrelated app and invalidate the target.
        continuation.resume(returning: true)
    }
    func reject() { stop() }
    private func receiveFinalTranscript(_ transcript: String) {
        guard canStartNewChat, selectedRunID == nil else { return }
        let parsed = VoiceCommandParser.parse(transcript)
        command = parsed.command
        guard parsed.hasExecutionTrigger else { return }
        guard parsed.shouldExecute else {
            errorMessage = "Say a task before “CU start”, or type the task here."
            return
        }
        run()
    }
    func answerClarification(_ answer: String) {
        let answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isStopping, !answer.isEmpty, answer.count <= 2_000,
              let continuation = clarification else { return }
        clarification = nil; pendingClarification = nil
        // The next snapshot restores the exact observed desktop app itself.
        // Arc observes its owned tab without changing the foreground application.
        continuation.resume(returning: answer)
    }
    func toggleVoice() {
        guard !isRunning && selectedRunID == nil && voiceStartID == nil && !speech.isStarting && !speech.isFinishing else { return }
        if speech.isListening { speech.stop() }
        else {
            let startID = UUID()
            voiceStartID = startID
            voiceStartTask = Task { [weak self] in
                guard let self, self.voiceStartID == startID, !self.isRunning, !Task.isCancelled else { return }
                defer {
                    if self.voiceStartID == startID {
                        self.voiceStartTask = nil; self.voiceStartID = nil
                    }
                }
                await self.speech.start()
            }
        }
    }
    func saveKey() {
        do {
            let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { keyMessage = "Enter an API key first."; return }
            try KeychainStore.save(key); apiKeyInput = ""; keySaved = true; keyMessage = "Saved in macOS Keychain."
        } catch { keyMessage = error.localizedDescription }
    }
    func removeKey() {
        do { try KeychainStore.delete(); keySaved = false; apiKeyInput = ""; keyMessage = "Key removed." }
        catch { keyMessage = error.localizedDescription }
    }
    func refreshPermissions() {
        let previouslyGranted = accessibilityGranted
        accessibilityGranted = MacDesktopDriver.hasAccessibilityPermission
        screenRecordingGranted = MacDesktopDriver.hasScreenRecordingPermission
        if accessibilityGranted && !previouslyGranted {
            desktop.stopEmergencyStopMonitor()
            desktop.startEmergencyStopMonitor()
        }
    }
    func requestAccessibility() { MacDesktopDriver.requestAccessibilityPermission(); refreshPermissions() }
    func requestScreenRecording() { _ = MacDesktopDriver.requestScreenRecordingPermission(); refreshPermissions() }
    func checkArcConnection() {
        guard !isRunning, !isCheckingArc else { return }
        isCheckingArc = true; arcConnectionChecked = false
        arcStatus = "Checking Arc Automation…"
        Task {
            defer { isCheckingArc = false }
            do {
                arcStatus = try await arc.checkConnection()
                arcConnectionChecked = true
            } catch { arcStatus = error.localizedDescription }
        }
    }
    func testArcPage() {
        guard !isRunning, !isCheckingArc else { return }
        isCheckingArc = true
        isTestingArcPage = true
        arcStatus = "Opening example.com in a separate Arc test window…"
        arcTestTask = Task {
            defer { isCheckingArc = false; isTestingArcPage = false; arcTestTask = nil }
            let driver = ArcBrowserDriver()
            do {
                _ = try await driver.execute(DesktopAction(name: "open_url", arguments: .object(["url": .string("https://example.com/")])))
                let page = try await waitForArcTestPage(driver, host: "example.com")
                guard page["title"].string == "Example Domain",
                      let link = page["elements"].array?.first(where: { $0["name"].string == "Learn more" }),
                      let elementID = link["id"].string,
                      let href = link["href"].string,
                      URL(string: href)?.host == "iana.org" || URL(string: href)?.host == "www.iana.org" else {
                    throw LiteCUError.message("The test page did not contain the expected Example Domain title and IANA link.")
                }
                arcStatus = "Read Example Domain. Clicking its Learn more link…"
                _ = try await driver.execute(DesktopAction(name: "browser_click", arguments: .object(["element_id": .string(elementID)])))
                let destination = try await waitForArcTestPage(driver, host: "iana.org")
                guard let title = destination["title"].string, !title.isEmpty else {
                    throw LiteCUError.message("The destination loaded without a page title.")
                }
                arcConnectionChecked = true
                arcStatus = "Browser test passed: opened Example Domain, read the page, clicked Learn more, and verified \(title). No model was used."
            } catch is CancellationError { arcStatus = "Browser test stopped." }
            catch { arcStatus = error.localizedDescription }
        }
    }

    func stopArcTest() { arcTestTask?.cancel() }

    private func waitForArcTestPage(_ driver: ArcBrowserDriver, host: String) async throws -> JSONValue {
        for _ in 0..<30 {
            try Task.checkCancellation()
            let snapshot = try await driver.snapshot()
            if let page = try? JSONDecoder().decode(JSONValue.self, from: Data(snapshot.context.utf8)),
               let address = page["url"].string,
               let actualHost = URL(string: address)?.host,
               actualHost == host || actualHost == "www." + host {
                return page
            }
            try await Task.sleep(for: .milliseconds(300))
        }
        throw LiteCUError.message("The browser test did not observe the expected \(host) page in time. Check the test window before retrying.")
    }

    func checkCodex() {
        guard !isCheckingCodex else { return }
        isCheckingCodex = true
        codexConnectionChecked = false
        codexStatus = "Checking Codex…"
        let path = codexPath
        Task {
            defer { isCheckingCodex = false }
            do {
                let status = try await CodexClient.connectionStatus(binaryPath: path)
                guard path == codexPath else { return }
                codexStatus = status
                codexConnectionChecked = true
            } catch {
                guard path == codexPath else { return }
                codexStatus = error.localizedDescription
            }
        }
    }
}
