import SwiftUI
import AppKit
import LiteCUCore

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 184)
            Rectangle().fill(Palette.line).frame(width: 1)
            VStack(spacing: 0) {
                topBar
                Rectangle().fill(Palette.line).frame(height: 1)
                HStack(alignment: .top, spacing: 0) {
                    mainContent.frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
                    Rectangle().fill(Palette.line).frame(width: 1)
                    sessionPanel.frame(width: 274)
                }
            }
        }
        .foregroundStyle(Palette.text)
        .background(Palette.background)
        .tint(Palette.blue)
        .sheet(isPresented: $model.showSettings) {
            SettingsView(model: model)
        }
        .onAppear { model.refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "cursorarrow.motionlines")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Palette.onBrand)
                    .frame(width: 32, height: 32)
                    .background(Palette.brandFill, in: RoundedRectangle(cornerRadius: 9))
                Text("lite cu").font(.system(size: 21, weight: .semibold, design: .rounded))
            }
            .padding(.top, 38)
            .padding(.bottom, 26)

            Eyebrow(text: "LOCAL WORKSPACE")
                .padding(.bottom, 13)
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up")
                    .foregroundStyle(Palette.accent)
                Text("Current session").font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Palette.elevated, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.line))

            Spacer()

            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Circle().fill(model.demoMode ? Palette.amber : Palette.accent).frame(width: 6, height: 6)
                    Text(model.demoMode ? "SIMULATION MODE" : "LIVE MODE")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(1)
                }
                Text(model.demoMode ? "Explore the workflow with a simulated desktop." : "Actions run on this Mac. You remain in control.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
            .padding(.bottom, 18)

            Button { model.showSettings = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "slider.horizontal.3")
                    Text("Settings")
                    Spacer()
                    Text("⌘,").font(.system(size: 11, design: .monospaced))
                }
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondary)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 14)
        }
        .padding(.horizontal, 16)
        .background(Palette.sidebar)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "desktopcomputer").font(.system(size: 13))
            Text("This Mac").font(.system(size: 12, weight: .medium))
            Spacer()
            if model.isRunning {
                Button(action: model.stop) { Label(model.stage == "Stopping" ? "Stopping…" : "Stop", systemImage: "stop.fill") }
                    .buttonStyle(SemanticButtonStyle(tone: .red))
                    .disabled(model.stage == "Stopping")
                    .keyboardShortcut(".", modifiers: .command)
            }
            Text(model.backend)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.secondary)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Palette.elevated, in: RoundedRectangle(cornerRadius: 6))
            Picker("Model", selection: $model.modelName) {
                Text("GPT 6.1 Sol").tag("gpt-6.1-sol")
                Text("GPT 6 Sol").tag("gpt-6-sol")
            }
            .labelsHidden()
            .controlSize(.regular)
            .frame(width: 136, height: 28)
            .disabled(model.isRunning)
            Picker("Execution mode", selection: $model.demoMode) {
                Text("Demo").tag(true)
                Text("Live").tag(false)
            }
            .labelsHidden()
            .accessibilityLabel("Execution mode")
            .pickerStyle(.segmented)
            .controlSize(.regular)
            .frame(width: 118, height: 28)
            .disabled(model.isRunning)
        }
        .foregroundStyle(Palette.secondary)
        .padding(.horizontal, 22)
        .frame(height: 58)
    }

    private var mainContent: some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    introduction
                    composer.id("composer")
                    workflow
                    if let error = model.errorMessage {
                        InlineNotice(icon: "exclamationmark.triangle", text: error, color: Palette.amber)
                    }
                    if let action = model.pendingAction {
                        approvalCard(action).id("approval")
                    }
                    timeline
                }
                .padding(.horizontal, 22)
                .padding(.top, 24)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .onChange(of: model.pendingAction) { _, action in
                if action != nil {
                    withAnimation(.easeInOut(duration: 0.2)) { scroll.scrollTo("approval", anchor: .top) }
                }
            }
            .onChange(of: model.result) { _, result in
                if !result.isEmpty {
                    withAnimation(.easeInOut(duration: 0.2)) { scroll.scrollTo("result", anchor: .top) }
                }
            }
            .onChange(of: model.isRunning) { _, running in
                if running {
                    withAnimation(.easeInOut(duration: 0.2)) { scroll.scrollTo("composer", anchor: .top) }
                }
            }
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your desktop assistant")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .tracking(-0.4)
            Text("Give it a task. Review the plan. Follow the progress.")
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondary)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                if model.command.isEmpty {
                    Text("Ask me to do something on your Mac…")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.secondary)
                        .padding(.top, 10)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $model.command)
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.text)
                    .scrollContentBackground(.hidden)
                    .frame(height: 100)
                    .disabled(model.isRunning)
                    .modifier(VoiceIdleModifier(speech: model.speech))
                    .accessibilityLabel("Task to perform")
            }
            .padding(.horizontal, 15)
            .padding(.top, 12)

            HStack(spacing: 10) {
                VoiceControl(speech: model.speech, isRunning: model.isRunning, toggle: model.toggleVoice)
                Spacer(minLength: 0)
                if model.isRunning {
                    Button(action: model.stop) {
                        Label(model.stage == "Stopping" ? "Stopping…" : "Stop task", systemImage: "stop.fill")
                    }
                    .buttonStyle(SemanticButtonStyle(tone: .red))
                    .disabled(model.stage == "Stopping")
                } else {
                    Button(action: model.run) {
                        HStack(spacing: 8) {
                            Text(model.demoMode ? "Run demo" : "Run task")
                            Image(systemName: "arrow.up.right")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .modifier(VoiceIdleModifier(speech: model.speech))
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(14)
            VoiceStatusDetails(speech: model.speech)
            VoiceErrorNotice(speech: model.speech)
            Rectangle().fill(Palette.line).frame(height: 1)
            HStack(spacing: 7) {
                Image(systemName: model.demoMode ? "play.rectangle" : "eye")
                Text(model.demoMode ? "Demo simulates actions. Your desktop stays untouched." : "Live sends your command and screenshots to OpenAI.")
            }
            .font(.system(size: 11))
            .foregroundStyle(Palette.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.line))
    }

    private var workflow: some View {
        HStack(spacing: 0) {
            WorkflowStep(number: 1, title: "Input", icon: "text.cursor", active: stageIndex == 0 && flowActive, complete: stageIndex > 0)
            workflowConnector
            WorkflowStep(number: 2, title: "Plan", icon: "list.bullet", active: stageIndex == 1 && flowActive, complete: stageIndex > 1)
            workflowConnector
            WorkflowStep(number: 3, title: "Act", icon: "cursorarrow", active: stageIndex == 2 && flowActive, complete: stageIndex > 2)
            workflowConnector
            WorkflowStep(number: 4, title: "Result", icon: "checkmark", active: stageIndex == 3 && flowActive, complete: false)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Workflow: Input, Plan, Act, Result. Current state: \(model.stage)")
    }

    private var workflowConnector: some View {
        Rectangle().fill(Palette.line).frame(maxWidth: .infinity).frame(height: 1).padding(.horizontal, 8)
    }

    private var stageIndex: Int {
        switch model.stage {
        case "Planning": return 1
        case "Acting", "Awaiting approval": return 2
        case "Complete": return 3
        default: return model.stepCount > 0 ? 2 : (model.plan.isEmpty ? 0 : 1)
        }
    }

    private var flowActive: Bool { !["Failed", "Stopped", "Stopping"].contains(model.stage) }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !model.result.isEmpty { resultCard.id("result") }
            HStack {
                Eyebrow(text: "ACTIVITY")
                Spacer()
                if !model.events.isEmpty {
                    Text("\(model.events.count) events")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Palette.secondary)
                }
            }

            if model.events.isEmpty {
                emptyTimeline
            } else {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.events) { event in
                        EventCard(event: event)
                    }
                }
            }
        }
    }

    private var resultCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Result", systemImage: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.accent)
            Text(model.result)
                .font(.system(size: 13))
                .lineSpacing(5)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(17)
        .background(Palette.accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Palette.accent.opacity(0.25)))
    }

    private var emptyTimeline: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: "sparkle")
                    .font(.system(size: 19))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 37, height: 37)
                    .background(Palette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.demoMode ? "See how a task runs" : "Start with a small desktop task")
                        .font(.system(size: 14, weight: .medium))
                    Text(model.demoMode ? "Try a simulated browser task to see the plan, actions, and result. No permissions or model connection needed." : "For example: open Safari and search for SwiftUI tutorials. Type it above, or dictate it, then run when ready.")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondary)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                Button {
                    model.demoMode = true
                    model.command = "Open Safari and search for SwiftUI tutorials"
                    model.run()
                } label: {
                    Label("Try demo", systemImage: "play.fill")
                }
                .buttonStyle(SemanticButtonStyle(tone: .blue))
                .disabled(model.isRunning)
                .modifier(VoiceIdleModifier(speech: model.speech))
                Button("Set up live control") { model.showSettings = true }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(19)
        .background(Palette.panel.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line))
    }

    private func approvalCard(_ action: DesktopAction) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Label("Your approval is needed", systemImage: "hand.raised")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.amber)
            Text(action.summary).font(.system(size: 12)).lineSpacing(4).lineLimit(4)
            VStack(alignment: .leading, spacing: 8) {
                Text(action.name).font(.system(size: 11, weight: .semibold, design: .monospaced))
                ScrollView {
                    Text(actionArguments(action))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Palette.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(height: 150)
                .accessibilityLabel("Exact action arguments")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Palette.background, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Reject & stop", action: model.reject).buttonStyle(SemanticButtonStyle(tone: .red))
                Spacer()
                Button("Approve action", action: model.approve).buttonStyle(SemanticButtonStyle(tone: .yellow))
            }
        }
        .padding(17)
        .background(Palette.amber.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.amber.opacity(0.30)))
    }

    private func actionArguments(_ action: DesktopAction) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(action.arguments) else { return "Unable to display arguments" }
        return String(decoding: data, as: UTF8.self)
    }

    private var sessionPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    Eyebrow(text: "SESSION")
                    HStack(spacing: 10) {
                        if model.isRunning {
                            ProgressView().controlSize(.small).scaleEffect(0.8)
                        } else {
                            Circle().fill(statusColor).frame(width: 7, height: 7)
                        }
                        Text(model.stage).font(.system(size: 15, weight: .medium))
                    }
                    Text(model.demoMode ? "A simulated run. Your desktop is untouched." : "Live runs act on this Mac using your selected model.")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondary)
                        .lineSpacing(4)
                    HStack {
                        Text("Actions")
                        Spacer()
                        Text("\(model.stepCount) / \(model.maxSteps)").monospacedDigit()
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondary)
                }
                if !model.demoMode && !model.isRunning { readinessCard }
                panelDivider
                agentsPanel
                panelDivider
                configurationPanel
                if !model.plan.isEmpty {
                    panelDivider
                    VStack(alignment: .leading, spacing: 12) {
                        Eyebrow(text: "CURRENT PLAN")
                        Text(model.plan)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.secondary)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                    }
                }
                panelDivider
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "stop.circle")
                        Text("Emergency stop")
                    }
                    .font(.system(size: 11, weight: .medium))
                    Text("⌘ ⇧ Esc")
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                    Text("Stops the current task, including while another app is in front.")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.secondary)
                        .lineSpacing(4)
                }
            }
            .padding(20)
            .padding(.top, 4)
        }
        .scrollIndicators(.hidden)
    }

    private var readinessCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.accessibilityGranted || !model.screenRecordingGranted {
                Label("Desktop access needed", systemImage: "lock")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.amber)
                Text("Enable \(missingPermissions) to let Lite CU see and control your desktop.")
                    .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Set up permissions") { model.showSettings = true }
                    .buttonStyle(SemanticButtonStyle(tone: .yellow))
            } else if !model.modelConnectionReady {
                Label("Model connection", systemImage: "network")
                    .font(.system(size: 12, weight: .semibold))
                Text(model.modelConnectionSummary)
                    .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    .lineLimit(4)
                if model.backend == "Codex" && !model.codexConnectionChecked && !model.codexPath.isEmpty {
                    Button(model.isCheckingCodex ? "Checking…" : "Check connection", action: model.checkCodex)
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(model.isCheckingCodex)
                    Text("You can also connect by running a task.")
                        .font(.system(size: 10)).foregroundStyle(Palette.secondary)
                } else {
                    Button("Connection settings") { model.showSettings = true }
                        .buttonStyle(PrimaryButtonStyle())
                }
            } else {
                Label("Ready for live tasks", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.accent)
                Text(model.modelConnectionSummary)
                    .font(.system(size: 11)).foregroundStyle(Palette.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Palette.elevated, in: RoundedRectangle(cornerRadius: 9))
    }

    private var missingPermissions: String {
        if !model.accessibilityGranted && !model.screenRecordingGranted { return "Accessibility and Screen Recording" }
        return model.accessibilityGranted ? "Screen Recording" : "Accessibility"
    }

    private var agentsPanel: some View {
        VStack(alignment: .leading, spacing: 13) {
            Eyebrow(text: "AGENT TEAM")
            AgentRow(title: "Coordinator", subtitle: model.stage == "Planning" ? "Planning the task" : (model.stage == "Stopping" ? "Stopping the current run" : (model.isRunning ? "Managing this run" : "Plans and delegates")), symbol: "point.3.connected.trianglepath.dotted", active: model.isRunning && model.stage != "Stopping")
            AgentRow(title: "Route & verification", subtitle: model.useSubagents ? "Parallel planning enabled" : "Parallel planning disabled", symbol: "square.stack.3d.up", active: model.useSubagents && model.stage == "Planning")
            AgentRow(title: "Desktop operator", subtitle: model.stage == "Awaiting approval" ? "Waiting for your approval" : (model.stage == "Acting" ? "Working on the desktop" : "One action at a time"), symbol: "cursorarrow", active: model.stage == "Acting" || model.stage == "Awaiting approval")
        }
    }

    private var configurationPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Eyebrow(text: "CONFIGURATION")
                Spacer()
                Button { model.showSettings = true } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 11))
                }.buttonStyle(.plain).foregroundStyle(Palette.secondary)
                    .accessibilityLabel("Open configuration settings")
            }
            ConfigurationRow(title: "Action approval", value: model.confirmActions ? "On" : "Off", good: model.confirmActions)
            ConfigurationRow(title: "Backend", value: model.backend, good: true)
            Text(model.modelConnectionSummary)
                .font(.system(size: 11))
                .foregroundStyle(model.modelConnectionReady ? Palette.accent : Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.backend == "OpenAI API" {
                ConfigurationRow(title: "Keychain", value: model.keySaved ? "Saved" : "Not saved", good: model.keySaved)
            }
            ConfigurationRow(title: "Accessibility", value: model.accessibilityGranted ? "Allowed" : "Not enabled", good: model.accessibilityGranted)
            ConfigurationRow(title: "Screen recording", value: model.screenRecordingGranted ? "Allowed" : "Not enabled", good: model.screenRecordingGranted)
        }
    }

    private var panelDivider: some View { Rectangle().fill(Palette.line).frame(height: 1) }

    private var statusColor: Color {
        if ["Failed", "Stopped", "Stopping"].contains(model.stage) { return Palette.amber }
        return model.stage == "Ready" ? Palette.secondary : Palette.accent
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
                Text(speech.isFinishing ? "Preparing the final text" : (speech.isListening ? "Click stop when finished" : (speech.isStarting ? "Preparing microphone access" : "Click to dictate")))
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.secondary)
            }
        }
    }

    private var statusTitle: String {
        if speech.isStarting { return "Starting microphone…" }
        if speech.isFinishing { return "Finishing transcript…" }
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
                Text(speech.isFinishing ? "Wait for the final words, then review your command and run." : speech.audioStatus)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(speech.isFinishing ? Palette.amber : Palette.secondary)
            }
            Text(speech.recognitionMode)
                .font(.system(size: 10))
                .foregroundStyle(Palette.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 15)
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
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
        }
    }
}

