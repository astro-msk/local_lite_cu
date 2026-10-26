import SwiftUI
import LiteCUCore

/// An intrinsic-height graph. The workspace owns scrolling and targets each node's UUID.
struct WorkflowGraphView: View {
    let nodes: [WorkflowNode]
    let isRunning: Bool
    let stage: String
    var isReadOnly: Bool = false
    let onApprove: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if nodes.isEmpty {
                emptyGuide
            } else {
                ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                    WorkflowGraphRow(node: node, number: index + 1, isLast: index == nodes.count - 1,
                                     isRunning: isRunning, isReadOnly: isReadOnly, onApprove: onApprove, onReject: onReject)
                        .id(node.id)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(nodes.isEmpty ? "Workflow guide. No task has started." : "Task workflow, \(stage)")
    }

    private var emptyGuide: some View {
        VStack(spacing: 0) {
            guideRow("Input", symbol: "text.bubble", detail: "Type or dictate what you want to do.", isLast: false)
            guideRow("Plan", symbol: "point.3.connected.trianglepath.dotted", detail: "See the proposed route and how success will be checked.", isLast: false)
            guideRow("Act", symbol: "cursorarrow", detail: "Follow each action and the desktop observation that comes next.", isLast: false)
            guideRow("Result", symbol: "checkmark", detail: "Review the outcome and the path taken.", isLast: true)
        }
        .padding(.vertical, 6)
    }

    private func guideRow(_ title: String, symbol: String, detail: String, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.secondary)
                .frame(width: 28, height: 28)
                .background(Palette.elevated, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 5)
            Spacer(minLength: 0)
        }
        .padding(.bottom, isLast ? 0 : 22)
        .background(alignment: .leading) {
            if !isLast { WorkflowSpine().stroke(Palette.line, style: StrokeStyle(lineWidth: 1, dash: [3, 4])).frame(width: 28) }
        }
    }
}

private struct WorkflowGraphRow: View {
    let node: WorkflowNode
    let number: Int
    let isLast: Bool
    let isRunning: Bool
    let isReadOnly: Bool
    let onApprove: () -> Void
    let onReject: () -> Void

    var body: some View {
        row
        .padding(.bottom, isLast ? 0 : 18)
        .background(alignment: .leading) {
            if !isLast { WorkflowSpine().stroke(Palette.line, lineWidth: 1).frame(width: 28) }
        }
        .accessibilityElement(children: .contain)
    }

    private var row: some View {
        HStack(alignment: .top, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Text("\(number)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(node.status.tint)
                    .frame(width: 28, height: 28)
                    .background(Palette.panel, in: Circle())
                    .overlay(Circle().stroke(node.status.tint.opacity(node.status == .complete ? 0.30 : 0.65), lineWidth: 1))
                    .accessibilityLabel("Step \(number), \(node.kind.label)")
                Text(node.kind.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.secondary)
                    .padding(.top, 7)
            }
            .frame(width: 112, alignment: .leading)
            card
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(node.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                WorkflowStatusPill(status: node.status, isRunning: isRunning, isResult: node.kind == .result)
            }
            if !isReadOnly, node.status == .awaitingApproval, let action = node.action {
                ActionApprovalCard(action: action, onApprove: onApprove, onReject: onReject)
            } else if node.kind == .planning {
                WorkflowPlanningDetails(detail: node.detail, notes: node.notes)
            } else {
                if !node.detail.isEmpty {
                    WorkflowReadableText(text: node.detail, initiallyLimited: node.kind != .result)
                }
                if let action = node.action {
                    WorkflowActionDetails(action: action)
                }
                if !node.notes.isEmpty {
                    if node.kind == .observation {
                        ForEach(node.notes, id: \.self) { note in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "arrow.turn.down.right").font(.system(size: 10)).padding(.top, 3)
                                WorkflowReadableText(text: note, initiallyLimited: true)
                            }
                            .foregroundStyle(Palette.secondary)
                        }
                    } else {
                        DisclosureGroup("Step notes") {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(node.notes, id: \.self) { note in WorkflowReadableText(text: note, initiallyLimited: false) }
                            }
                            .padding(.top, 6)
                        }
                        .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    }
                }
            }
        }
        .padding(node.kind == .planning ? 18 : 15)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(cardBorder, lineWidth: 1))
    }

    private var cardFill: Color {
        switch node.status {
        case .active: return Palette.blue.opacity(0.035)
        case .awaitingApproval: return Palette.amber.opacity(0.035)
        case .failed: return Palette.danger.opacity(0.035)
        default: return Palette.panel
        }
    }

    private var cardBorder: Color {
        switch node.status {
        case .active, .awaitingApproval, .failed: return node.status.tint.opacity(0.35)
        default: return Palette.line
        }
    }
}

