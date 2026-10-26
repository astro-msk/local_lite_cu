import SwiftUI
import AppKit
import LiteCUCore

private enum Palette {
    static let background = Color(red: 0.055, green: 0.065, blue: 0.065)
    static let sidebar = Color(red: 0.075, green: 0.085, blue: 0.083)
    static let panel = Color(red: 0.092, green: 0.104, blue: 0.100)
    static let elevated = Color(red: 0.125, green: 0.139, blue: 0.132)
    static let line = Color.white.opacity(0.085)
    static let text = Color(red: 0.91, green: 0.93, blue: 0.88)
    static let secondary = Color(red: 0.57, green: 0.62, blue: 0.58)
    static let accent = Color(red: 0.80, green: 0.93, blue: 0.43)
    static let amber = Color(red: 0.97, green: 0.74, blue: 0.40)
}

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 188)
            Rectangle().fill(Palette.line).frame(width: 1)
            VStack(spacing: 0) {
                topBar
                Rectangle().fill(Palette.line).frame(height: 1)
                HStack(alignment: .top, spacing: 0) {
                    mainContent.frame(maxWidth: .infinity, maxHeight: .infinity)
                    Rectangle().fill(Palette.line).frame(width: 1)
                    sessionPanel.frame(width: 252)
                }
            }
        }
        .foregroundStyle(Palette.text)
        .background(Palette.background)
        .tint(Palette.accent)
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
                    .foregroundStyle(Palette.background)
                    .frame(width: 35, height: 35)
                    .background(Palette.accent, in: RoundedRectangle(cornerRadius: 10))
                Text("lite cu").font(.system(size: 22, weight: .semibold, design: .rounded))
            }
            .padding(.top, 48)
            .padding(.bottom, 42)

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
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 16)
        .background(Palette.sidebar)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "desktopcomputer").font(.system(size: 13))
            Text("This Mac").font(.system(size: 12, weight: .medium))
            Spacer()
            Text(model.backend)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(Palette.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: 5))
            Picker("Model", selection: $model.modelName) {
                Text("GPT 6.1 Sol").tag("gpt-6.1-sol")
                Text("GPT 6 Sol").tag("gpt-6-sol")
            }
            .labelsHidden()
            .frame(width: 137)
            .disabled(model.isRunning)
            Picker("Execution mode", selection: $model.demoMode) {
                Text("Demo").tag(true)
                Text("Live").tag(false)
            }
            .labelsHidden()
            .accessibilityLabel("Execution mode")
            .pickerStyle(.segmented)
            .frame(width: 116)
            .disabled(model.isRunning)
        }
        .foregroundStyle(Palette.secondary)
        .padding(.horizontal, 24)
        .frame(height: 68)
    }

    private var mainContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                introduction
                composer
                workflow
                if let error = model.errorMessage {
                    InlineNotice(icon: "exclamationmark.triangle", text: error, color: Palette.amber)
                }
                if let action = model.pendingAction {
                    approvalCard(action)
                }
                timeline
            }
            .padding(.horizontal, 28)
            .padding(.top, 31)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 9) {
            Eyebrow(text: "A LITTLE HELP ON YOUR DESKTOP")
            Text("What should we do?")
                .font(.system(size: 29, weight: .medium, design: .rounded))
                .tracking(-0.7)
            Text("Speak or type a task. Follow every step.")
                .font(.system(size: 13))
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
                    .frame(minHeight: 87, maxHeight: 112)
                    .disabled(model.isRunning)
                    .accessibilityLabel("Task to perform")
            }
            .padding(.horizontal, 15)
            .padding(.top, 12)

            HStack(spacing: 10) {
                VoiceControl(speech: model.speech, isRunning: model.isRunning, toggle: model.toggleVoice)
                Spacer(minLength: 0)
                if model.isRunning {
                    Button(action: model.stop) {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(".", modifiers: .command)
                } else {
                    Button(action: model.run) {
                        HStack(spacing: 8) {
                            Text(model.demoMode ? "Run demo" : "Run task")
                            Image(systemName: "arrow.up.right")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(14)
            Rectangle().fill(Palette.line).frame(height: 1)
            HStack(spacing: 7) {
                Image(systemName: model.demoMode ? "play.rectangle" : "eye")
                Text(model.demoMode ? "Demo simulates actions. Your desktop stays untouched." : "Live sends your command and screenshots to OpenAI.")
            }
            .font(.system(size: 10))
            .foregroundStyle(Palette.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
        }
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.line))
    }

    private var workflow: some View {
        HStack(spacing: 0) {
            WorkflowStep(number: 1, title: "Voice", icon: "waveform", active: stageIndex == 0, complete: stageIndex > 0)
            workflowConnector
            WorkflowStep(number: 2, title: "Plan", icon: "list.bullet", active: stageIndex == 1, complete: stageIndex > 1)
            workflowConnector
            WorkflowStep(number: 3, title: "Act", icon: "cursorarrow", active: stageIndex == 2, complete: stageIndex > 2)
            workflowConnector
            WorkflowStep(number: 4, title: "Result", icon: "checkmark", active: stageIndex == 3, complete: false)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Workflow: Voice, Plan, Act, Result. Current state: \(model.stage)")
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

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 16) {
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
                if !model.result.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("RESULT", systemImage: "checkmark.circle")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .tracking(1)
                            .foregroundStyle(Palette.accent)
                        Text(model.result)
                            .font(.system(size: 13))
                            .lineSpacing(5)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .background(Palette.accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(Palette.accent.opacity(0.20)))
                }
            }
        }
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
                    Text("Start with something small")
                        .font(.system(size: 14, weight: .medium))
                    Text("The plan, agent notes, and desktop actions will appear here as the task runs.")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondary)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button {
                model.demoMode = true
                model.command = "Open Safari and search for SwiftUI tutorials"
                model.run()
            } label: {
                HStack(spacing: 8) {
                    Text("Try a simulated browser task")
                    Spacer()
                    Image(systemName: "arrow.right")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.text)
                .padding(12)
                .background(Palette.elevated, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(model.isRunning)
        }
        .padding(19)
        .background(Palette.panel.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
    }

    private func approvalCard(_ action: DesktopAction) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Label("Your approval is needed", systemImage: "hand.raised")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.amber)
            Text(action.summary).font(.system(size: 12)).lineSpacing(4)
            VStack(alignment: .leading, spacing: 8) {
                Text(action.name).font(.system(size: 11, weight: .semibold, design: .monospaced))
                Text(actionArguments(action))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Palette.background, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Reject & stop", action: model.reject).buttonStyle(SecondaryButtonStyle())
                Spacer()
                Button("Approve action", action: model.approve).buttonStyle(PrimaryButtonStyle())
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
            VStack(alignment: .leading, spacing: 25) {
                VStack(alignment: .leading, spacing: 16) {
                    Eyebrow(text: "SESSION")
                    HStack(spacing: 10) {
                        if model.isRunning {
                            ProgressView().controlSize(.small).scaleEffect(0.8)
                        } else {
                            Circle().fill(statusColor).frame(width: 7, height: 7)
                        }
                        Text(model.stage).font(.system(size: 15, weight: .medium))
                    }
                    Text(model.demoMode ? "A simulated run for testing the workflow." : (model.accessibilityGranted && model.screenRecordingGranted ? "Ready to use your local desktop." : "Enable desktop permissions before starting a live task."))
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
            .padding(22)
            .padding(.top, 10)
        }
        .scrollIndicators(.hidden)
    }

    private var agentsPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Eyebrow(text: "AGENT TEAM")
            AgentRow(title: "Coordinator", subtitle: model.stage == "Planning" ? "Planning the task" : (model.isRunning ? "Managing this run" : "Plans and delegates"), symbol: "point.3.connected.trianglepath.dotted", active: model.isRunning)
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
            if model.backend == "OpenAI API" {
                ConfigurationRow(title: "API key", value: model.keySaved ? "Saved" : "Not set", good: model.keySaved)
            }
            ConfigurationRow(title: "Accessibility", value: model.accessibilityGranted ? "Allowed" : "Not enabled", good: model.accessibilityGranted)
            ConfigurationRow(title: "Screen recording", value: model.screenRecordingGranted ? "Allowed" : "Not enabled", good: model.screenRecordingGranted)
        }
    }

    private var panelDivider: some View { Rectangle().fill(Palette.line).frame(height: 1) }

    private var statusColor: Color {
        if model.stage == "Failed" || model.stage == "Stopped" { return Palette.amber }
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
                Image(systemName: speech.isListening ? "stop.fill" : "mic")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(speech.isListening ? Palette.background : Palette.text)
                    .frame(width: 34, height: 34)
                    .background(speech.isListening ? Palette.accent : Palette.elevated, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(isRunning)
            .accessibilityLabel(speech.isListening ? "Stop dictation" : "Start dictation")
            VStack(alignment: .leading, spacing: 2) {
                Text(speech.isListening ? "Listening…" : "Voice command")
                    .font(.system(size: 10, weight: .medium))
                if let error = speech.error {
                    Text(error).font(.system(size: 9)).foregroundStyle(Palette.amber).lineLimit(2)
                } else {
                    Text(speech.isListening ? "Speak, then stop to review" : "Click to dictate")
                        .font(.system(size: 9))
                        .foregroundStyle(Palette.secondary)
                }
                Text(speech.recognitionMode)
                    .font(.system(size: 9))
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
                Text(title).font(.system(size: 11, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 10))
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
        .font(.system(size: 10))
    }
}

private struct Eyebrow: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .tracking(1.3)
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
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Palette.background)
            .padding(.horizontal, 15)
            .padding(.vertical, 10)
            .background(Palette.accent.opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Palette.elevated.opacity(configuration.isPressed ? 0.6 : 1), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line))
    }
}

private struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow(text: "LITE CU")
                    Text("Settings").font(.system(size: 24, weight: .medium, design: .rounded))
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
            }
            .padding(25)
            Rectangle().fill(Palette.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 27) {
                    if model.isRunning {
                        InlineNotice(icon: "lock", text: "Run settings are locked until the current task ends.", color: Palette.secondary)
                    }
                    connectionSection
                    if model.backend == "OpenAI API" {
                        keySection
                    }
                    executionSection
                    permissionsSection
                    privacySection
                }
                .padding(25)
            }
        }
        .frame(width: 560, height: 680)
        .foregroundStyle(Palette.text)
        .background(Palette.background)
        .tint(Palette.accent)
        .onAppear { model.refreshPermissions() }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "MODEL CONNECTION")
            Picker("Backend", selection: $model.backend) {
                Text("Codex").tag("Codex")
                Text("OpenAI API").tag("OpenAI API")
            }
            .pickerStyle(.segmented)
            .disabled(model.isRunning)
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
                    .disabled(model.isRunning)
                HStack(alignment: .center, spacing: 12) {
                    Text(model.codexStatus)
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Check connection", action: model.checkCodex)
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(model.isRunning)
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
                    Button("Remove", action: model.removeKey).buttonStyle(SecondaryButtonStyle()).disabled(model.isRunning)
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
            Toggle(isOn: $model.confirmActions) {
                settingLabel("Approve desktop actions", detail: "Review each action before it changes your desktop.")
            }
            Toggle(isOn: $model.useSubagents) {
                settingLabel("Parallel planning agents", detail: "Independent agents help plan and review the task.")
            }
            HStack {
                settingLabel("Action limit", detail: "Stop after this many steps in one run.")
                Spacer()
                Stepper(value: $model.maxSteps, in: 1...30) {
                    Text("\(model.maxSteps)").monospacedDigit().frame(width: 25)
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
                    .font(.system(size: 10))
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.accent)
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
            Text(detail).font(.system(size: 10)).foregroundStyle(Palette.secondary)
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
                Button("Enable", action: action).buttonStyle(SecondaryButtonStyle()).disabled(model.isRunning)
            }
        }
    }
}
