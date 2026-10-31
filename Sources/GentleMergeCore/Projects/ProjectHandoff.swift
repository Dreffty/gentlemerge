import Foundation

public struct CommitRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String { sha }
    public var sha: String
    public var date: Date
    public var subject: String
    public var author: String?
    /// The paths this commit touched, repository-relative.
    ///
    /// This is the half of a commit that answers the only question worth asking
    /// before you write your own: *did somebody already change the file I am
    /// about to change?* A subject line cannot answer it, so the list is kept
    /// even though it makes the handoff file longer.
    public var files: [String]

    public init(
        sha: String,
        date: Date,
        subject: String,
        author: String? = nil,
        files: [String] = []
    ) {
        self.sha = sha
        self.date = date
        self.subject = subject
        self.author = author
        self.files = files
    }

    public var shortSHA: String { String(sha.prefix(7)) }

    // Tolerant, like everything else that has to read a file written by an
    // older binary: a commit recorded before files existed simply has none.
    enum CodingKeys: String, CodingKey {
        case sha, date, subject, author, files
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sha = try container.decode(String.self, forKey: .sha)
        date = (try? container.decode(Date.self, forKey: .date)) ?? Date()
        subject = (try? container.decode(String.self, forKey: .subject)) ?? ""
        author = try? container.decode(String.self, forKey: .author)
        files = (try? container.decode([String].self, forKey: .files)) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sha, forKey: .sha)
        try container.encode(date, forKey: .date)
        try container.encode(subject, forKey: .subject)
        try container.encodeIfPresent(author, forKey: .author)
        if !files.isEmpty { try container.encode(files, forKey: .files) }
    }
}

/// One point of a task, written down *before* it is worked on.
///
/// That is the whole trick: a ten-point task registered up front leaves the
/// six that got done and the four that did not on disk, so a session that runs
/// out of context or dies on a 529 still hands over a truthful record.
public struct TaskStep: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var text: String
    public var done: Bool

    public init(id: String? = nil, text: String, done: Bool = false) {
        // Same identity rule as a task: derived from the text, so the app, the
        // CLI and the next launch all agree on which point this is. One line,
        // for the same reason as TaskItem: a newline here becomes a flush-left
        // checkbox on the way back in and gets promoted to its own task.
        let clean = HandoffMarkdown.oneLine(text)
        self.id = id ?? HandoffMarkdown.identifier(for: clean)
        self.text = clean
        self.done = done
    }
}

public struct TaskItem: Codable, Sendable, Identifiable {
    public var id: String
    public var text: String
    /// The points this task breaks down into. Empty is the normal case, and
    /// every old handoff file is exactly that.
    public var steps: [TaskStep]
    public var addedAt: Date?
    /// `claude`, `codex`, `you`… — knowing who left it is half the context.
    public var addedBy: String?

    /// Only consulted for a task with no steps; see `done`.
    private var completed: Bool

    /// Derived from the steps whenever there are any.
    ///
    /// Two sources of truth for "is this finished" is the confusing option: you
    /// end up with `- [x]` sitting above four unticked points and nobody knows
    /// which one lied. A task with steps is finished exactly when its steps are.
    public var done: Bool {
        get { steps.isEmpty ? completed : steps.allSatisfy(\.done) }
        set {
            let wasDone = done
            completed = newValue
            // Ticking the parent off ticks what is left under it — but only
            // when that actually changes the answer, so "undone" on a task
            // sitting at 6/10 cannot wipe the six that were done.
            guard newValue != wasDone else { return }
            for index in steps.indices { steps[index].done = newValue }
        }
    }

    public var doneStepCount: Int { steps.count(where: \.done) }
    public var openSteps: [TaskStep] { steps.filter { !$0.done } }
    /// `6/10`, or nil when there is nothing to count.
    public var progressLabel: String? {
        steps.isEmpty ? nil : "\(doneStepCount)/\(steps.count)"
    }
    /// Started and abandoned: the shape of a session that ran out of road.
    public var isPartlyDone: Bool { !steps.isEmpty && doneStepCount > 0 && !done }

