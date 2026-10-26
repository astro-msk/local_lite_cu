import SwiftUI
import AppKit
import LiteCUCore

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var showApprovalPreview = false
    @State private var followLive = true
    @State private var section: WorkspaceSection = .workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Palette.line).frame(height: 1)
            if section == .history {
                history
            } else {
                if isPreviousRun { previousRunBanner } else { controlStrip }
                Rectangle().fill(Palette.line).frame(height: 1)
                workspace
            }
        }
        .foregroundStyle(Palette.text)
        .background(Palette.background)
        .tint(Palette.blue)
        .sheet(isPresented: $model.showSettings) { SettingsView(model: model) }
        .sheet(isPresented: $showApprovalPreview) { ApprovalPreviewView() }
        .onChange(of: model.isRunning) { _, running in
            if running { showApprovalPreview = false }
        }
        .onAppear { model.refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "cursorarrow.motionlines")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Palette.onBrand)
                .frame(width: 37, height: 37)
                .background(Palette.brandFill, in: RoundedRectangle(cornerRadius: 11))
            Text("lite cu").font(.system(size: 22, weight: .semibold, design: .rounded)).fixedSize()
            Picker("View", selection: sectionBinding) {
                Text("Workspace").tag(WorkspaceSection.workspace)
                Text("Previous runs").tag(WorkspaceSection.history)
            }
            .labelsHidden()
            .accessibilityLabel("Workspace view")
            .pickerStyle(.segmented)
            .frame(width: 210, height: 28)
            .disabled(!model.canStartNewChat)
            .modifier(VoiceIdleModifier(speech: model.speech))
            Spacer(minLength: 10)
            if section == .workspace && !isPreviousRun {
                Picker("Model", selection: $model.modelName) {
                    Text("GPT 6.1 Sol").tag("gpt-6.1-sol")
                    Text("GPT 6 Sol").tag("gpt-6-sol")
                }
                .labelsHidden()
                .accessibilityLabel("Model")
                .frame(width: 132, height: 28)
                .disabled(model.isRunning)
                Picker("Execution mode", selection: $model.demoMode) {
                    Text("Demo").tag(true)
                    Text("Live").tag(false)
                }
                .labelsHidden()
                .accessibilityLabel("Execution mode")
                .pickerStyle(.segmented)
                .frame(width: 112, height: 28)
                .disabled(model.isRunning)
            }
            Button(action: startNewChat) { Label("New chat", systemImage: "plus") }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!model.canStartNewChat)
                .modifier(VoiceIdleModifier(speech: model.speech))
                .help("Start a new computer-use task.")
            Button { model.showSettings = true } label: {
                Image(systemName: "slider.horizontal.3").frame(width: 15)
            }
            .buttonStyle(SecondaryButtonStyle())
            .accessibilityLabel("Settings")
            .help("Settings · ⌘,")
        }
        .frame(maxWidth: 1080)
        .padding(.horizontal, 28)
        .padding(.top, 21)
        .frame(maxWidth: .infinity)
        .frame(height: 84)
        .background(Palette.panel)
    }

    private var isPreviousRun: Bool { model.selectedRunID != nil }
    private var selectedRun: SavedRun? { model.savedRuns.first { $0.id == model.selectedRunID } }

    private var sectionBinding: Binding<WorkspaceSection> {
        Binding(get: { section }, set: { value in
            guard model.canStartNewChat else { return }
            section = value
        })
    }

    private func startNewChat() {
        guard model.canStartNewChat else { return }
        model.newChat()
        showApprovalPreview = false
        section = .workspace
    }

    private var previousRunBanner: some View {
        HStack(spacing: 16) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 18)).foregroundStyle(Palette.blue)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 9) {
                    Text("Previous run").font(.system(size: 12, weight: .semibold))
                    if let run = selectedRun {
                        Text(run.startedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                            .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                        Text(run.stage == "Complete" ? "Run finished" : run.stage)
                            .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                        if run.endedAt != nil {
                            ElapsedTimeLabel(startedAt: run.startedAt, endedAt: run.endedAt, isRunning: false, prefix: "Total ")
                                .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                        }
                    }
                }
                if let run = selectedRun {
                    Text("\(run.demoMode ? "Demo" : "Live") · \(run.executionTarget) · \(run.modelName) · \(run.backend) · \(run.stepCount) / \(run.maxSteps) actions")
                        .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                }
                Text("Read only. Start a new chat to run another task.")
                    .font(.system(size: 11)).foregroundStyle(Palette.secondary)
            }
            Spacer(minLength: 12)
            Button("New chat", action: startNewChat).buttonStyle(PrimaryButtonStyle())
                .disabled(!model.canStartNewChat)
                .modifier(VoiceIdleModifier(speech: model.speech))
        }
        .frame(maxWidth: 1080)
        .padding(.horizontal, 28).padding(.vertical, 15)
        .frame(maxWidth: .infinity)
        .background(Palette.sidebar.opacity(0.6))
    }

    private var history: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Previous runs").font(.system(size: 25, weight: .semibold, design: .rounded))
                    Text("Revisit the plan, actions, and observations from earlier tasks.")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }
                if let error = model.historyError {
                    InlineNotice(icon: "exclamationmark.triangle", text: error, color: Palette.amber)
                }
                if model.savedRuns.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "clock.arrow.circlepath").font(.system(size: 25)).foregroundStyle(Palette.blue)
                        Text("No previous runs yet").font(.system(size: 16, weight: .semibold))
                        Text("Finished tasks will appear here. Start a new chat to try your first one.")
                            .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                        Button("New chat", action: startNewChat).buttonStyle(PrimaryButtonStyle())
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(25)
                    .background(Palette.panel, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.line))
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(model.savedRuns) { run in historyRow(run) }
                    }
                }
            }
            .frame(maxWidth: 1080, alignment: .leading)
            .padding(.horizontal, 28).padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
    }

    private func historyRow(_ run: SavedRun) -> some View {
        Button {
            guard model.canStartNewChat else { return }
            model.openRun(run)
            section = .workspace
        } label: {
            HStack(spacing: 16) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 16)).foregroundStyle(Palette.blue)
                    .frame(width: 35, height: 35)
                    .background(Palette.elevated, in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 8) {
                    Text(run.command).font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.text).lineLimit(2).multilineTextAlignment(.leading)
                    HStack(spacing: 9) {
                        Text(run.startedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                        Text("·")
                        Text(run.demoMode ? "Demo" : "Live")
                        Text("·")
                        Text(run.executionTarget)
                        Text("·")
                        Text(run.modelName)
                    }
                    .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                }
                Spacer(minLength: 12)
                Text(run.stage == "Complete" ? "Run finished" : run.stage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(run.stage == "Failed" ? Palette.danger : Palette.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Palette.elevated, in: Capsule())
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.secondary)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line))
        }
        .buttonStyle(.plain)
        .disabled(!model.canStartNewChat)
        .modifier(VoiceIdleModifier(speech: model.speech))
        .accessibilityLabel("Open previous run: \(run.command)")
        .help("Open this saved workflow without running any actions.")
    }

    private var controlStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    if model.isRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Circle().fill(statusColor).frame(width: 7, height: 7)
                    }
                    Text(model.stage == "Complete" ? "Run finished" : model.stage)
                        .font(.system(size: 12, weight: .semibold))
                }
                if !model.workflowNodes.isEmpty {
                    Text("\(model.stepCount) / \(model.maxSteps) actions")
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(Palette.secondary)
                }
                if model.currentRunStartedAt != nil {
                    ElapsedTimeLabel(startedAt: model.currentRunStartedAt, endedAt: model.currentRunEndedAt,
                                     isRunning: model.isRunning, prefix: "Total ")
                        .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                }
                Spacer(minLength: 12)
                if model.isRunning {
                    Button(action: model.stop) {
                        Label(model.stage == "Stopping" ? "Stopping…" : "Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(SemanticButtonStyle(tone: .red))
                    .fixedSize()
                    .disabled(model.stage == "Stopping")
                    .keyboardShortcut(".", modifiers: .command)
                } else {
                    Button {
                        guard !model.isRunning else { return }
                        showApprovalPreview = true
                    } label: {
                        Label("Preview", systemImage: "eye")
                    }
                    .buttonStyle(SemanticButtonStyle(tone: .yellow))
                    .fixedSize()
                    .disabled(model.isRunning)
                    .accessibilityLabel("Preview approval")
                    .help("Test approval controls with an isolated sample. No desktop action runs.")
                }
            }
            HStack(spacing: 12) {
                Text("Target").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.secondary)
                Picker("Execution target", selection: $model.executionTarget) {
                    ForEach(ExecutionTarget.allCases) { target in Text(target.rawValue).tag(target) }
                }
                .labelsHidden()
                .accessibilityLabel("Execution target")
                .frame(width: 155)
                .disabled(model.isRunning || model.isCheckingArc)
                Text("Approval").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.secondary)
                    .padding(.leading, 8)
                ApprovalLevelPicker(selection: $model.approvalMode)
                    .frame(width: 228)
                    .disabled(model.isRunning)
                Spacer(minLength: 0)
            }
            HStack(spacing: 12) {
                Text(model.approvalMode.explanation)
                    .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                Spacer(minLength: 12)
                if model.isRunning {
                    Text(model.executionTarget == .desktop ? "Emergency stop  ⌘ ⇧ Esc" : "Stop task  ⌘ .")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Palette.secondary)
                        .fixedSize()
                } else if !model.demoMode {
                    liveReadiness
                } else {
                    Label("Simulated desktop", systemImage: "play.rectangle")
                        .font(.system(size: 10)).foregroundStyle(Palette.secondary).fixedSize()
                }
            }
        }
        .frame(maxWidth: 1080)
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(Palette.sidebar.opacity(0.6))
    }

    @ViewBuilder
    private var liveReadiness: some View {
        if model.executionTarget == .desktop && (!model.accessibilityGranted || !model.screenRecordingGranted) {
            Button("Set up desktop access") { model.showSettings = true }
                .font(.system(size: 11, weight: .semibold)).buttonStyle(.plain)
                .foregroundStyle(Palette.blue).fixedSize()
        } else if !model.modelConnectionReady {
            if model.backend == "Codex" && !model.codexPath.isEmpty {
                Button(model.isCheckingCodex ? "Checking connection…" : "Check connection", action: model.checkCodex)
                    .font(.system(size: 11, weight: .semibold)).buttonStyle(.plain)
                    .foregroundStyle(Palette.blue).fixedSize()
                    .disabled(model.isCheckingCodex)
            } else {
                Button("Set up model connection") { model.showSettings = true }
                    .font(.system(size: 11, weight: .semibold)).buttonStyle(.plain)
                    .foregroundStyle(Palette.blue).fixedSize()
            }
        } else if model.executionTarget == .backgroundArc {
            Button(model.arcConnectionChecked ? "Arc setup" : "Set up Arc") { model.showSettings = true }
                .font(.system(size: 11, weight: .semibold)).buttonStyle(.plain)
                .foregroundStyle(Palette.blue).fixedSize()
        } else {
            Label("Desktop & connection ready", systemImage: "checkmark.circle.fill")
                .font(.system(size: 10)).foregroundStyle(Palette.accent).fixedSize()
        }
    }

    private var workspace: some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    composer.id("composer")
                    if let error = model.errorMessage {
                        InlineNotice(icon: "exclamationmark.triangle", text: error, color: Palette.danger)
                    }
                    if let error = model.historyError {
                        InlineNotice(icon: "externaldrive.badge.exclamationmark", text: error, color: Palette.amber)
                    }
                    if model.workflowNodes.isEmpty && !isPreviousRun { startingPoints }
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Workflow").font(.system(size: 19, weight: .semibold, design: .rounded))
                            Spacer()
                            if model.isRunning {
                                Toggle("Follow live", isOn: $followLive)
                                    .toggleStyle(.checkbox)
                                    .font(.system(size: 11))
                                    .fixedSize()
                                    .help("Keep the latest workflow step in view as the task runs.")
                            } else {
                                Text(model.workflowNodes.isEmpty ? "A visible path from command to result" : "The plan, actions, and observations from this run")
                                    .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                            }
                        }
                        WorkflowGraphView(nodes: model.workflowNodes, isRunning: model.isRunning, stage: model.stage, isReadOnly: isPreviousRun,
                                          pendingClarification: model.pendingClarification,
                                          onApprove: model.approve, onReject: model.reject,
                                          onClarify: model.answerClarification, onCancelClarification: model.stop)
                    }
                    .id("workflow")
                }
                .frame(maxWidth: 1080)
                .padding(.horizontal, 28)
                .padding(.top, 25)
                .padding(.bottom, 34)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.automatic)
            .onChange(of: model.pendingAction) { _, action in
                if action != nil, let node = model.workflowNodes.last(where: { $0.status == .awaitingApproval }) {
                    reveal(node.id, in: scroll)
                }
            }
            .onChange(of: model.pendingClarification) { _, request in
                if request != nil, let node = model.workflowNodes.last(where: { $0.status == .awaitingApproval }) {
                    reveal(node.id, in: scroll)
                }
            }
            .onChange(of: model.result) { _, result in
                if !isPreviousRun, !result.isEmpty, let node = model.workflowNodes.last(where: { $0.kind == .result }) {
                    reveal(node.id, in: scroll)
                }
            }
            .onChange(of: model.isRunning) { _, running in
                if running {
                    followLive = true
                    reveal("workflow", in: scroll)
                }
            }
            .onChange(of: model.workflowNodes.last?.id) { _, nodeID in
                if nodeID == nil {
                    reveal("composer", in: scroll)
                } else if model.isRunning, followLive, let nodeID {
                    reveal(nodeID, in: scroll)
                }
            }
            .onChange(of: model.stage) { _, stage in
                if !isPreviousRun, ["Failed", "Stopped"].contains(stage), let node = model.workflowNodes.last {
                    reveal(node.id, in: scroll)
                }
            }
            .onChange(of: model.selectedRunID) { _, _ in
                reveal("composer", in: scroll)
            }
        }
    }

    private func reveal<ID: Hashable>(_ id: ID, in scroll: ScrollViewProxy) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
            scroll.scrollTo(id, anchor: .top)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(isPreviousRun ? "SAVED COMMAND" : (model.isRunning ? "CURRENT COMMAND" : "COMMAND"))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.1).foregroundStyle(Palette.secondary)
                Spacer()
                if model.isRunning || isPreviousRun {
                    Label(isPreviousRun ? "Read only" : "Locked during this run", systemImage: "lock")
                        .font(.system(size: 10)).foregroundStyle(Palette.secondary)
                } else {
                    Text("⌘ Return to run").font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            CommandEditor(model: model, speech: model.speech)
                .padding(.horizontal, 15)
                .padding(.top, 7)
            if model.isRunning || isPreviousRun {
                Color.clear.frame(height: 12)
            } else {
                HStack(spacing: 10) {
                    VoiceControl(speech: model.speech, isRunning: model.isRunning, toggle: model.toggleVoice)
                    Spacer(minLength: 0)
                    Button(action: model.run) {
                        Label(model.demoMode ? "Run demo" : "Run task", systemImage: "arrow.up.right")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isCheckingArc)
                    .modifier(VoiceIdleModifier(speech: model.speech))
                    .keyboardShortcut(.return, modifiers: .command)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                VoiceStatusDetails(speech: model.speech)
                VoiceErrorNotice(speech: model.speech)
                Rectangle().fill(Palette.line).frame(height: 1)
                Label(model.demoMode ? "Demo uses a simulated desktop. No setup required." : (model.executionTarget == .backgroundArc ? "Arc sends page text and your command to OpenAI. Other apps stay available." : "Live sends your command and screenshots to OpenAI."), systemImage: model.demoMode ? "play.rectangle" : "eye")
                    .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    .padding(.horizontal, 20).padding(.vertical, 10)
            }
        }
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(Palette.line))
    }

    private var startingPoints: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Start with something small").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    guard canEditCommand else { return }
                    model.demoMode = true
                    model.command = "Open Safari and search for SwiftUI tutorials"
                    model.run()
                } label: {
                    Label("Try a demo", systemImage: "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                .modifier(VoiceIdleModifier(speech: model.speech))
            }
            HStack(spacing: 12) {
                if model.executionTarget == .backgroundArc && !model.demoMode {
                    suggestion("Find something", detail: "Search for SwiftUI tutorials", icon: "magnifyingglass", command: "Search the web for SwiftUI tutorials")
                    suggestion("Read a page", detail: "Summarize an article", icon: "doc.text", command: "Open https://www.swift.org and summarize the latest announcements")
                    suggestion("Compare options", detail: "Research a browser task", icon: "rectangle.split.2x1", command: "Compare the getting-started guides for SwiftUI and AppKit on Apple's website")
                } else {
                    suggestion("Find something", detail: "Search for SwiftUI tutorials", icon: "safari", command: "Open Safari and search for SwiftUI tutorials")
                    suggestion("Open an app", detail: "Bring up Calculator", icon: "plus.forwardslash.minus", command: "Open Calculator")
                    suggestion("Find a folder", detail: "Show Downloads in Finder", icon: "folder", command: "Open Finder and show my Downloads folder")
                }
            }
            Text("Suggestions fill the command box. You choose when to run.")
                .font(.system(size: 10)).foregroundStyle(Palette.secondary)
        }
    }

    private func suggestion(_ title: String, detail: String, icon: String, command: String) -> some View {
        Button {
            guard canEditCommand else { return }
            model.command = command
        } label: {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: icon).font(.system(size: 16)).foregroundStyle(Palette.blue)
                    .frame(width: 22, height: 24)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.text)
                    Text(detail).font(.system(size: 11)).foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.left").font(.system(size: 10)).foregroundStyle(Palette.secondary)
            }
            .padding(15)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(Palette.line))
        }
        .buttonStyle(.plain)
        .disabled(model.isRunning)
        .modifier(VoiceIdleModifier(speech: model.speech))
        .accessibilityLabel("Use example: \(command)")
        .help("Fill the command box without running it.")
    }

    private var canEditCommand: Bool {
        !isPreviousRun && !model.isRunning && !model.speech.isStarting && !model.speech.isListening && !model.speech.isFinishing
    }

    private var statusColor: Color {
        if ["Failed", "Stopped", "Stopping"].contains(model.stage) { return Palette.amber }
        return model.stage == "Ready" ? Palette.secondary : Palette.accent
    }
}

