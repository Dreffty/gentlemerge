import XCTest
@testable import GentleMergeCore

/// The README's own setup, exercised end to end with real worktrees and the real
/// hook script.
///
/// The round-2 audit found four separate defects that were invisible to the unit
/// suite because nothing drove the documented layout: `say` and `task add`
/// identified the agent by the *repository root* (so every worktree signed as
/// the main checkout's label, or as "you", and one agent's `say --done` buried
/// another's blockers); `session-context` identified the reader by *provider*
/// (so `say --to <label>` was undeliverable through hooks); the PreToolUse advice
/// relativised the file against the repository root (so it was silence for any
/// agent in a worktree); and a briefing told every agent about itself as a peer.
///
/// Reproduced through the real binary for exactly the reason `StagedFilesTests`
/// gives: these all live in *how git and a shell read the world*, so a unit test
/// over a hand-written array would pass while the documented flow is broken.
final class MultiWorktreeCoordinationTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var binary: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("multi-\(UUID())")
        home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"])
        try git(["config", "user.email", "t@example.com"])
        try git(["config", "user.name", "t"])
        try "seed\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git(["add", "-A"]); try git(["commit", "-qm", "seed"])

        binary = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GENTLEMERGE_BIN"]
            ?? ".build/debug/gentlemerge").standardizedFileURL.path
        XCTAssertTrue(run(["project", "init", "--git-hooks", "--label", "claude"], in: root).succeeded)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func git(_ args: [String], in directory: URL? = nil) throws -> String {
        let out = Shell.run("/usr/bin/env", ["git"] + args, in: directory ?? root, timeout: 30)
        guard out.succeeded else {
            throw NSError(domain: "git", code: Int(out.status), userInfo: [NSLocalizedDescriptionKey: out.stderr])
        }
        return out.stdout
    }

    private func run(_ args: [String], in directory: URL, label: String? = nil) -> Shell.Output {
        var env = ["GENTLEMERGE_HOME": home.path]
        if let label { env["GENTLEMERGE_LABEL"] = label }
        return Shell.run(binary, args + ["--project", directory.path], in: directory,
                         environment: env, timeout: 60)
    }

    /// The README's setup: one worktree per agent, each with its own label.
    private func worktree(_ name: String, branch: String, label: String) throws -> URL {
        // Inside `root`, not beside it: a sibling is not removed by tearDown and
        // collides with the next test's worktree of the same name.
        let url = root.appendingPathComponent(name)
        try git(["worktree", "add", "-q", url.path, "-b", branch])
        XCTAssertTrue(run(["project", "init", "--label", label], in: url).succeeded)
        return url
    }

    /// A note is signed by the worktree that wrote it, and a briefing delivers
    /// it to the worktree it was addressed to.
    func testANoteIsSignedByItsWorktreeAndDeliveredToItsAddressee() throws {
        let alice = try worktree("wt-alice", branch: "agent/alice", label: "alice")
        let bob = try worktree("wt-bob", branch: "agent/bob", label: "bob")

        XCTAssertTrue(run(["say", "--to", "bob", "bob: stay off lib/store"], in: alice, label: "alice").succeeded)

        // Authored as alice, not as the main checkout's label and not as "you".
        let messages = try decodedMessages()
        let message = messages.first { $0.to == "bob" }
        XCTAssertEqual(message?.from, "alice", "the worktree's own label, not the repository root's")

        // And bob's session-context — what a hook prints — hands it over.
        let context = run(["session-context", "--provider", "claude-code"], in: bob)
        XCTAssertTrue(context.succeeded, context.stderr)
        // The hook prints JSON, which escapes `/` — match on text with none in it.
        XCTAssertTrue(context.stdout.contains("stay off lib"),
                      "a note addressed to the worktree's label must reach that worktree: \(context.stdout)")
        XCTAssertTrue(context.stdout.contains("alice"), "and it names alice as the sender")
    }

    /// `say --done` takes back what *this* worktree said, and nothing else.
    func testSayDoneOnlyTakesBackThisWorktreesNotes() throws {
        let alice = try worktree("wt-alice", branch: "agent/alice", label: "alice")
        let bob = try worktree("wt-bob", branch: "agent/bob", label: "bob")

        XCTAssertTrue(run(["say", "--kind", "urgent", "--to", "bob",
                           "bob: DO NOT touch lib/store"], in: alice, label: "alice").succeeded)
        XCTAssertTrue(run(["say", "bob's own note"], in: bob, label: "bob").succeeded)
        XCTAssertTrue(run(["say", "--done"], in: bob, label: "bob").succeeded)

        // Only bob's note may be buried. A resolve echoes the opening words of
        // what it buries, so the tombstone's *text* would match either way —
        // what matters is which id it names.
        let messages = try decodedMessages()
        let aliceNote = messages.first { $0.from == "alice" && $0.to == "bob" }
        let bobNote = messages.first { $0.from == "bob" }
        XCTAssertNotNil(aliceNote); XCTAssertNotNil(bobNote)
        let buried = Set(messages.filter { $0.effectiveKind == .resolve }.compactMap(\.refID))
        XCTAssertFalse(buried.contains(aliceNote!.id),
                       "another agent's blocker was taken back by somebody else's --done")
        XCTAssertTrue(buried.contains(bobNote!.id), "my own note is the one that goes")
    }

    private func decodedMessages() throws -> [AgentMessage] {
        let lines = try String(contentsOf: Paths(home: home).messages, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        return try lines.compactMap { line in
            try JSONCoding.decoder().decode(AgentMessage.self, from: Data(line.utf8))
        }
    }

    /// A task is credited to the worktree that added it.
    func testATaskIsCreditedToTheWorktreeThatAddedIt() throws {
        let bob = try worktree("wt-bob", branch: "agent/bob", label: "bob")
        XCTAssertTrue(run(["task", "add", "widen the data zone"], in: bob, label: "bob").succeeded)

        let handoff = ProjectRegistry.handoff(for: root.path, refreshingCommits: false)
        let task = handoff.tasks.first { $0.text == "widen the data zone" }
        XCTAssertEqual(task?.addedBy, "bob")
    }

    /// The PreToolUse answer sees a claim held by another worktree. It used to
    /// relativise the file against the repository root and say nothing at all.
    func testThePreToolUseAdviceSeesAnotherWorktreesClaim() throws {
        let alice = try worktree("wt-alice", branch: "agent/alice", label: "alice")
        let bob = try worktree("wt-bob", branch: "agent/bob", label: "bob")

        XCTAssertTrue(run(["claim", "--paths", "lib/store/**", "--intent", "alice is here"],
                          in: alice, label: "alice").succeeded)

        let payload = root.appendingPathComponent("payload-\(UUID()).json")
        try """
        {"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"\(bob.path)/lib/store/x.dart"}}
        """.write(to: payload, atomically: true, encoding: .utf8)

        let advice = Shell.run(binary, ["advise", "--payload", payload.path, "--project", bob.path,
                                        "--provider", "claude-code"],
                               in: bob, environment: ["GENTLEMERGE_HOME": home.path], timeout: 60)
        XCTAssertTrue(advice.stdout.contains("claimed by alice"),
                      "no pre-edit warning for a claimed path in a worktree: \(advice.stdout)")
        XCTAssertTrue(advice.stdout.contains("say --to alice"), "the reason names the way out")
    }

    /// A reader is never told about itself as another working agent.
    func testABriefingDoesNotListTheReaderAsItsOwnPeer() throws {
        let alice = try worktree("wt-alice", branch: "agent/alice", label: "alice")
        let bob = try worktree("wt-bob", branch: "agent/bob", label: "bob")

        XCTAssertTrue(run(["say", "alice is here"], in: alice, label: "alice").succeeded)
        XCTAssertTrue(run(["say", "bob is here"], in: bob, label: "bob").succeeded)

        // The MCP reader is the shape a hook-less agent (Hermes, Gemini, …) has.
        let request = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"status","arguments":{}}}"#
        let answer = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["mcp", "--label", "bob"]
        process.currentDirectoryURL = bob
        process.environment = ["GENTLEMERGE_HOME": home.path, "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"]
        process.standardInput = Pipe()
        process.standardOutput = answer
        let input = process.standardInput as! Pipe
        try process.run()
        input.fileHandleForWriting.write(Data((request + "\n").utf8))
        try input.fileHandleForWriting.close()
        let data = answer.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let text = String(decoding: data, as: UTF8.self)
        let peers = text.components(separatedBy: "right now").last ?? ""
        XCTAssertTrue(text.contains("alice"), "alice is a peer and must be listed: \(text)")
        XCTAssertFalse(peers.contains("on agent/bob"),
                       "the reader's own presence mark is listed as a peer: \(text)")
    }
}
