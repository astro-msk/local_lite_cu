import AppKit
import Combine
import LiteCUCore

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
    @Published var approvalMode: ApprovalMode = .everyAction
    @Published var useSubagents = true
    @Published var maxSteps = 12
    @Published var apiKeyInput = ""
    @Published var keySaved = false
    @Published var isRunning = false
    @Published var isStopping = false
    @Published var stage = "Ready"
    @Published var events: [RunEvent] = []
    @Published var workflowNodes: [WorkflowNode] = []
    @Published var plan = ""
    @Published var result = ""
    @Published var pendingAction: DesktopAction?
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
    private var task: Task<Void, Never>?
    private var voiceStartTask: Task<Void, Never>?
    private var voiceStartID: UUID?
    private var approval: CheckedContinuation<Bool, Never>?
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
            guard let self, !self.isRunning, !text.isEmpty else { return }
            self.command = text
        }.store(in: &subscriptions)
        desktop.onEmergencyStop = { [weak self] in self?.stop() }
        desktop.startEmergencyStopMonitor()
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.stop() }.store(in: &subscriptions)
    }

    func run() {
        guard !isRunning, selectedRunID == nil else { return }
        guard voiceStartID == nil && !speech.isStarting && !speech.isListening && !speech.isFinishing else {
            errorMessage = "Stop dictation and wait for the transcript before running your task."
            return
        }
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { errorMessage = "Type a command or use the microphone."; return }
        refreshPermissions()
        if !demoMode && (!accessibilityGranted || !screenRecordingGranted) {
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
        let driver: any DesktopDriving = config.demo ? DemoDesktopDriver() : desktop
        let runner = AgentRunner(driver: driver, client: client, configuration: config)
        activeRunID = UUID(); runStartedAt = Date()
        events = [RunEvent("user", command)]
        plan = ""; result = ""; errorMessage = nil; pendingAction = nil; stepCount = 0; workflowNodes = []
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
        let submittedCommand = command
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isRunning = false; self.isStopping = false; self.pendingAction = nil; self.task = nil
                self.saveCurrentRun()
                self.activeRunID = nil
                NSApp.unhide(nil); NSApp.activate(ignoringOtherApps: true)
            }
            do {
                if !config.demo {
                    NSApp.hide(nil)
                    try await Task.sleep(for: .milliseconds(650))
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
        command = ""; workflowNodes = []; events = []; plan = ""; result = ""
        errorMessage = nil; pendingAction = nil; stepCount = 0; stage = "Ready"
    }

    func openRun(_ run: SavedRun) {
        guard canStartNewChat else { return }
        selectedRunID = run.id
        command = run.command; workflowNodes = run.nodes; result = run.result
        stage = run.stage; stepCount = run.stepCount; errorMessage = nil
        events = []; plan = run.nodes.first(where: { $0.kind == .planning })?.detail ?? ""
    }

    private func saveCurrentRun() {
        guard let id = activeRunID else { return }
        let run = SavedRun(id: id, command: command, startedAt: runStartedAt,
                           modelName: modelName, backend: backend, demoMode: demoMode,
                           stage: stage, result: result, nodes: workflowNodes,
                           stepCount: stepCount, maxSteps: maxSteps)
        savedRuns.removeAll { $0.id == id }
        savedRuns.insert(run, at: 0)
        savedRuns = Array(savedRuns.prefix(100))
        do { try historyStore.save(savedRuns); historyError = nil }
        catch { historyError = error.localizedDescription }
    }

    func stop() {
        voiceStartTask?.cancel()
        voiceStartTask = nil; voiceStartID = nil
        speech.abort()
        if isRunning { isStopping = true; stage = "Stopping" }
        task?.cancel()
        let continuation = approval; approval = nil; pendingAction = nil
        continuation?.resume(returning: false)
    }
    func approve() {
        guard let continuation = approval else { return }
        approval = nil; pendingAction = nil
        NSApp.hide(nil)
        // The driver restores the app from the observation before sending input.
        continuation.resume(returning: true)
    }
    func reject() { stop() }
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