private enum WorkspaceSection: Hashable {
    case workspace, history
}

private extension ApprovalMode {
    var displayName: String {
        switch self {
        case .everyAction: return "Ask every action"
        case .sensitiveActions: return "Ask for sensitive actions"
        case .fullAccess: return "Approve all (Full access)"
        }
    }

    var explanation: String {
        switch self {
        case .everyAction:
            return "Review each action before it runs. Observations and waits continue automatically."
        case .sensitiveActions:
            return "Review actions flagged as sensitive. Other supported actions run automatically."
        case .fullAccess:
            return "Auto-approve supported actions. Existing macOS permissions, action validation, and step limits still apply."
        }
    }
}

private struct ApprovalLevelPicker: View {
    @Binding var selection: ApprovalMode

    var body: some View {
        Picker("Approval level", selection: $selection) {
            ForEach(ApprovalMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .accessibilityLabel("Approval level")
        .accessibilityHint("Controls which actions ask for confirmation during the next run.")
        .font(.system(size: 11, weight: .medium))
        .frame(maxWidth: .infinity)
    }
}

/// Render an actual read-only view during capture and execution. A disabled
/// native TextEditor can still accept some accessibility-driven text changes.
private struct CommandEditor: View {
    @ObservedObject var model: AppModel
    @ObservedObject var speech: SpeechController

    private var isReadOnly: Bool {
        model.selectedRunID != nil || model.isRunning || speech.isStarting || speech.isListening || speech.isFinishing
    }

    private var guardedCommand: Binding<String> {
        Binding(get: { model.command }, set: { value in
            guard model.selectedRunID == nil, !model.isRunning, !speech.isStarting, !speech.isListening, !speech.isFinishing else { return }
            model.command = value
        })
    }

    var body: some View {
        Group {
            if isReadOnly {
                ScrollView {
                    Text(model.command.isEmpty ? "Your transcript will appear here…" : model.command)
                        .foregroundStyle(model.command.isEmpty ? Palette.secondary : Palette.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.horizontal, 5)
                        .padding(.top, 0)
                }
                .accessibilityLabel(model.selectedRunID != nil ? "Saved command, read only" : (model.isRunning ? "Current task, read only" : "Voice transcript, read only"))
            } else {
                ZStack(alignment: .topLeading) {
                    if model.command.isEmpty {
                        Text("Ask me to do something on your Mac…")
                            .foregroundStyle(Palette.secondary)
                            .padding(.top, 0)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: guardedCommand)
                        .foregroundStyle(Palette.text)
                        .scrollContentBackground(.hidden)
                        .accessibilityLabel("Task to perform")
                }
            }
        }
        .font(.system(size: 14))
        .frame(height: model.isRunning || model.selectedRunID != nil ? 60 : 88)
    }
}

struct ClarificationCard: View {
    let request: ClarificationRequest
    let onContinue: (String) -> Void
    let onCancel: () -> Void
    @State private var selectedOption: String?
    @State private var customAnswer = ""

    private var answer: String {
        let custom = customAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? (selectedOption ?? "") : custom
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(request.question)
                .font(.system(size: 14, weight: .medium)).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            VStack(spacing: 7) {
                ForEach(request.options, id: \.self) { option in
                    Button {
                        selectedOption = option
                        customAnswer = ""
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: selectedOption == option && customAnswer.isEmpty ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedOption == option && customAnswer.isEmpty ? Palette.blue : Palette.secondary)
                                .padding(.top, 1)
                            Text(option).font(.system(size: 12)).foregroundStyle(Palette.text)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(11).frame(maxWidth: .infinity, alignment: .leading)
                        .background(selectedOption == option && customAnswer.isEmpty ? Palette.blue.opacity(0.07) : Palette.panel, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(selectedOption == option && customAnswer.isEmpty ? Palette.blue.opacity(0.5) : Palette.line))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selectedOption == option && customAnswer.isEmpty ? .isSelected : [])
                }
            }
            TextField("Or write your own answer…", text: $customAnswer, axis: .vertical)
                .lineLimit(2...4)
                .font(.system(size: 12)).textFieldStyle(.plain)
                .padding(11)
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line))
                .accessibilityLabel("Custom answer")
            if answer.count > 2_000 {
                Text("Keep your answer under 2,000 characters.")
                    .font(.system(size: 11)).foregroundStyle(Palette.danger)
            }
            HStack(spacing: 12) {
                Button("Cancel task", action: onCancel).buttonStyle(SemanticButtonStyle(tone: .red))
                Text("Your answer continues this same task.")
                    .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                Spacer(minLength: 0)
                Button("Continue") { onContinue(answer) }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(answer.isEmpty || answer.count > 2_000)
            }
        }
        .onChange(of: request) { _, _ in selectedOption = nil; customAnswer = "" }
    }
}

