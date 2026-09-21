#if os(macOS)
import GentleMergeCore
import AppKit
import SwiftUI

/// The real window: who is working on what, what they have told each other, and
/// the shared state of each project. A menu bar popover is too small to read
/// three agents at once, which is exactly what this has to show.
@MainActor
struct MainWindow: View {
    let model: InboxModel

    @State private var selection: String?
    @State private var draft = ""
    @State private var showReview = false
    @State private var showSnapshots = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            if let projectPath = selection ?? model.projects.first?.path {
                ProjectPane(
                    model: model,
                    projectPath: projectPath,
                    draft: $draft,
                    showReview: $showReview,
                    showSnapshots: $showSnapshots
                )
            } else {
                EmptyPane()
            }
        }
        .frame(minWidth: 780, minHeight: 520)
        .onAppear {
            model.refreshBus()
            if selection == nil { selection = model.projects.first?.path }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Section("Running now") {
                if model.liveActivities.isEmpty {
                    Text("No agent sessions")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                ForEach(model.liveActivities) { activity in
                    HStack(spacing: 7) {
                        Circle()
                            .fill(color(for: activity.state))
                            .frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(activity.provider.displayName)
                                .font(.system(size: 11.5, weight: .medium))
                            Text("\(activity.projectName) · \(activity.stateLabel)")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 1)
                    .tag(activity.projectPath ?? "")
                }
            }

            Section("Projects") {
                ForEach(model.projects) { summary in
                    Label(summary.name, systemImage: "folder")
                        .font(.system(size: 12))
                        .tag(summary.path)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func color(for state: AgentActivity.State) -> Color {
        switch state {
        case .working: return .green
        case .waiting: return .orange
        case .idle: return .blue
        case .ended: return .secondary
        }
    }
}

@MainActor
private struct EmptyPane: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text("Nothing running yet")
                .font(.system(size: 13, weight: .medium))
            Text("Start Claude Code or Codex in a project and it shows up here,\n"
                + "along with everything it tells the other agents.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - One project

@MainActor
private struct ProjectPane: View {
    let model: InboxModel
    let projectPath: String
    @Binding var draft: String
    @Binding var showReview: Bool
    @Binding var showSnapshots: Bool

    @State private var handoff: ProjectHandoff?
    /// Merged in at render time, by task id. Never part of the handoff file.
    @State private var claimed: [String: TaskClaim] = [:]
    @State private var newTask = ""
    @State private var requestError: String?

    private var projectName: String { URL(fileURLWithPath: projectPath).lastPathComponent }

    private var agents: [AgentActivity] {
        model.activities
            .filter { $0.projectPath == projectPath && $0.isLive }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var conversation: [AgentMessage] {
        model.messages
            .filter { $0.projectPath == nil || $0.projectPath == projectPath }
            .sorted { $0.at < $1.at }
            .suffix(30)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                agentsSection
                messagesSection
                requestsSection
                automationSection
                HStack(alignment: .top, spacing: 18) {
                    tasksSection.frame(maxWidth: .infinity, alignment: .leading)
                    commitsSection.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
        }
        .navigationTitle(projectName)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.startReview(projectPath: projectPath)
                    showReview = true
                } label: {
                    Label("Review", systemImage: "checkmark.shield")
                }
                .help("Diff, build and tests for what the agents did here")

                Button { showSnapshots = true } label: {
                    Label("Restore points", systemImage: "clock.arrow.circlepath")
                }

                Button {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: projectPath)
                } label: {
                    Label("Finder", systemImage: "folder")
                }
            }
        }
        .sheet(isPresented: $showReview) {
            ReviewView(model: model, onBack: { showReview = false })
                .frame(minWidth: 460, minHeight: 420)
        }
        .sheet(isPresented: $showSnapshots) {
            SnapshotsView(model: model, projectPath: projectPath, onBack: { showSnapshots = false })
                .frame(minWidth: 460, minHeight: 420)
        }
        .onAppear(perform: reload)
        .onChange(of: projectPath) { _, _ in reload() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(projectName)
                .font(.system(size: 20, weight: .semibold))
            Text(projectPath)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
    }

    // MARK: Agents

    private var agentsSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionHeader("WHO IS ON THIS")

            if agents.isEmpty {
                Text("No session running here right now.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            // One ledger scan per render, not one per session: summaries() is
            // memoized on the ledger's size+mtime, so this stays free while
            // the file does not move.
            let costs = Stats.summaries(paths: model.paths).bySession
            ForEach(agents) { activity in
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: activity.provider.symbolName)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(activity.provider.displayName)
                                .font(.system(size: 12.5, weight: .semibold))
                            Text(activity.stateLabel)
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(stateColor(activity.state).opacity(0.15), in: Capsule())
                                .foregroundStyle(stateColor(activity.state))
                            Text(RelativeTime.short(from: activity.updatedAt))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }

                        if let task = activity.currentTask {
                            Text("“\(task)”")
                                .font(.system(size: 12))
                                .fixedSize(horizontal: false, vertical: true)
                        } else if let event = activity.lastEvent {
                            Text(event)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        // What this session has cost so far. Tokens are chars/4
                        // off the ledger, always said as an estimate.
                        if let cost = costs[activity.id], cost.turns > 0 {
                            Text("\(cost.turns) briefings · ≈\(cost.estTokens) tokens (estimate)")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
            }
        }
    }

    private func stateColor(_ state: AgentActivity.State) -> Color {
        switch state {
        case .working: return .green
        case .waiting: return .orange
        case .idle: return .blue
        case .ended: return .secondary
        }
    }

    // MARK: Messages

    /// A kind earns a chip only when it is not the default one: a column of
    /// grey UPDATE badges would say nothing and cost every line its width.
    /// Resolved notes never reach here — they are folded out of the list.
    @ViewBuilder
    private func kindChip(for message: AgentMessage) -> some View {
        if message.effectiveKind != .update {
            Text(message.effectiveKind.rawValue.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .foregroundStyle(tint(for: message.effectiveKind))
                .background(tint(for: message.effectiveKind).opacity(0.14), in: Capsule())
        }
    }

    private func tint(for kind: MessageKind) -> Color {
        switch kind {
        case .urgent: return .red
        case .handoff: return .purple
        case .request, .requestResult: return .teal
        case .fyi, .update, .resolve: return .gray
        }
    }

    private var messagesSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionHeader("WHAT THEY HAVE TOLD EACH OTHER")

            if conversation.isEmpty {
                Text("Nothing yet. Anything written here is handed to every agent"
                    + " on its next turn — and they can write back with `gentlemerge say`.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(conversation) { message in
                HStack(alignment: .top, spacing: 8) {
                    Text(message.from)
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(tint(for: message.from))
                        .frame(width: 54, alignment: .leading)
                    kindChip(for: message)
                    Text(message.text)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Spacer(minLength: 6)
                    Text(RelativeTime.short(from: message.at))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            HStack(spacing: 7) {
                TextField("Tell every agent something…", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { send() }
                Button("Send") { send() }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                Menu {
                    Button("Only for this project") { send(scoped: true) }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
            }
            .padding(.top, 2)
        }
    }

    private func tint(for author: String) -> Color {
        switch author {
        case "you": return .blue
        case "claude": return .purple
        case "codex": return .teal
        case "hermes": return .orange
        default: return .secondary
        }
    }

    private func send(scoped: Bool = false) {
        let text = draft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        model.say(text, project: scoped ? projectPath : nil)
        draft = ""
    }

    private var requestsSection: some View {
        TimelineView(.periodic(from: .now, by: 3)) { _ in
            VStack(alignment: .leading, spacing: 7) {
                SectionHeader("REQUESTS")
                ForEach(Requests(paths: model.paths).all().filter { $0.projectPath == projectPath && $0.state != .acked }) { request in
                    HStack {
                        VStack(alignment: .leading) {
                            Text("\(request.id) · \(request.title)").font(.system(size: 12))
                            Text("\(request.from) → \(request.resolvedTo ?? request.to) · \(request.state.rawValue)")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let logURL = model.requestLogURL(for: request) {
                            Button("Open log") { NSWorkspace.shared.open(logURL) }
                                .buttonStyle(.link)
                                .help(logURL.path)
                        }
                        if request.from == "you" && request.state.isTerminal {
                            Button("Ack") { updateRequest(request, action: "ack") }
                        }
                        if request.state == .assigned || request.state == .queued {
                            Button("Reject") { updateRequest(request, action: "reject") }
                        }
                    }
                }
                if let requestError { Text(requestError).foregroundStyle(.red) }
            }
        }
    }

    private func updateRequest(_ request: AgentRequest, action: String) {
        do {
            _ = try RequestActions.perform(action: action, id: request.id, by: "you", result: nil, paths: model.paths)
            requestError = nil
            reload()
        } catch { requestError = "\(error)" }
    }

    // MARK: Tasks and commits

    /// Who may start headless work, and how much of it per day. Off by
    /// default; delegated lets agents trigger within tiers and budget; strict
    /// only runs human-created requests and parks the rest for approval here.
    private var automationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader("HEADLESS WORK")
            Picker("Dispatch mode", selection: Binding(
                get: { model.config.dispatchMode },
                set: { model.config.dispatchMode = $0; reload() }
            )) {
                Text("Off").tag("off")
                Text("Delegated").tag("delegated")
                Text("Strict").tag("strict")
            }
            .pickerStyle(.segmented)
            Stepper("Daily budget: \(model.config.dispatchDailyBudgetMinutes) min", value: Binding(
                get: { model.config.dispatchDailyBudgetMinutes },
                set: { model.config.dispatchDailyBudgetMinutes = max(0, $0); reload() }
            ), step: 15)
            Text("Delegated lets agents start headless work within tiers and budget. Strict only runs human-created requests.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private var tasksSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader("OPEN TASKS")

            ForEach(handoff?.tasks ?? []) { task in
                HStack(alignment: .top, spacing: 6) {
                    Toggle("", isOn: Binding(
                        get: { task.done },
                        set: { model.setTask(task, done: $0, in: projectPath); reload() }
                    ))
                    .labelsHidden()
                    .toggleStyle(.checkbox)

                    VStack(alignment: .leading, spacing: 1) {
                        if task.text.hasPrefix("[req-") {
                            Text("REQUEST").font(.system(size: 9, weight: .semibold)).foregroundStyle(.teal)
                        }
                        Text(task.text)
                            .font(.system(size: 12))
                            .strikethrough(task.done)
                            .foregroundStyle(task.done ? .secondary : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let by = task.addedBy {
                            Text("from \(by)")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.tertiary)
                        }
                        // Only while it is open: a finished task's claim died
                        // with the work, and saying otherwise would be a lie
                        // you cannot click away.
                        if !task.done, let claim = claimed[task.id] {
                            Text(claim.annotation())
                                .font(.system(size: 9.5))
                                .foregroundStyle(.orange)
                        }
                    }
                    Spacer(minLength: 4)
                }
            }

            HStack(spacing: 6) {
                TextField("Something left to do…", text: $newTask)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5))
                    .onSubmit(addTask)
                Button("Add", action: addTask)
                    .controlSize(.small)
                    .disabled(newTask.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if handoff != nil, !ProjectRegistry.exists(for: projectPath) {
                Button("Set up the handoff file") {
                    model.initializeProject(projectPath)
                    reload()
                }
                .controlSize(.small)
                .padding(.top, 2)
            }
        }
    }

    private var commitsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader("LAST COMMITS")

            if let commits = handoff?.commits, !commits.isEmpty {
                ForEach(commits) { commit in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(commit.subject)
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(commit.shortSHA) · \(HandoffMarkdown.dayFormatter.string(from: commit.date))")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
            } else {
                Text("No commits — this folder is not a git repository.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func addTask() {
        let text = newTask.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        model.addTask(text, to: projectPath)
        newTask = ""
        reload()
    }

    private func reload() {
        handoff = model.handoff(for: projectPath)
        claimed = model.claims(for: projectPath)
    }
}

@MainActor
struct SectionHeader: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
    }
}
#endif
