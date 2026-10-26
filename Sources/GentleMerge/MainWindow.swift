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
            // No fixed point sizes in here: a sidebar's text follows the size
            // people pick in General settings (`sidebars.md` › Desktop).
            Section("Running now") {
                if model.liveActivities.isEmpty {
                    Text("No agent sessions")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.liveActivities) { activity in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(activity.state.tint)
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(activity.provider.displayName)
                            Text("\(activity.projectName) · \(activity.stateLabel)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    // The project it works in, and nothing else: a row whose
                    // session has no project has nowhere to navigate, and the
                    // old `?? ""` tagged it as an empty project that sat in the
                    // same selection space as the real ones — clickable, and
                    // resolving to nothing (audit 2026-10-11).
                    .tag(activity.projectPath)
                }
            }

            Section("Projects") {
                ForEach(model.projects) { summary in
                    Label(summary.name, systemImage: "folder")
                        .tag(summary.path)
                }
            }
        }
        .listStyle(.sidebar)
    }
}

@MainActor
private struct EmptyPane: View {
    var body: some View {
        ContentUnavailableView {
            Label("Nothing running yet", systemImage: "antenna.radiowaves.left.and.right")
        } description: {
            Text("Start Claude Code or Codex in a project and it shows up here, "
                + "along with everything it tells the other agents.")
        }
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

    /// Whether the project has a handoff file, resolved once per refresh rather
    /// than in the body: `ProjectRegistry.exists` canonicalises a path, which
    /// spawns git, and the body re-renders on every 3-second drain tick
    /// (audit 2026-10-11).
    @State private var handoffExists = false
    /// Merged in at render time, by task id. Never part of the handoff file.
    @State private var claimed: [String: TaskClaim] = [:]
    @State private var newTask = ""
    @State private var requestError: String?
    /// Read with the task board on every refresh tick, so the section can
    /// leave the layout entirely while there is nothing open.
    @State private var openRequests: [AgentRequest] = []

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

    private var openTaskCount: Int { (handoff?.tasks ?? []).filter { !$0.done }.count }

    var body: some View {
        ScrollView {
            // The project's name is the window title and its path the
            // subtitle, so the pane opens on the agents instead of on a second
            // copy of the title. Headless dispatch moved to Settings: it is one
            // switch for every project, and sitting inside each one said
            // otherwise.
            VStack(alignment: .leading, spacing: 26) {
                agentsSection
                messagesSection
                if !openRequests.isEmpty || requestError != nil {
                    requestsSection
                }
                HStack(alignment: .top, spacing: 28) {
                    tasksSection.frame(maxWidth: .infinity, alignment: .leading)
                    commitsSection.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
        // The model writes `lastMessage` from ~30 places and nothing read it:
        // add a task, deny a request, kick off a headless run and the window
        // said nothing either way — including when the write had failed and the
        // answer was the one thing worth seeing (audit 2026-10-08).
        .safeAreaInset(edge: .bottom) {
            if let message = model.lastMessage, !message.isEmpty {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                    .background(.bar)
            }
        }
        .navigationTitle(projectName)
        .navigationSubtitle(NSString(string: projectPath).abbreviatingWithTildeInPath)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    // The newest session in this project, so the diff is since
                    // *its* baseline. Passing no session fell back to HEAD, and
                    // a Review of work already committed then said "nothing
                    // since HEAD" — the button appeared to do nothing
                    // (audit 2026-10-11).
                    let session = model.mostRecentSession(in: projectPath)
                    model.startReview(projectPath: projectPath, sessionID: session?.id)
                    showReview = true
                } label: {
                    Label("Review", systemImage: "checkmark.shield")
                }
                .help(reviewHelp)

                Button { showSnapshots = true } label: {
                    Label("Restore Points", systemImage: "clock.arrow.circlepath")
                }
                .help("Snapshots of this project you can write back")

                Button {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: projectPath)
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .help("Show this project in Finder")
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
        // Tasks and claims were read once, in `reload`, and never again: what
        // another agent added or ticked did not appear in the window until the
        // pane was torn down and rebuilt (audit 2026-10-11). The drain already
        // ticks every 3 seconds for the bus, so this piggybacks on it and reads
        // the cheap local files — `handoffWithoutCommits` skips the `git log`.
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            refreshShared()
        }
    }

    /// Keep the task board, the claim list and the open requests current
    /// without a `git log`.
    private func refreshShared() {
        handoff = model.handoffWithoutCommits(for: projectPath)
        claimed = model.claims(for: projectPath)
        handoffExists = ProjectRegistry.exists(for: projectPath)
        openRequests = readOpenRequests()
    }

    private func readOpenRequests() -> [AgentRequest] {
        Requests(paths: model.paths).all()
            .filter { $0.projectPath == projectPath && $0.isOpenInTheWindow }
    }

    /// What the Review button will review, said out loud in its tooltip: the
    /// baseline it uses is the newest session's, and with no session there is
    /// nothing but HEAD to diff against.
    private var reviewHelp: String {
        guard let session = model.mostRecentSession(in: projectPath) else {
            return "Diff, build and tests for what the agents did here — no session has started here yet, so the diff is against HEAD"
        }
        return "Diff, build and tests since \(session.provider.displayName) started at "
            + session.startedAt.formatted()
    }

    // MARK: Agents

    private var agentsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Who is on this", detail: agents.isEmpty ? nil : "\(agents.count) running")

            if agents.isEmpty {
                Text("No session running here right now.")
                    .foregroundStyle(.secondary)
            }

            // One ledger scan per render, not one per session: summaries() is
            // memoized on the ledger's size+mtime, so this stays free while
            // the file does not move.
            let costs = Stats.summaries(paths: model.paths).bySession
            ForEach(agents) { activity in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    // The provider's own colour, the same one its notes use
                    // below, so a session and what it said read as one thing.
                    Image(systemName: activity.provider.symbolName)
                        .fontWeight(.semibold)
                        .foregroundStyle(Palette.tint(for: activity.provider))
                        .frame(width: 18)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text(activity.provider.displayName)
                                .font(.headline)
                            StateBadge(state: activity.state, label: activity.stateLabel)
                            Spacer(minLength: 8)
                            Text(RelativeTime.short(from: activity.updatedAt))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }

                        if let task = activity.currentTask {
                            Text("“\(task)”")
                                .fixedSize(horizontal: false, vertical: true)
                        } else if let event = activity.lastEvent {
                            Text(event)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        // What this session has cost so far. Tokens are chars/4
                        // off the ledger, always said as an estimate.
                        if let cost = costs[activity.id], cost.turns > 0 {
                            Text("\(cost.turns) briefings · ≈\(cost.estTokens) tokens (estimate)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: Messages

    /// A kind earns a chip only when it is not the default one: a column of
    /// grey UPDATE badges would say nothing and cost every line its width.
    /// Resolved notes never reach here — they are folded out of the list.
    /// Only urgent is coloured: purple and teal already mean Claude and Codex.
    @ViewBuilder
    private func kindChip(for message: AgentMessage) -> some View {
        if message.effectiveKind != .update {
            let tint = message.effectiveKind == .urgent ? Color.red : Color.secondary
            Text(message.effectiveKind.rawValue.uppercased())
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .foregroundStyle(tint)
                .background(tint.opacity(0.14), in: Capsule())
        }
    }

    private var messagesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("What they have told each other")

            if conversation.isEmpty {
                Text("Nothing yet. Anything written here is handed to every agent"
                    + " on its next turn — and they can write back with `gentlemerge say`.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // A transcript: handles in monospace, the way the agents sign
            // their notes in a terminal.
            ForEach(conversation) { message in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(message.from)
                        .font(.system(.callout, design: .monospaced).weight(.semibold))
                        .foregroundStyle(Palette.tint(forAuthor: message.from))
                        .frame(width: 60, alignment: .leading)
                    kindChip(for: message)
                    Text(message.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    Text(RelativeTime.short(from: message.at))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            HStack(spacing: 8) {
                TextField("Tell every agent something…", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { send() }
                // A split button: Send goes to every agent, the arrow keeps it
                // to this project (`pull-down-buttons.md`).
                Menu("Send") {
                    Button("Send Only to This Project") { send(scoped: true) }
                } primaryAction: {
                    send()
                }
                .fixedSize()
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.top, 4)
        }
    }

    private func send(scoped: Bool = false) {
        let text = draft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        model.say(text, project: scoped ? projectPath : nil)
        draft = ""
    }

    /// Shown only while there is a request open here: an empty heading is a
    /// question with nothing under it.
    private var requestsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Requests", detail: openRequests.isEmpty ? nil : "\(openRequests.count) open")
            ForEach(openRequests) { request in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(request.id) · \(request.title)")
                        Text("\(request.from) → \(request.resolvedTo ?? request.to) · \(request.state.rawValue)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let logURL = model.requestLogURL(for: request) {
                        Button("Open Log") { NSWorkspace.shared.open(logURL) }
                            .buttonStyle(.link)
                            .help(logURL.path)
                    }
                    if request.from == "you" && request.state.isTerminal {
                        Button("Acknowledge") { updateRequest(request, action: "ack") }
                    }
                    if request.state == .assigned || request.state == .queued {
                        // The model's own path, not `RequestActions` with a
                        // literal "you": a human is not the assignee, and
                        // `transition` only lets the two parties to the
                        // contract move it — this button was doomed to fail
                        // with "you is not allowed to do that"
                        // (audit 2026-10-08).
                        Button("Reject") { model.deny(request.id); reload() }
                    }
                }
            }
            if let requestError {
                Label(requestError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    /// `ack` only: the one transition a human genuinely owns, because it is the
    /// *requester* acknowledging a result (`Requests.transition` requires
    /// `actor == from`, and the button is only shown when `from == "you"`).
    /// Reject used to come through here with a literal `by: "you"` and could
    /// never succeed — it now goes through `model.deny`, which acts as the
    /// assignee on purpose (audit 2026-10-08).
    private func updateRequest(_ request: AgentRequest, action: String) {
        do {
            _ = try RequestActions.perform(action: action, id: request.id, by: "you", result: nil, paths: model.paths)
            requestError = nil
            reload()
        } catch { requestError = "\(error)" }
    }

    // MARK: Tasks and commits

    private var tasksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Open tasks", detail: openTaskCount == 0 ? nil : "\(openTaskCount)")

            ForEach(handoff?.tasks ?? []) { task in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { task.done },
                        set: { model.setTask(task, done: $0, in: projectPath); reload() }
                    ))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .accessibilityLabel(task.text)

                    VStack(alignment: .leading, spacing: 2) {
                        if task.text.hasPrefix("[req-") {
                            Text("REQUEST")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        Text(task.text)
                            .strikethrough(task.done)
                            .foregroundStyle(task.done ? .secondary : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let by = task.addedBy {
                            Text("from \(by)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        // Only while it is open: a finished task's claim died
                        // with the work, and saying otherwise would be a lie
                        // you cannot click away. Not orange: orange means an
                        // agent is waiting on you, a claim that one is on it.
                        if !task.done, let claim = claimed[task.id] {
                            Label(claim.annotation(), systemImage: "hand.raised.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 4)
                }
            }

            HStack(spacing: 8) {
                TextField("Something left to do…", text: $newTask)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTask)
                Button("Add", action: addTask)
                    .disabled(newTask.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.top, 2)

            if handoff != nil, !handoffExists {
                Button("Set Up the Handoff File") {
                    model.initializeProject(projectPath)
                    reload()
                }
                .padding(.top, 2)
            }
        }
    }

    private var commitsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Last commits")

            if let commits = handoff?.commits, !commits.isEmpty {
                ForEach(commits) { commit in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(commit.subject)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(commit.shortSHA) · \(HandoffMarkdown.dayFormatter.string(from: commit.date))")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("No commits — this folder is not a git repository.")
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
        handoffExists = ProjectRegistry.exists(for: projectPath)
        openRequests = readOpenRequests()
    }
}

/// A section's title, with an optional count or summary beside it. Headline
/// weight in sentence case: the old tiny grey capitals were 10 pt at 1.9:1,
/// and read as decoration rather than as the way into a section.
@MainActor
struct SectionHeader: View {
    let text: String
    var detail: String?

    init(_ text: String, detail: String? = nil) {
        self.text = text
        self.detail = detail
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(text)
                .font(.headline)
            if let detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// An agent's state as a tinted capsule. The word is always there, so the
/// colour is never the only thing saying it.
@MainActor
struct StateBadge: View {
    let state: AgentActivity.State
    let label: String

    var body: some View {
        Text(label)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .foregroundStyle(state.tint)
            .background(state.tint.opacity(0.15), in: Capsule())
    }
}
#endif