private struct WorkflowSpine: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: 14, y: 29))
            path.addLine(to: CGPoint(x: 14, y: rect.maxY))
        }
    }
}

private struct WorkflowStatusPill: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let status: WorkflowNodeStatus
    let isRunning: Bool
    let isResult: Bool

    var body: some View {
        HStack(spacing: 5) {
            if status == .active && isRunning && !reduceMotion {
                ProgressView().controlSize(.mini).scaleEffect(0.75).frame(width: 11, height: 11)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: status.symbol).font(.system(size: 9, weight: .semibold)).accessibilityHidden(true)
            }
            Text(isResult && status == .complete ? "Run finished" : status.label).font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(status.tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(status.tint.opacity(status == .complete ? 0.06 : 0.09), in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

private struct WorkflowPlanningDetails: View {
    let detail: String
    let notes: [String]

    private var advisorNotes: [String] {
        ["Route planner:", "Verifier:"].compactMap { prefix in notes.first(where: { $0.hasPrefix(prefix) }) }
    }

    private var contextNotes: [String] {
        notes.filter { !$0.hasPrefix("Route planner:") && !$0.hasPrefix("Verifier:") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !advisorNotes.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(advisorNotes, id: \.self) { note in
                        WorkflowPlanningNote(note: note).frame(minWidth: 0, maxWidth: .infinity)
                    }
                }
                PlanningMergeConnector(branches: advisorNotes.count)
                    .stroke(Palette.line, lineWidth: 1)
                    .frame(height: 24)
                    .accessibilityHidden(true)
            }
            if !detail.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    if !advisorNotes.isEmpty {
                        Label("Coordinator plan", systemImage: "arrow.triangle.merge")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Palette.blue)
                    }
                    WorkflowCoordinatorPlan(text: detail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(advisorNotes.isEmpty ? 0 : 14)
                .background(advisorNotes.isEmpty ? Color.clear : Palette.elevated.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
            }
            if !contextNotes.isEmpty {
                DisclosureGroup("Context & next step") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(contextNotes, id: \.self) { note in WorkflowReadableText(text: note, initiallyLimited: false) }
                    }
                    .padding(.top, 7)
                }
                .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                .padding(.top, 12)
            }
        }
    }
}

private struct WorkflowCoordinatorPlan: View {
    let text: String

    private struct Step {
        let number: String
        var text: String
    }

    /// Preserve the model's numbers and wording. Arbitrary prose stays ordinary prose.
    private var numberedPlan: (introduction: String, steps: [Step])? {
        guard let pattern = try? NSRegularExpression(pattern: #"^\s*(\d{1,3})[.)]\s+(.+)$"#) else { return nil }
        var introduction: [String] = []
        var steps: [Step] = []
        for line in text.components(separatedBy: .newlines) {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if let match = pattern.firstMatch(in: line, range: range),
               let numberRange = Range(match.range(at: 1), in: line),
               let textRange = Range(match.range(at: 2), in: line) {
                steps.append(Step(number: String(line[numberRange]), text: String(line[textRange])))
            } else if steps.isEmpty {
                introduction.append(line)
            } else {
                steps[steps.count - 1].text += "\n" + line
            }
        }
        guard !steps.isEmpty else { return nil }
        return (introduction.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), steps)
    }

