import AppKit
import Combine
import LiteCUCore

@MainActor
final class AppModel: ObservableObject {
    @Published var command = ""
    @Published var modelName = "gpt-6.1-sol"
    @Published var backend = "Codex"
    @Published var codexPath = CodexClient.discoverBinary() ?? ""
    @Published var codexStatus = "Uses your existing Codex sign-in"
    @Published var demoMode = true
    @Published var confirmActions = true
    @Published var useSubagents = true
    @Published var maxSteps = 12
    @Published var apiKeyInput = ""
    @Published var keySaved = false
    @Published var isRunning = false
    @Published var stage = "Ready"
    @Published var events: [RunEvent] = []
    @Published var plan = ""
    @Published var result = ""
    @Published var pendingAction: DesktopAction?
    @Published var errorMessage: String?
    @Published var keyMessage: String?
    @Published var stepCount = 0
    @Published var showSettings = false
    @Published var accessibilityGranted = false
    @Published var screenRecordingGranted = false
    let speech = SpeechController()
    private let desktop = MacDesktopDriver()
    private var task: Task<Void, Never>?
    private var approval: CheckedContinuation<Bool, Never>?
    private var subscriptions = Set<AnyCancellable>()

    init() {
        keySaved = KeychainStore.load() != nil
        refreshPermissions()
        speech.$transcript.dropFirst().sink { [weak self] text in
            guard !text.isEmpty else { return }
            self?.command = text
        }.store(in: &subscriptions)
        desktop.onEmergencyStop = { [weak self] in self?.stop() }
        desktop.startEmergencyStopMonitor()
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.stop() }.store(in: &subscriptions)
    }

    func run() {
        guard !isRunning else { return }
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { errorMessage = "Type a command or use the microphone."; return }
        speech.stop()
        refreshPermissions()
        if !demoMode && (!accessibilityGranted || !screenRecordingGranted) {
            errorMessage = "Live desktop control needs Accessibility and Screen Recording. Enable them in Settings, then try again."
            showSettings = true; return
        }
        let config = RunConfiguration(model: modelName, apiKey: KeychainStore.load() ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? "", demo: demoMode, confirmActions: confirmActions, useSubagents: useSubagents, maxSteps: maxSteps)
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
        events = [RunEvent("user", command)]
        plan = ""; result = ""; errorMessage = nil; pendingAction = nil; stepCount = 0
        isRunning = true; stage = "Planning"
        runner.onEvent = { [weak self] in self?.events.append($0) }
        runner.onStage = { [weak self] in self?.stage = $0 }
        runner.onPlan = { [weak self] in self?.plan = $0 }
        runner.onStep = { [weak self] in self?.stepCount = $0 }
        runner.approve = { [weak self] action in
            guard let self, !Task.isCancelled else { return false }
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
                self.isRunning = false; self.pendingAction = nil; self.task = nil
                NSApp.unhide(nil); NSApp.activate(ignoringOtherApps: true)
            }
            do {
                if !config.demo {
                    NSApp.hide(nil)
                    try await Task.sleep(for: .milliseconds(650))
                }
                self.result = try await runner.run(command: submittedCommand)
                try Task.checkCancellation()
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

    func stop() {
        speech.stop()
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
        guard !isRunning else { return }
        if speech.isListening { speech.stop() }
        else { Task { await speech.start() } }
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
        codexStatus = "Checking Codex…"
        let path = codexPath
        Task {
            do { codexStatus = try await CodexClient.connectionStatus(binaryPath: path) }
            catch { codexStatus = error.localizedDescription }
        }
    }
}