struct ActionApprovalCard: View {
    let action: DesktopAction
    var isPreview = false
    var isInteractive = true
    let onApprove: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: isPreview ? 9 : 13) {
            Label(isPreview ? "Sample action" : "Your approval is needed", systemImage: "hand.raised")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.amber)
            Text(action.summary).font(.system(size: 12)).lineSpacing(4).lineLimit(4)
            VStack(alignment: .leading, spacing: 8) {
                Text(action.name).font(.system(size: 11, weight: .semibold, design: .monospaced))
                ScrollView {
                    Text(arguments)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Palette.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(height: isPreview ? 80 : 150)
                .accessibilityLabel("Exact action arguments")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(isPreview ? 10 : 12)
            .background(Palette.background, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button(isPreview ? "Reject sample" : "Reject & stop", action: onReject)
                    .buttonStyle(SemanticButtonStyle(tone: .red))
                Spacer()
                Button(isPreview ? "Approve sample" : "Approve action", action: onApprove)
                    .buttonStyle(SemanticButtonStyle(tone: .yellow))
            }
            .disabled(!isInteractive)
        }
        .padding(isPreview ? 14 : 17)
        .background(Palette.amber.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.amber.opacity(0.30)))
    }

    private var arguments: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(action.arguments) else { return "Unable to display arguments" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// This view owns only sample state. It has no model, network, or desktop driver.
private struct ApprovalPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var approved: Bool?

    private let sample = DesktopAction(name: "open_app", arguments: .object([
        "bundle_id": .string("com.apple.Safari"),
        "reason": .string("Open Safari for a sample browser task.")
    ]))

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Approval preview").font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text("Try the controls without running a task.")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.cancelAction)
            }
            Label("Preview only. This sample never opens Safari, sends a request, or controls your desktop.", systemImage: "eye")
                .font(.system(size: 12))
                .foregroundStyle(Palette.blue)
                .fixedSize(horizontal: false, vertical: true)
            ActionApprovalCard(action: sample, isPreview: true, isInteractive: approved == nil,
                               onApprove: { approved = true }, onReject: { approved = false })
            if let approved {
                HStack(alignment: .top, spacing: 11) {
                    Image(systemName: approved ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(approved ? Palette.accent : Palette.danger)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(approved ? "Sample approved" : "Sample rejected")
                            .font(.system(size: 13, weight: .semibold))
                        Text("No action was executed. This decision only updates the preview.")
                            .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    }
                    Spacer(minLength: 8)
                    Button("Try again") { self.approved = nil }.buttonStyle(SecondaryButtonStyle())
                }
                .padding(13)
                .background(Palette.elevated, in: RoundedRectangle(cornerRadius: 9))
            } else {
                Text("Choose Approve sample or Reject sample to see the result.")
                    .font(.system(size: 12)).foregroundStyle(Palette.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(width: 560, height: 600)
        .foregroundStyle(Palette.text)
        .background(Palette.background)
        .tint(Palette.blue)
    }
}