    var body: some View {
        if let plan = numberedPlan {
            VStack(alignment: .leading, spacing: 13) {
                if !plan.introduction.isEmpty { WorkflowReadableText(text: plan.introduction, initiallyLimited: false) }
                ForEach(Array(plan.steps.enumerated()), id: \.offset) { _, step in
                    HStack(alignment: .top, spacing: 10) {
                        Text(step.number)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Palette.blue)
                            .frame(width: 22, height: 22)
                            .background(Palette.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                        WorkflowReadableText(text: step.text.trimmingCharacters(in: .whitespacesAndNewlines), initiallyLimited: false)
                            .padding(.top, 2)
                    }
                }
            }
        } else {
            WorkflowReadableText(text: text, initiallyLimited: false)
        }
    }
}

private struct PlanningMergeConnector: Shape {
    let branches: Int

    func path(in rect: CGRect) -> Path {
        Path { path in
            if branches > 1 {
                let leftCenter = (rect.width - 10) / 4
                let rightCenter = rect.width - leftCenter
                path.move(to: CGPoint(x: leftCenter, y: 0))
                path.addLine(to: CGPoint(x: leftCenter, y: 10))
                path.addLine(to: CGPoint(x: rightCenter, y: 10))
                path.addLine(to: CGPoint(x: rightCenter, y: 0))
                path.move(to: CGPoint(x: rect.midX, y: 10))
            } else {
                path.move(to: CGPoint(x: rect.midX, y: 0))
            }
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        }
    }
}

private struct WorkflowPlanningNote: View {
    let note: String
    @State private var expanded = false

    private var parsed: (title: String, text: String) {
        for role in ["Route planner", "Verifier"] {
            if note.hasPrefix(role + ":") {
                return (role, String(note.dropFirst(role.count + 1)).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return ("Planning note", note)
    }

    private var needsDisclosure: Bool {
        parsed.text.count > 100 || parsed.text.components(separatedBy: .newlines).count > 3
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(parsed.title, systemImage: parsed.title == "Verifier" ? "checkmark.shield" : "arrow.triangle.branch")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.text)
            Text(parsed.text)
                .font(.system(size: 11))
                .foregroundStyle(Palette.secondary)
                .lineSpacing(4)
                .lineLimit(needsDisclosure && !expanded ? 3 : nil)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if needsDisclosure {
                Button {
                    expanded.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Text(expanded ? "Show less" : "Read note")
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .semibold))
                    }
                    .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.blue)
                .accessibilityLabel("\(expanded ? "Collapse" : "Expand") \(parsed.title) note")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.line))
    }
}

private struct WorkflowReadableText: View {
    let text: String
    let initiallyLimited: Bool
    @State private var expanded = false

    private var needsDisclosure: Bool { initiallyLimited && (text.count > 230 || text.components(separatedBy: .newlines).count > 4) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondary)
                .lineSpacing(5)
                .lineLimit(needsDisclosure && !expanded ? 4 : nil)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if needsDisclosure {
                Button(expanded ? "Show less" : "Read more") { expanded.toggle() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.blue)
            }
        }
    }
}

private struct WorkflowActionDetails: View {
    let action: DesktopAction

    var body: some View {
        DisclosureGroup("Action details") {
            ScrollView {
                Text(arguments)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            }
            .frame(height: 160)
        }
        .font(.system(size: 11))
        .foregroundStyle(Palette.secondary)
    }

    private var arguments: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(action.arguments) else { return "Action details unavailable" }
        return String(decoding: data, as: UTF8.self)
    }
}

private extension WorkflowNodeKind {
    var label: String {
        switch self {
        case .input: return "Input"
        case .planning: return "Plan"
        case .action: return "Action"
        case .observation: return "Observe"
        case .result: return "Result"
        }
    }
}

private extension WorkflowNodeStatus {
    var label: String {
        switch self {
        case .active: return "In progress"
        case .awaitingApproval: return "Approval needed"
        case .complete: return "Done"
        case .stopped: return "Stopped"
        case .failed: return "Failed"
        }
    }

    var symbol: String {
        switch self {
        case .active: return "ellipsis"
        case .awaitingApproval: return "hand.raised.fill"
        case .complete: return "checkmark"
        case .stopped: return "stop.fill"
        case .failed: return "exclamationmark"
        }
    }

    var tint: Color {
        switch self {
        case .active: return Palette.blue
        case .awaitingApproval, .stopped: return Palette.amber
        case .complete: return Palette.accent
        case .failed: return Palette.danger
        }
    }
}