private struct WorkflowStep: View {
    let number: Int
    let title: String
    let icon: String
    let active: Bool
    let complete: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: complete ? "checkmark" : icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(active || complete ? Palette.accent : Palette.secondary)
                .frame(width: 26, height: 26)
                .background(active ? Palette.accent.opacity(0.1) : Palette.panel, in: Circle())
                .overlay(Circle().stroke(active ? Palette.accent.opacity(0.35) : Palette.line))
            Text(title)
                .font(.system(size: 11, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Palette.text : Palette.secondary)
        }
        .fixedSize()
    }
}

private struct EventCard: View {
    let event: RunEvent

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(Palette.accent.opacity(0.85))
                .frame(width: 26, height: 26)
                .background(Palette.accent.opacity(0.065), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(event.role.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text(event.date, style: .time)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Palette.secondary)
                }
                Text(event.message)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line))
    }

    private var icon: String {
        let role = event.role.lowercased()
        if role.contains("plan") { return "list.bullet" }
        if role.contains("user") { return "person" }
        if role.contains("action") || role.contains("operator") || role.contains("exec") { return "cursorarrow" }
        if role.contains("result") || role.contains("complete") { return "checkmark" }
        if role.contains("error") { return "exclamationmark.triangle" }
        if role.contains("research") || role.contains("agent") || role.contains("review") { return "square.stack.3d.up" }
        return "circle.dotted"
    }
}

private struct AgentRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    let active: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(active ? Palette.accent : Palette.secondary)
                .frame(width: 28, height: 28)
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct ConfigurationRow: View {
    let title: String
    let value: String
    let good: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(Palette.secondary)
            Spacer(minLength: 5)
            Text(value).foregroundStyle(good ? Palette.text : Palette.secondary)
        }
        .font(.system(size: 11))
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
                    permissionsSection
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
                settingLabel("Approve desktop actions", detail: "Pause before clicks, typing, or other desktop changes.")
                Spacer(minLength: 12)
                Toggle("Approve desktop actions", isOn: $model.confirmActions)
                    .labelsHidden().fixedSize()
            }
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
            Text("Microphone and speech recognition access are requested when you first use voice. macOS may require restarting the app after a permission change.")
                .font(.system(size: 10))
                .foregroundStyle(Palette.secondary)
                .lineSpacing(4)
        }
    }

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("What leaves your Mac", systemImage: "network")
                .font(.system(size: 12, weight: .medium))
            Text("Live runs send your command, desktop screenshots, and relevant action history to OpenAI. Voice uses Apple speech recognition and may use Apple servers when on-device recognition is unavailable. Demo runs simulate the workflow without sending a task to OpenAI.")
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