private struct VoiceControl: View {
    @ObservedObject var speech: SpeechController
    let isRunning: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggle) {
                Group {
                    if speech.isStarting || speech.isFinishing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: speech.isListening ? "stop.fill" : "mic")
                            .font(.system(size: 14, weight: .medium))
                    }
                }
                .frame(width: 14, height: 14)
            }
            .buttonStyle(SemanticButtonStyle(tone: speech.isFinishing ? .yellow : (speech.isListening ? .red : .green)))
            .disabled(isRunning || speech.isStarting || speech.isFinishing)
            .accessibilityLabel(buttonLabel)
            .accessibilityHint(speech.isListening ? "Stops microphone capture and finishes your transcript." : "Dictates a command for you to review before running.")
            .help(speech.isListening ? "Finish dictation, then review your command" : "Start voice dictation")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 9) {
                    Text(statusTitle).font(.system(size: 11, weight: .medium))
                    if speech.isListening {
                        VoiceInputMeter(level: speech.audioLevel)
                    }
                }
                Text(speech.isFinishing ? "Transcribing on your Mac…" : (speech.isListening ? "Pause to transcribe, or click stop" : (speech.isStarting ? "Preparing microphone access" : "Click to dictate")))
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.secondary)
            }
        }
    }

    private var statusTitle: String {
        if speech.isStarting { return "Starting microphone…" }
        if speech.isFinishing { return "Transcribing…" }
        return speech.isListening ? "Listening…" : "Voice command"
    }

    private var buttonLabel: String {
        if speech.isStarting { return "Starting microphone" }
        if speech.isFinishing { return "Finishing transcript" }
        return speech.isListening ? "Finish dictation" : "Start dictation"
    }
}