    public init(
        id: String? = nil,
        text: String,
        done: Bool = false,
        steps: [TaskStep] = [],
        addedAt: Date? = Date(),
        addedBy: String? = nil
    ) {
        // Identity comes from the text, not from a UUID: this file is edited by
        // agents and by hand, and a task read back must be the same task.
        // One line first: an interior newline renders as a second line that
        // parses as a different task — and loses half the words on save.
        let clean = HandoffMarkdown.oneLine(text)
        self.id = id ?? HandoffMarkdown.identifier(for: clean)
        self.text = clean
        self.steps = steps
        self.completed = done
        self.addedAt = addedAt
        self.addedBy = addedBy
    }

    // Tolerant like the rest of this file: a handoff written before steps
    // existed has no `steps` key, and that is not an error.
    enum CodingKeys: String, CodingKey {
        case id, text, done, steps, addedAt, addedBy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Same normalization as the memberwise init: decoded text can carry
        // whatever an older binary wrote, and one line is the invariant.
        text = HandoffMarkdown.oneLine((try? container.decode(String.self, forKey: .text)) ?? "")
        id = (try? container.decode(String.self, forKey: .id))
            ?? HandoffMarkdown.identifier(for: text)
        completed = (try? container.decode(Bool.self, forKey: .done)) ?? false
        steps = ((try? container.decode([TaskStep].self, forKey: .steps)) ?? []).map { step in
            let clean = HandoffMarkdown.oneLine(step.text)
            return clean == step.text ? step : TaskStep(text: clean, done: step.done)
        }
        addedAt = try? container.decode(Date.self, forKey: .addedAt)
        addedBy = try? container.decode(String.self, forKey: .addedBy)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(text, forKey: .text)
        // The derived answer, so anything reading only `done` still reads true.
        try container.encode(done, forKey: .done)
        if !steps.isEmpty { try container.encode(steps, forKey: .steps) }
        try container.encodeIfPresent(addedAt, forKey: .addedAt)
        try container.encodeIfPresent(addedBy, forKey: .addedBy)
    }
}

extension TaskItem: Equatable {
    /// Compares what the file says, not the backing flag: a task with steps is
    /// described entirely by its steps, whatever `completed` happens to hold.
    public static func == (lhs: TaskItem, rhs: TaskItem) -> Bool {
        lhs.id == rhs.id
            && lhs.text == rhs.text
            && lhs.done == rhs.done
            && lhs.steps == rhs.steps
            && lhs.addedAt == rhs.addedAt
            && lhs.addedBy == rhs.addedBy
    }
}

/// The state of a project between sessions: what was just done, what is left,
/// and anything worth saying to whoever picks it up next — human or model.
///
/// It lives as markdown inside the project so every agent can read it with the
/// tools it already has, and so it travels with the repository.
public struct ProjectHandoff: Codable, Sendable, Equatable {
    public static let fileName = "HANDOFF.md"
    public static let directoryName = ".gentlemerge"

    public var projectPath: String
    public var projectName: String
    /// Regenerated from `git log` — never hand-edited, always current.
    public var commits: [CommitRecord]
    /// How the project is put together. Generated, cached here, and rebuilt
    /// when the commit it was sealed with is no longer HEAD.
    public var map: ProjectMap?
    public var tasks: [TaskItem]
    public var notes: String
    /// What a person wrote between the title and the first `##` section. Kept
    /// verbatim, after the generated introduction: it used to be dropped on the
    /// next save, together with any `- [ ]` written there.
    public var preamble: String
    /// Sections someone else added, kept verbatim so we never eat their work.
    public var extraSections: [(heading: String, body: String)]
    public var updatedAt: Date