private struct VoiceStatusDetails: View {
    @ObservedObject var speech: SpeechController

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if speech.isStarting || speech.isListening || speech.isFinishing {
                Text(speech.isFinishing ? "Whisper is transcribing locally. Review the command when it is ready." : speech.audioStatus)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(speech.isFinishing ? Palette.amber : Palette.secondary)
            }
            Text(speech.recognitionMode)
                .font(.system(size: 10))
                .foregroundStyle(Palette.secondary)
            Text("Say your task, then “CU start” to run. Otherwise, review the transcript and click Run.")
                .font(.system(size: 10))
                .foregroundStyle(Palette.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.bottom, 11)
        .accessibilityElement(children: .combine)
    }
}

private struct VoiceInputMeter: View {
    let level: Double

    var body: some View {
        ProgressView(value: min(1, max(0, level)), total: 1)
            .progressViewStyle(.linear)
            .tint(Palette.accent)
            .frame(width: 54)
            .accessibilityLabel("Microphone input level")
            .accessibilityValue("\(Int(min(1, max(0, level)) * 100)) percent")
    }
}

/// Observes speech directly so capture state disables actions immediately,
/// even when AppModel has not published a new transcript or other change.
private struct VoiceIdleModifier: ViewModifier {
    @ObservedObject var speech: SpeechController

    func body(content: Content) -> some View {
        content
            .disabled(speech.isStarting || speech.isListening || speech.isFinishing)
            .help(speech.isStarting || speech.isListening || speech.isFinishing ? "Finish dictation before editing or running the command." : "Review your command before running.")
    }
}

private struct VoiceErrorNotice: View {
    @ObservedObject var speech: SpeechController
    var body: some View {
        if let error = speech.error {
            InlineNotice(icon: "mic.slash", text: error, color: Palette.danger)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
        }
    }
}

private struct Eyebrow: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(1.1)
            .foregroundStyle(Palette.secondary)
    }
}

private struct InlineNotice: View {
    let icon: String
    let text: String
    let color: Color
    var body: some View {
        Label(text, systemImage: icon)
            .font(.system(size: 12))
            .foregroundStyle(color)
            .lineSpacing(4)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(13)
            .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SemanticButtonStyle(tone: .blue).makeBody(configuration: configuration)
    }
}

private struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SemanticButtonStyle(tone: .neutral).makeBody(configuration: configuration)
    }
}

private struct SemanticButtonStyle: ButtonStyle {
    let tone: ButtonTone
    func makeBody(configuration: Configuration) -> some View {
        ButtonSurface(tone: tone, pressed: configuration.isPressed) { configuration.label }
    }
}