    public init(
        projectPath: String,
        projectName: String? = nil,
        commits: [CommitRecord] = [],
        map: ProjectMap? = nil,
        tasks: [TaskItem] = [],
        notes: String = "",
        preamble: String = "",
        extraSections: [(heading: String, body: String)] = [],
        updatedAt: Date = Date()
    ) {
        self.projectPath = projectPath
        self.projectName = projectName ?? URL(fileURLWithPath: projectPath).lastPathComponent
        self.commits = commits
        self.map = map
        self.tasks = tasks
        self.notes = notes
        self.preamble = preamble
        self.extraSections = extraSections
        self.updatedAt = updatedAt
    }

    public var openTasks: [TaskItem] { tasks.filter { !$0.done } }
    public var doneTasks: [TaskItem] { tasks.filter(\.done) }

    public static func fileURL(for projectPath: String) -> URL {
        URL(fileURLWithPath: projectPath)
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    // Codable ignores the tuple array; it is only meaningful in the file itself.
    enum CodingKeys: String, CodingKey {
        case projectPath, projectName, commits, map, tasks, notes, preamble, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectPath = try container.decode(String.self, forKey: .projectPath)
        projectName = try container.decode(String.self, forKey: .projectName)
        commits = (try? container.decode([CommitRecord].self, forKey: .commits)) ?? []
        map = try? container.decode(ProjectMap.self, forKey: .map)
        tasks = (try? container.decode([TaskItem].self, forKey: .tasks)) ?? []
        notes = (try? container.decode(String.self, forKey: .notes)) ?? ""
        preamble = (try? container.decodeIfPresent(String.self, forKey: .preamble)) ?? ""
        updatedAt = (try? container.decode(Date.self, forKey: .updatedAt)) ?? Date()
        extraSections = []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(projectPath, forKey: .projectPath)
        try container.encode(projectName, forKey: .projectName)
        try container.encode(commits, forKey: .commits)
        try container.encodeIfPresent(map, forKey: .map)
        try container.encode(tasks, forKey: .tasks)
        try container.encode(notes, forKey: .notes)
        try container.encode(preamble, forKey: .preamble)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    public static func == (lhs: ProjectHandoff, rhs: ProjectHandoff) -> Bool {
        lhs.projectPath == rhs.projectPath
            && lhs.commits == rhs.commits
            && lhs.map == rhs.map
            && lhs.tasks == rhs.tasks
            && lhs.notes == rhs.notes
            && lhs.preamble == rhs.preamble
            && lhs.extraSections.map(\.heading) == rhs.extraSections.map(\.heading)
            && lhs.extraSections.map(\.body) == rhs.extraSections.map(\.body)
    }
}

// MARK: - Markdown

/// Reads and writes the handoff file. Deliberately forgiving: an agent editing
/// this by hand should never be able to corrupt it, only add to it.
public enum HandoffMarkdown {
    static let commitsHeading = "Recent commits"
    static let mapHeading = "Project map"
    static let tasksHeading = "Open tasks"
    static let notesHeading = "Notes"
    /// What an empty Notes section says. Matched exactly when reading it back.
    static let notesPlaceholder = "_Nothing yet._"

    /// Peer text enters the file as data, never as structure. Only flush-left
    /// `#` lines split sections on the way back in, so only those are
    /// escaped: `\## Ownership` inside a task or a note renders as literal
    /// text and can never become a section that `Ownership.from` would read
    /// as a zone grant. `unescape` restores the text on parse, so the round
    /// trip is lossless. (A peer that hand-edits the file outside these
    /// fields is the human's own editor, not this channel.)
    ///
    /// Only `##` and deeper. A single `#` is not a section here (the parser takes
    /// one only as the file's own title, before the first `##`), so it needs no
    /// protection — and escaping it rewrote ordinary text: a `# install deps`
    /// comment in a shell block in the notes came back as `\# install deps`.
    public static func escape(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let fenced = fencedLines(lines)
        return lines.enumerated().map { index, line -> String in
            // Inside a code block a `##` is code, not structure: the parser does
            // not read headings there, and a bash comment must not come back
            // from a save with a backslash in it.
            !fenced[index] && line.hasPrefix("##") ? "\\" + line : line
        }.joined(separator: "\n")
    }

    public static func unescape(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let fenced = fencedLines(lines)
        return lines.enumerated().map { index, line -> String in
            !fenced[index] && line.hasPrefix("\\#") ? String(line.dropFirst()) : line
        }.joined(separator: "\n")
            // Also undoes `protectMetadata`: rendered task text carries its
            // literal " · " as " ·<nbsp>", which the metadata strip never
            // matches. Restoring here keeps every unescape path symmetric.
            .replacingOccurrences(of: " ·\u{00A0}", with: " · ")
    }

    /// Which lines are part of a fenced code block (the fence lines included).
    ///
    /// A fence that never closes marks nothing. CommonMark would let it run to the
    /// end of the file, which here would swallow every section after it — the
    /// Ownership zones among them — because of one stray backtick fence.
    static func fencedLines(_ lines: [String]) -> [Bool] {
        var mask = [Bool](repeating: false, count: lines.count)
        var open: (index: Int, marker: Character, length: Int)?
        for (index, line) in lines.enumerated() {
            guard let fence = fenceMarker(line) else { continue }
            if let started = open {
                if fence.marker == started.marker, fence.length >= started.length, fence.rest.isEmpty {
                    for covered in started.index...index { mask[covered] = true }
                    open = nil
                }
            } else {
                open = (index, fence.marker, fence.length)
            }
        }
        return mask
    }

    /// A line that opens or closes a fence: up to three spaces, then three or
    /// more backticks or tildes. `rest` is what follows the run, trimmed.
    private static func fenceMarker(_ line: String) -> (marker: Character, length: Int, rest: String)? {
        let trimmed = line.drop { $0 == " " }
        guard line.count - trimmed.count <= 3, let marker = trimmed.first, marker == "`" || marker == "~" else {
            return nil
        }
        let run = trimmed.prefix { $0 == marker }
        guard run.count >= 3 else { return nil }
        let rest = String(trimmed.dropFirst(run.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        if marker == "`", rest.contains("`") { return nil }
        return (marker, run.count, rest)
    }

    /// The fence line that closes a block left open at the end of `text`, or
    /// nil. Notes are followed by other sections in the file, so a dangling
    /// fence would pair with the next one down and swallow the headings between.
    static func closingFence(for text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var open: (marker: Character, length: Int)?
        for line in lines {
            guard let fence = fenceMarker(line) else { continue }
            if let started = open {
                if fence.marker == started.marker, fence.length >= started.length, fence.rest.isEmpty { open = nil }
            } else {
                open = (fence.marker, fence.length)
            }
        }
        return open.map { String(repeating: $0.marker, count: $0.length) }
    }

    /// Task and step text is one line. The grammar is line-based, so an
    /// interior newline renders as a second line that parses back as a
    /// different task — or a remainder the tasks heading discards — and the
    /// next save permanently deletes the lost half (audit Tier 2 #11).
    static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A literal " · " inside task text, written so the metadata parser cannot
    /// eat it: `task(from:)` strips only plain-space separators, and a task
    /// genuinely named "… · by hand" round-trips as its own words (the real
    /// ` · by claude` still strips, because renderTask appends it unmodified).
    static func protectMetadata(_ text: String) -> String {
        text.replacingOccurrences(of: " · ", with: " ·\u{00A0}")
    }

    public static func render(_ handoff: ProjectHandoff) -> String {
        var lines: [String] = [
            "# \(handoff.projectName) — agent handoff",
            "",
            "_Shared state for every agent working on this project. Read it at the start of a"
                + " session and update the tasks when you finish something. Write `- [ ] …` anywhere"
                + " in this file and it will be tidied into the list below. The commit list is"
                + " regenerated by GentleMerge; anything else here is yours._",
            "",
        ]
        if !handoff.preamble.isEmpty { lines += [escape(handoff.preamble), ""] }

        if let map = handoff.map, !map.isEmpty {
            lines += ["## \(mapHeading)", "", seal(for: map)] + mapLines(map) + [""]
        }

        lines += ["## \(commitsHeading)", "", commitsNote, ""]

        if handoff.commits.isEmpty {
            lines.append("_No commits yet._")
        } else {
            for commit in handoff.commits {
                lines += commitLines(commit)
            }
        }

        lines += ["", "## \(tasksHeading)", ""]
        if handoff.tasks.isEmpty {
            lines.append("_Nothing tracked yet._")
        } else {
            for task in handoff.tasks {
                lines += renderTaskLines(task)
            }
        }

        lines += ["", "## \(notesHeading)", ""]
        if handoff.notes.isEmpty {
            lines.append(notesPlaceholder)
        } else {
            lines.append(escape(handoff.notes))
            if let closing = closingFence(for: handoff.notes) { lines.append(closing) }
        }

        for section in handoff.extraSections {
            lines += ["", "## \(section.heading)", "", section.body]
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }

    static func renderTask(_ task: TaskItem) -> String {
        var line = "- [\(task.done ? "x" : " ")] \(escape(protectMetadata(oneLine(task.text))))"
        // The counter is written out so the file reads right on its own, in a
        // pull request or in someone else's editor. It is recomputed on the way
        // back in, so a stale one can never outvote the boxes below it.
        if let progress = task.progressLabel {
            line += " · \(progress)"
        }
        if let addedAt = task.addedAt {
            line += " · added \(dayFormatter.string(from: addedAt))"
        }
        if let addedBy = task.addedBy, !addedBy.isEmpty {
            line += " · by \(addedBy)"
        }
        return line
    }

    /// A task and its points. Indentation is the only thing that says a
    /// checkbox belongs to the line above it — no ids, no anchors, nothing an
    /// agent editing by hand has to get right.
    static func renderTaskLines(_ task: TaskItem) -> [String] {
        [renderTask(task)] + task.steps.map { step in
            "\(stepIndent)- [\(step.done ? "x" : " ")] \(escape(protectMetadata(oneLine(step.text))))"
        }
    }

    static let stepIndent = "  "

    public static func parse(_ text: String, projectPath: String) -> ProjectHandoff {
        var handoff = ProjectHandoff(projectPath: projectPath)
        var currentHeading: String?
        var buffer: [String] = []
        var extras: [(String, String)] = []
        // The `# title` line is the file's first line, before any `##` section. A `# `
        // line further down is somebody's text — a shell comment in a code block in the
        // notes, a heading in a pasted document. It used to be taken for a second title:
        // it cut the section off (everything after it was dropped on the next save) and
        // renamed the project after it.
        var seenSection = false
        var seenTitle = false

        func flush() {
            let body = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            defer { buffer.removeAll() }
            guard let heading = currentHeading else {
                // Before the first section: what a person wrote under the title
                // (or above it). It used to be dropped here, and a `- [ ]` among
                // it with it.
                let (tasks, remainder) = extractTasks(from: body)
                handoff.tasks += tasks
                handoff.preamble = withoutIntroduction(remainder)
                return
            }

            switch heading {
            case commitsHeading:
                handoff.commits = parseCommits(body)
            case mapHeading:
                // First class rather than an extra section: an extra is kept
                // verbatim, and a map nobody can rewrite would be frozen at the
                // shape the project had the day it was first generated.
                let (tasks, remainder) = extractTasks(from: body)
                handoff.tasks += tasks
                handoff.map = parseMap(remainder)
            case tasksHeading:
                handoff.tasks += extractTasks(from: body).tasks
            case notesHeading:
                let (tasks, remainder) = extractTasks(from: body)
                handoff.tasks += tasks
                // Exactly the placeholder we write. "Starts and ends with an underscore" also
                // matched a real note in italics (`_Never deploy on Fridays._`), which was
                // erased on the next save.
                handoff.notes = remainder == notesPlaceholder ? "" : unescape(remainder)
            default:
                // An agent told to "add a task" will append a checkbox wherever
                // its cursor happens to be. Collect those rather than lose them,
                // and hand the rest of the section back untouched.
                let (tasks, remainder) = extractTasks(from: body)
                handoff.tasks += tasks
                if !remainder.isEmpty { extras.append((heading, remainder)) }
            }
        }

        let lines = text.components(separatedBy: "\n")
        let fenced = fencedLines(lines)
        for (index, line) in lines.enumerated() {
            // A `#` or `##` inside a code block is code, not a title or a section.
            if !fenced[index] {
                if line.hasPrefix("# "), !seenSection, !seenTitle {
                    // Only the first one is the title; a later `# ` before the
                    // first section is somebody's text and stays in the preamble.
                    seenTitle = true
                    let title = String(line.dropFirst(2))
                    if let name = title.components(separatedBy: " — ").first, !name.isEmpty {
                        handoff.projectName = name
                    }
                    continue
                }
                if line.hasPrefix("## ") {
                    seenSection = true
                    flush()
                    currentHeading = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    continue
                }
            }
            buffer.append(line)
        }
        flush()

        handoff.extraSections = extras
        return handoff
    }

    /// The introduction `render` writes under the title, taken back out so only
    /// what a person added is kept as the preamble.
    static func withoutIntroduction(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .filter { !$0.hasPrefix(introductionPrefix) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let introductionPrefix = "_Shared state for every agent working on this project."

    static func extractTasks(from body: String) -> (tasks: [TaskItem], remainder: String) {
        var tasks: [TaskItem] = []
        var kept: [String] = []

        let lines = body.components(separatedBy: "\n")
        let fenced = fencedLines(lines)
        for (index, line) in lines.enumerated() {
            // A checkbox inside a code block is an example being shown, not a task.
            guard !fenced[index], let checkbox = parseCheckbox(line) else {
                kept.append(line)
                continue
            }

            // An indented checkbox is a point of the task above it; one that is
            // flush left starts a new task. That is the entire grammar, and it
            // is the one thing a model gets right without being told.
            if checkbox.indented, !tasks.isEmpty {
                tasks[tasks.count - 1].steps.append(
                    TaskStep(text: unescape(checkbox.text), done: checkbox.done)
                )
                continue
            }

            // Indented with nothing above it: a fragment somebody pasted. It is
            // still a checkbox somebody wrote, so it becomes a task of its own
            // rather than something we quietly eat.
            let parsed = task(from: checkbox)
            if parsed.text.isEmpty {
                kept.append(line)
            } else {
                tasks.append(parsed)
            }
        }

        return (tasks, kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - The map

    /// Stolen from a graph report that had the right instinct: say what you
    /// were built from and how to check, so nobody has to trust a generated
    /// file blind.
    static func seal(for map: ProjectMap) -> String {
        let day = dayFormatter.string(from: map.builtAt)
        guard let short = map.shortCommit else {
            return "_Generated from the files on disk on \(day). No git repository here, so there is no"
                + " commit to pin it to._"
        }
        return "_Generated from the files on disk at commit `\(short)` on \(day) — run"
            + " `git rev-parse HEAD` to see whether it has moved on._"
    }

    static func mapLines(_ map: ProjectMap) -> [String] {
        var lines: [String] = [""]
        if !map.stack.isEmpty { lines.append("- Stack: \(map.stack.joined(separator: " · "))") }
        if !map.commands.isEmpty {
            lines.append("- Build & test: \(map.commands.joined(separator: " · "))")
        }
        if map.fileCount > 0 { lines.append("- Shape: \(map.shapeSentence)") }
        if !map.hubs.isEmpty { lines.append("- Start here: \(map.hubs.joined(separator: ", "))") }
        return lines
    }

    static func parseMap(_ body: String) -> ProjectMap? {
        var map = ProjectMap()

        for rawLine in body.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("_") {
                map.commit = sealedCommit(in: line)
                if let date = sealedDate(in: line) { map.builtAt = date }
            } else if let rest = suffix(of: line, after: "- Stack: ") {
                map.stack = rest.components(separatedBy: " · ")
            } else if let rest = suffix(of: line, after: "- Build & test: ") {
                map.commands = rest.components(separatedBy: " · ")
            } else if let rest = suffix(of: line, after: "- Shape: ") {
                let parts = rest.components(separatedBy: " — ")
                map.fileCount = Int(parts[0].components(separatedBy: " ").first ?? "") ?? 0
                if parts.count > 1 { map.directories = parts[1].components(separatedBy: ", ") }
            } else if let rest = suffix(of: line, after: "- Start here: ") {
                map.hubs = rest.components(separatedBy: ", ")
            }
        }

        // Nothing recognisable: treat it as absent so the next session rebuilds
        // it, rather than carrying a corpse forward forever.
        return map.isEmpty ? nil : map
    }

    static func suffix(of line: String, after prefix: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        let rest = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }

    /// The first code span in the seal, when it looks like a revision. The
    /// second one is the `git rev-parse HEAD` we tell the reader to run.
    static func sealedCommit(in line: String) -> String? {
        let spans = line.components(separatedBy: "`")
        guard spans.count >= 3 else { return nil }
        let candidate = spans[1]
        let isHex = candidate.allSatisfy { $0.isHexDigit }
        return isHex && candidate.count >= 7 ? candidate : nil
    }

    static func sealedDate(in line: String) -> Date? {
        let punctuation = CharacterSet(charactersIn: "._`,;—-")
        for token in line.components(separatedBy: .whitespaces) {
            let cleaned = token.trimmingCharacters(in: punctuation)
            if let date = dayFormatter.date(from: cleaned) { return date }
        }
        return nil
    }

    // MARK: - Commits

    /// Said in the file and not only in the session briefing: the agent that
    /// opens `HANDOFF.md` a week from now is not the one that read the briefing,
    /// and this is the sentence that stops it overwriting somebody's work.
    static let commitsNote =
        "_Before you commit, look here for the files you are about to touch. If one of them is on"
        + " this list, read that commit before you write over it —"
        + " `gentlemerge precommit` does the comparison for you._"

    /// How many paths one commit spells out. A commit that touched forty files
    /// is a merge or a rename sweep, and forty lines of it would push the open
    /// tasks off the screen.
    static let filePreviewLimit = 10
    static let fileIndent = "  "

    static func commitLines(_ commit: CommitRecord) -> [String] {
        var header = "- `\(commit.shortSHA)` \(dayFormatter.string(from: commit.date))"
        if let author = commit.author, !author.isEmpty { header += " · \(author)" }
        header += " — \(commit.subject)"
        guard !commit.files.isEmpty else { return [header] }

        var shown = Array(commit.files.prefix(filePreviewLimit))
        if commit.files.count > filePreviewLimit {
            shown.append("+\(commit.files.count - filePreviewLimit) more")
        }
        return [header, fileIndent + shown.joined(separator: " · ")]
    }

    /// The section, read as commits with their files hanging under them.
    ///
    /// Line by line rather than `compactMap`, because a file list only means
    /// anything next to the commit above it.
    static func parseCommits(_ body: String) -> [CommitRecord] {
        var commits: [CommitRecord] = []

        for line in body.components(separatedBy: "\n") {
            if let commit = parseCommit(line) {
                commits.append(commit)
                continue
            }
            // Anything else that is not an indented list of paths under a
            // commit — the note at the top, a blank line — is not ours.
            guard !commits.isEmpty, line.hasPrefix(fileIndent) else { continue }
            let paths = line
                .trimmingCharacters(in: .whitespaces)
                .components(separatedBy: " · ")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !isTruncationMarker($0) }
            guard !paths.isEmpty else { continue }
            commits[commits.count - 1].files += paths
        }

        return commits
    }

    /// `+7 more` — written by us, and not a path anybody can open.
    static func isTruncationMarker(_ token: String) -> Bool {
        guard token.hasPrefix("+"), token.hasSuffix(" more") else { return false }
        let count = token.dropFirst().dropLast(5)
        return !count.isEmpty && count.allSatisfy(\.isNumber)
    }

    static func parseCommit(_ line: String) -> CommitRecord? {
        // - `a1b2c3d` 2026-08-14 · claude — subject
        guard line.hasPrefix("- `"), let closing = line.dropFirst(3).firstIndex(of: "`") else { return nil }
        let sha = String(line.dropFirst(3)[..<closing])
        let rest = String(line.dropFirst(3)[line.index(after: closing)...])
            .trimmingCharacters(in: .whitespaces)

        let parts = rest.components(separatedBy: " — ")
        guard parts.count >= 2 else { return nil }

        // The date alone in a file written before authors were recorded, and
        // `date · author` in one written since.
        let head = parts[0].components(separatedBy: " · ")
        let date = dayFormatter.date(from: head[0].trimmingCharacters(in: .whitespaces)) ?? Date()
        let author = head.count > 1 ? head[1].trimmingCharacters(in: .whitespaces) : ""

        return CommitRecord(
            sha: sha,
            date: date,
            subject: parts.dropFirst().joined(separator: " — "),
            author: author.isEmpty ? nil : author
        )
    }

    /// One checkbox line, before we decide whether it is a task or a point of
    /// the task above it.
    struct Checkbox {
        var indented: Bool
        var done: Bool
        var text: String
    }

    static func parseCheckbox(_ rawLine: String) -> Checkbox? {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        let markers = ["- [ ] ", "- [x] ", "- [X] ", "* [ ] ", "* [x] ", "* [X] "]
        guard let marker = markers.first(where: { line.hasPrefix($0) }) else { return nil }

        let text = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        return Checkbox(
            indented: rawLine.first == " " || rawLine.first == "\t",
            done: marker.lowercased().contains("[x]"),
            text: text
        )
    }

    static func task(from checkbox: Checkbox) -> TaskItem {
        // Strip `renderTask`'s metadata from the raw line, BEFORE unescape:
        // a literal " · " in the text was protected at render time (nbsp), so
        // only real metadata — plain-space separators — matches here.
        // Unescaping first would restore the separators and feed them straight
        // back to this parser, and the task's own words would be stolen again
        // (audit Tier 2 #11).
        var text = checkbox.text
        var addedAt: Date?
        var addedBy: String?

        // Metadata is a suffix we wrote; strip it back off so it never doubles.
        while let range = text.range(of: " · ", options: .backwards) {
            let suffix = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if suffix.hasPrefix("added "), let date = dayFormatter.date(from: String(suffix.dropFirst(6))) {
                addedAt = date
            } else if suffix.hasPrefix("by "), isLabel(String(suffix.dropFirst(3))) {
                // An author is a label: one word. "fix the parser · by design is wrong"
                // is a task with words in it, not a task by "design is wrong".
                addedBy = String(suffix.dropFirst(3))
            } else if isProgress(suffix) {
                // Dropped, not read: the boxes underneath are the truth, and a
                // counter someone edited by hand must never outvote them.
            } else {
                break
            }
            text = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        text = unescape(text)

        // Stable id from the text: the same task keeps its identity across edits
        // made in a file we do not control.
        return TaskItem(
            id: identifier(for: text),
            text: text,
            done: checkbox.done,
            addedAt: addedAt,
            addedBy: addedBy
        )
    }

    /// Whether `text` could be the label of an agent: what `Identity.safe` lets through.
    static func isLabel(_ text: String) -> Bool {
        !text.isEmpty && Identity.safe(text) == text
    }

    /// `6/10` and nothing else — a task actually called "Fix 3/4 of the specs"
    /// keeps its name.
    static func isProgress(_ suffix: String) -> Bool {
        let parts = suffix.components(separatedBy: "/")
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return false }
        return parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    static func parseTask(_ rawLine: String) -> TaskItem? {
        guard let checkbox = parseCheckbox(rawLine) else { return nil }
        let parsed = task(from: checkbox)
        return parsed.text.isEmpty ? nil : parsed
    }

    /// FNV-1a, not `hashValue`: Swift seeds its hasher per process, and this id
    /// has to mean the same thing to the app, the CLI and the next launch.
    static func identifier(for text: String) -> String {
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in normalized.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    public static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