private struct ButtonSurface<Label: View>: View {
    let tone: ButtonTone
    let pressed: Bool
    @ViewBuilder let label: () -> Label
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @State private var hovered = false

    var body: some View {
        label()
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(tone.foreground)
            .padding(.horizontal, 13)
            .frame(minHeight: 34)
            .background(tone.fill, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(hovered && isEnabled ? 0.09 : 0)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(isFocused ? Palette.blue : Color.clear, lineWidth: 2).padding(-3))
            .opacity(isEnabled ? (pressed ? 0.78 : 1) : 0.42)
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

private struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.light.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Settings").font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text("Make Lite CU work your way.").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.cancelAction)
            }
            .padding(22)
            Rectangle().fill(Palette.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    appearanceSection
                    settingsDivider
                    if model.isRunning {
                        InlineNotice(icon: "lock", text: "Run settings are locked until the current task ends.", color: Palette.secondary)
                    }
                    connectionSection
                    if model.backend == "OpenAI API" {
                        keySection
                    }
                    settingsDivider
                    executionSection
                    settingsDivider
                    if model.executionTarget == .backgroundArc { arcSection } else { permissionsSection }
                    privacySection
                }
                .padding(22)
            }
        }
        .frame(width: 580, height: 680)
        .foregroundStyle(Palette.text)
        .background(Palette.background)
        .tint(Palette.blue)
        .preferredColorScheme(AppAppearance(rawValue: appearance)?.colorScheme)
        .onAppear { model.refreshPermissions() }
    }

    private var appearanceSection: some View {
        HStack(spacing: 18) {
            settingLabel("Appearance", detail: "Choose a theme for the app.")
            Spacer(minLength: 12)
            Picker("Appearance", selection: $appearance) {
                ForEach(AppAppearance.allCases) { theme in Text(theme.rawValue).tag(theme.rawValue) }
            }
            .labelsHidden()
            .accessibilityLabel("Appearance")
            .pickerStyle(.segmented)
            .frame(width: 226)
        }
    }

    private var settingsDivider: some View { Rectangle().fill(Palette.line).frame(height: 1) }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "MODEL CONNECTION")
            HStack(spacing: 18) {
                settingLabel("Provider", detail: "Choose how the model connects.")
                Spacer(minLength: 12)
                Picker("Backend", selection: $model.backend) {
                    Text("Codex").tag("Codex")
                    Text("OpenAI API").tag("OpenAI API")
                }
                .labelsHidden()
                .accessibilityLabel("Model provider")
                .pickerStyle(.segmented)
                .frame(width: 226)
                .disabled(model.isRunning || model.isCheckingCodex)
            }
            if model.backend == "Codex" {
                Text("Use your existing Codex sign-in. No API key needed.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondary)
                TextField("Path to the Codex executable", text: $model.codexPath)
                    .font(.system(size: 11, design: .monospaced))
                    .textFieldStyle(.plain)
                    .padding(11)
                    .background(Palette.panel, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line))
                    .disabled(model.isRunning || model.isCheckingCodex)
                HStack(alignment: .center, spacing: 12) {
                    Text(model.codexStatus)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(model.isCheckingCodex ? "Checking…" : "Check connection", action: model.checkCodex)
                        .buttonStyle(PrimaryButtonStyle())
                        .fixedSize()
                        .disabled(model.isRunning || model.isCheckingCodex || model.codexPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var keySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "OPENAI CONNECTION")
            HStack {
                Text("API key").font(.system(size: 13, weight: .medium))
                Spacer()
                if model.keySaved {
                    Label("Saved in Keychain", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.accent)
                }
            }
            SecureField(model.keySaved ? "Enter a replacement API key" : "Enter your OpenAI API key", text: $model.apiKeyInput)
                .textFieldStyle(.plain)
                .padding(11)
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line))
                .disabled(model.isRunning)
            HStack {
                Text("Stored securely in macOS Keychain.")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.secondary)
                Spacer()
                if model.keySaved {
                    Button("Remove", action: model.removeKey).buttonStyle(SemanticButtonStyle(tone: .red)).disabled(model.isRunning)
                }
                Button("Save key", action: model.saveKey)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isRunning)
            }
            if let message = model.keyMessage {
                Text(message).font(.system(size: 11)).foregroundStyle(Palette.secondary)
            }
            Text("Model access depends on your API account. The model names shown in Codex may not be available through your API key.")
                .font(.system(size: 10))
                .foregroundStyle(Palette.secondary)
                .lineSpacing(4)
        }
    }

    private var executionSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow(text: "EXECUTION")
            HStack(spacing: 18) {
                settingLabel("Target", detail: "Desktop controls apps. Arc controls a dedicated browser tab.")
                Spacer(minLength: 12)
                Picker("Execution target", selection: $model.executionTarget) {
                    ForEach(ExecutionTarget.allCases) { target in Text(target.rawValue).tag(target) }
                }
                .labelsHidden().accessibilityLabel("Execution target")
                .frame(width: 226)
                .disabled(model.isCheckingArc)
            }
            HStack(spacing: 18) {
                Text("Action approval").font(.system(size: 12, weight: .medium))
                Spacer(minLength: 12)
                ApprovalLevelPicker(selection: $model.approvalMode).frame(width: 226)
            }
            Text(model.approvalMode.explanation)
                .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 18) {
                settingLabel("Parallel planning agents", detail: "Compare a route and verification plan before acting.")
                Spacer(minLength: 12)
                Toggle("Parallel planning agents", isOn: $model.useSubagents)
                    .labelsHidden().fixedSize()
            }
            HStack {
                settingLabel("Action limit", detail: "Stop after this many steps in one run.")
                Spacer()
                HStack(spacing: 10) {
                    Text("\(model.maxSteps)").font(.system(size: 12, weight: .medium)).monospacedDigit().frame(width: 24, alignment: .trailing)
                    Stepper("Action limit", value: $model.maxSteps, in: 1...30).labelsHidden()
                }
                .fixedSize()
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .disabled(model.isRunning)
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Eyebrow(text: "MAC PERMISSIONS")
                Spacer()
                Button("Refresh", action: model.refreshPermissions)
                    .buttonStyle(PrimaryButtonStyle())
            }
            permissionRow("Accessibility", detail: "Allows clicks, typing, and keyboard shortcuts.", granted: model.accessibilityGranted, action: model.requestAccessibility)
            permissionRow("Screen recording", detail: "Allows the agent to see your desktop.", granted: model.screenRecordingGranted, action: model.requestScreenRecording)
            Text("Microphone access is requested when you first use voice. Whisper transcribes recordings on this Mac. macOS may require restarting the app after a permission change.")
                .font(.system(size: 10))
                .foregroundStyle(Palette.secondary)
                .lineSpacing(4)
        }
    }

    private var arcSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "BACKGROUND ARC SETUP")
            Text("Allow Lite CU to automate Arc when macOS asks. In Arc, choose View → Developer → Allow JavaScript from Apple Events for page controls.")
                .font(.system(size: 12)).foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)
            Text("Works in a dedicated Arc tab using page text and elements. Opening the task window may briefly bring Arc forward. Desktop Accessibility and Screen Recording are not required for this target.")
                .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .center, spacing: 14) {
                Text(model.arcStatus)
                    .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(model.isCheckingArc ? "Checking…" : "Check Arc setup", action: model.checkArcConnection)
                    .buttonStyle(PrimaryButtonStyle()).fixedSize()
                    .disabled(model.isRunning || model.isCheckingArc)
            }
        }
    }

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("What leaves your Mac", systemImage: "network")
                .font(.system(size: 12, weight: .medium))
            Text("Live runs send your command and relevant action history to OpenAI, plus desktop screenshots for Desktop or page text and elements for Background Arc. Whisper transcribes voice locally; audio stays on this Mac. Demo runs simulate the workflow without sending a task to OpenAI.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.secondary)
                .lineSpacing(5)
        }
        .padding(15)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 10))
    }

    private func settingLabel(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 12, weight: .medium))
            Text(detail).font(.system(size: 11)).foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func permissionRow(_ title: String, detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            settingLabel(title, detail: detail)
            Spacer()
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.accent)
            } else {
                Button("Enable", action: action).buttonStyle(PrimaryButtonStyle()).disabled(model.isRunning)
            }
        }
    }
}
