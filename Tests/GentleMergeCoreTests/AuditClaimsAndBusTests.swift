import XCTest
@testable import GentleMergeCore

// MARK: - Glob: an absolute claim must not claim the whole repository

final class GlobAbsolutePatternTests: XCTestCase {
    /// The last trailing window of `/…/lib/data/**` was `**`, which matches every
    /// path: a claim on lib/data blocked commits to README.md.
    func testAnAbsolutePatternNeverMatchesTheWholeRepository() {
        let pattern = "/Users/dev/app/lib/data/**"
        XCTAssertFalse(Glob.matches(pattern, "README.md"))
        XCTAssertFalse(Glob.matches(pattern, "assets/hero.png"))
        XCTAssertFalse(Glob.matches(pattern, "lib/store/a.dart"))
        XCTAssertTrue(Glob.matches(pattern, "lib/data/b.dart"), "it must still cover its own directory")
    }

    func testAnAbsoluteExtensionPatternDoesNotMatchEveryFileOfThatType() {
        XCTAssertFalse(Glob.matches("/Users/dev/app/*.swift", "Sources/Deep/File.swift"))
        XCTAssertFalse(Glob.matches("/Users/dev/app/lib/*.swift", "Sources/File.swift"))
    }

    func testRelativizeStripsTheRepositoryRoot() {
        XCTAssertEqual(Glob.relativize("/r/app/lib/data/**", roots: ["/r/app"]), "lib/data/**")
        XCTAssertEqual(Glob.relativize("/r/app/README.md", roots: ["/r/app"]), "README.md")
        XCTAssertEqual(Glob.relativize("/r/app/lib/*.dart", roots: ["/r/app/"]), "lib/*.dart")
        XCTAssertEqual(Glob.relativize("/r/app", roots: ["/r/app"]), "**")
        XCTAssertEqual(Glob.relativize("/r/app/**", roots: ["/r/app"]), "**")
    }

    func testRelativeAndOutsidePatternsAreLeftAlone() {
        XCTAssertEqual(Glob.relativize("lib/**", roots: ["/r/app"]), "lib/**")
        XCTAssertEqual(Glob.relativize("/elsewhere/lib/**", roots: ["/r/app"]), "/elsewhere/lib/**")
        XCTAssertEqual(Glob.relativize("/r/application/lib", roots: ["/r/app"]), "/r/application/lib",
                       "/r/app must not match /r/application")
    }

    func testASymlinkedPrefixIsResolved() throws {
        let real = FileManager.default.temporaryDirectory.appendingPathComponent("rel-\(UUID())")
        try FileManager.default.createDirectory(at: real.appendingPathComponent("lib"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: real) }
        let link = real.deletingLastPathComponent().appendingPathComponent("rel-link-\(UUID())")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: link) }
        XCTAssertEqual(Glob.relativize(link.path + "/lib/**", roots: [real.resolvingSymlinksInPath().path]), "lib/**")
    }
}

// MARK: - The bus said "sent" when it was not

final class BusWriteFailureTests: XCTestCase {
    func testSendThrowsWhenTheLogCannotBeWritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bus-fail-\(UUID())")
        let paths = try Paths(home: root).createDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        // The log is a directory: every append must fail.
        try FileManager.default.createDirectory(at: paths.messages, withIntermediateDirectories: true)
        let bus = AgentBus(paths: paths)
        XCTAssertThrowsError(try bus.send(AgentMessage(from: "a", text: "hello")))
        XCTAssertThrowsError(try bus.say(from: "a", text: "hello"))
        // `post` stays fire-and-forget for callers with nobody to tell.
        _ = bus.post(AgentMessage(from: "a", text: "hello"))
    }

    func testSendStillWorksAndScrubsOnAHealthyHome() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bus-ok-\(UUID())")
        let paths = try Paths(home: root).createDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        let bus = AgentBus(paths: paths)
        let result = try bus.send(AgentMessage(from: "a", text: "call luis@example.com"))
        XCTAssertTrue(result.didRedact)
        XCTAssertEqual(bus.messages().count, 1)
        XCTAssertFalse(bus.messages()[0].text.contains("luis@example.com"))
    }
}

// MARK: - MCP

final class AuditMCPTests: XCTestCase {
    private var root: URL!
    private var project: URL!
    private var paths: Paths!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-audit-\(UUID())")
        project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        paths = try Paths(home: root.appendingPathComponent("home")).createDirectories()
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func server(_ label: String, verified: Bool = false) -> MCPServer {
        MCPServer(paths: paths, cwd: project.path, identity: label, identityVerified: verified)
    }

    private func call(_ server: MCPServer, _ name: String, _ args: [String: JSONValue] = [:]) throws -> JSONValue {
        let line = try JSONCoding.encoder().encode(JSONValue.object([
            "jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/call"),
            "params": .object(["name": .string(name), "arguments": .object(args)]),
        ]))
        return try JSONCoding.decoder().decode(
            JSONValue.self, from: Data(XCTUnwrap(server.handle(line: String(decoding: line, as: UTF8.self))).utf8))
    }

    private func text(_ response: JSONValue) -> String {
        response["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
    }

    private func isError(_ response: JSONValue) -> Bool {
        response["error"] != nil || response["result"]?["isError"] == .bool(true)
    }

    /// The tool promised "only your own watches"; any agent could call off another's.
    func testWatchRmOnlyCallsOffTheCallersOwnWatches() throws {
        let hermes = server("hermes")
        _ = try call(hermes, "watch_add", ["kind": .string("session-idle"), "target": .string("codex")])
        let rule = try XCTUnwrap(Watches(paths: paths).pending().first)

        let claude = server("claude")
        let refused = try call(claude, "watch_rm", ["id": .string(String(rule.id.prefix(8)))])
        XCTAssertTrue(isError(refused), text(refused))
        XCTAssertEqual(Watches(paths: paths).pending().count, 1, "hermes' watch must still stand")

        let own = try call(hermes, "watch_rm", ["id": .string(String(rule.id.prefix(8)))])
        XCTAssertFalse(isError(own), text(own))
        XCTAssertTrue(Watches(paths: paths).pending().isEmpty)
    }

    /// An empty claim overlaps every other claim: one `paths: [""]` shut the others out.
    func testAnEmptyPathIsRefusedSoItCannotShutEveryoneOut() throws {
        let response = try call(server("hermes"), "claim", ["paths": .array([.string("")])])
        XCTAssertTrue(isError(response), text(response))
        XCTAssertTrue(PathClaims(paths: paths).live(project: project.path).isEmpty)
        let blank = try call(server("hermes"), "claim", ["paths": .array([.string("  ")])])
        XCTAssertTrue(isError(blank))
    }

    func testAnAbsoluteClaimIsStoredRelativeToTheRepository() throws {
        let absolute = ProjectRegistry.canonicalPath(for: project.path) + "/lib/data/**"
        _ = try call(server("hermes"), "claim", ["paths": .array([.string(absolute)])])
        XCTAssertEqual(PathClaims(paths: paths).live(project: ProjectRegistry.canonicalPath(for: project.path)).map(\.pattern),
                       ["lib/data/**"])
    }

    func testADelegatedRequestCarriesTheServersVerifiedFlag() throws {
        func delegate(_ verified: Bool, to: String) throws -> AgentRequest {
            let response = try call(server("claude", verified: verified), "delegate", [
                "to": .string(to), "title": .string("t"), "spec": .string("s"),
            ])
            XCTAssertFalse(isError(response), text(response))
            return try XCTUnwrap(Requests(paths: paths).all().first { $0.to == to })
        }
        XCTAssertTrue(try delegate(true, to: "hermes").fromVerified)
        XCTAssertFalse(try delegate(false, to: "codex").fromVerified)
    }

    /// `brief` is a read. It used to rewrite the repository's HANDOFF.md (the map and
    /// the commit list) whenever HEAD had moved, leaving the tree dirty.
    func testBriefDoesNotRewriteTheHandoffFile() throws {
        func git(_ args: [String]) throws {
            let out = Shell.run("/usr/bin/env", ["git"] + args, in: project, timeout: 30)
            XCTAssertTrue(out.succeeded, out.stderr)
        }
        try git(["init", "-q", "-b", "main"])
        try git(["config", "user.email", "t@example.com"]); try git(["config", "user.name", "t"])
        try "a\n".write(to: project.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git(["add", "-A"]); try git(["commit", "-qm", "first"])
        _ = try ProjectRegistry.initialize(projectPath: project.path)
        let handoff = ProjectHandoff.fileURL(for: ProjectRegistry.canonicalPath(for: project.path))
        // Move HEAD past the commit the map was sealed with.
        try "b\n".write(to: project.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try git(["add", "-A"]); try git(["commit", "-qm", "second"])
        let before = try Data(contentsOf: handoff)

        let response = try call(server("hermes"), "brief")
        XCTAssertFalse(isError(response))
        XCTAssertEqual(try Data(contentsOf: handoff), before, "a read must not rewrite HANDOFF.md")
    }
}

// MARK: - Watches follow the worktree label, not the provider

@MainActor
final class WatchByLabelTests: XCTestCase {
    private var root: URL!
    private var project: URL!
    private var paths: Paths!
    private var model: InboxModel!

    override func setUp() async throws {
        try await MainActor.run { try prepare() }
    }
    private func prepare() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("watch-label-\(UUID())")
        project = FileManager.default.temporaryDirectory.appendingPathComponent("watch-label-project-\(UUID())")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        paths = try Paths(home: root).createDirectories()
        model = InboxModel(paths: paths)
    }
    override func tearDown() async throws {
        await MainActor.run {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: project)
        }
    }

    private func stop(label: String?, session: String) -> SpoolEnvelope {
        SpoolEnvelope(provider: .claudeCode, cwd: project.path, pid: nil, label: label,
                      payload: .object(["session_id": .string(session), "hook_event_name": .string("Stop")]))
    }

    private func notices() -> [AgentMessage] {
        model.bus.messages().filter { $0.from == "inbox" }
    }

    /// A Claude Code session in the worktree labelled `hermes` is hermes. The watch for
    /// `hermes` never fired, and the one for `claude` fired instead.
    func testAWatchOnAWorktreeLabelFiresForThatWorktreesSession() throws {
        let canonical = ProjectRegistry.canonicalPath(for: project.path)
        let watches = Watches(paths: paths)
        try watches.add(WatchRule(owner: "boss", projectPath: canonical, kind: .sessionIdle, target: "hermes"))
        try watches.add(WatchRule(owner: "boss2", projectPath: canonical, kind: .sessionIdle, target: "claude"))

        model.ingest(stop(label: "hermes", session: "s-hermes"))

        let got = notices()
        XCTAssertEqual(got.map(\.to), ["boss"], "only the hermes watch may fire: \(got.map(\.text))")
        XCTAssertTrue(got.first?.text.contains("hermes") == true)
        XCTAssertFalse(got.contains { $0.text.contains("claude finished") })
    }

    func testASessionWithNoWorktreeLabelStillMatchesItsProviderName() throws {
        let canonical = ProjectRegistry.canonicalPath(for: project.path)
        try Watches(paths: paths).add(WatchRule(owner: "boss", projectPath: canonical, kind: .sessionIdle, target: "claude"))
        model.ingest(stop(label: nil, session: "s-plain"))
        XCTAssertEqual(notices().map(\.to), ["boss"])
    }
}

// MARK: - Through the binary: identity from the worktree, claims, loud failures

final class AuditBusCLITests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var binary: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("audit-bus-\(UUID())")
        home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        binary = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GENTLEMERGE_BIN"]
            ?? ".build/debug/gentlemerge").standardizedFileURL.path
        try git(["init", "-q", "-b", "main"], in: root)
        try git(["config", "user.email", "t@example.com"], in: root)
        try git(["config", "user.name", "t"], in: root)
        try "seed\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git(["add", "-A"], in: root); try git(["commit", "-qm", "seed"], in: root)
        XCTAssertTrue(run(["project", "init", "--label", "claude"], in: root).succeeded)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    private func git(_ args: [String], in dir: URL) throws -> Shell.Output {
        let out = Shell.run("/usr/bin/env", ["git"] + args, in: dir, timeout: 60)
        guard out.succeeded else {
            throw NSError(domain: "git", code: Int(out.status), userInfo: [NSLocalizedDescriptionKey: out.stderr])
        }
        return out
    }

    private func worktree(_ name: String, label: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try git(["worktree", "add", "-q", url.path, "-b", "agent/\(name)"], in: root)
        XCTAssertTrue(run(["project", "init", "--label", label], in: url).succeeded)
        return url
    }

    /// Inside a Claude Code session, with CLAUDECODE exported — the usual case.
    private func run(_ args: [String], in dir: URL, environment: [String: String] = [:]) -> Shell.Output {
        Shell.run(binary, args, in: dir,
                  environment: ["GENTLEMERGE_HOME": home.path, "CLAUDECODE": "1"]
                    .merging(environment) { _, new in new }, timeout: 60)
    }

    private func claimedBy() throws -> [String] {
        let data = try Data(contentsOf: home.appendingPathComponent("claims.json"))
        let rows = try JSONCoding.decoder().decode([TaskClaim].self, from: data)
        return rows.map(\.claimedBy)
    }

    /// `task claim` credited the provider the environment hinted at ("claude") instead
    /// of the worktree's label, so the real claude could claim the same task unopposed.
    func testATaskClaimIsMadeUnderTheWorktreesLabel() throws {
        let hermes = try worktree("wt-hermes", label: "hermes")
        XCTAssertTrue(run(["task", "add", "shared work"], in: hermes).succeeded)
        let claim = run(["task", "claim", "0"], in: hermes)
        XCTAssertEqual(claim.status, 0, claim.stderr)
        XCTAssertEqual(try claimedBy(), ["hermes"])

        let other = try worktree("wt-claude", label: "claude")
        let clash = run(["task", "claim", "0"], in: other)
        XCTAssertEqual(clash.status, 1, "a second agent claiming the same task must be told: \(clash.stdout)")
    }

    func testAWatchIsOwnedByTheWorktreesLabel() throws {
        let hermes = try worktree("wt-hermes", label: "hermes")
        XCTAssertTrue(run(["watch", "idle", "codex"], in: hermes).succeeded)
        let rule = try XCTUnwrap(Watches(paths: Paths(home: home)).pending().first)
        XCTAssertEqual(rule.owner, "hermes")
    }

    /// And nobody may take a label their worktree does not carry.
    func testActingAsAnotherLabelIsRefused() throws {
        let hermes = try worktree("wt-hermes", label: "hermes")
        XCTAssertTrue(run(["task", "add", "x"], in: hermes).succeeded)
        XCTAssertEqual(run(["task", "claim", "0", "--as", "claude"], in: hermes).status, 1)
    }

    func testAnAbsoluteClaimIsStoredRelativeAndDoesNotBlockOtherFiles() throws {
        let hermes = try worktree("wt-hermes", label: "hermes")
        let out = run(["claim", "--paths", hermes.resolvingSymlinksInPath().path + "/lib/data/**"], in: hermes)
        XCTAssertEqual(out.status, 0, out.stderr)
        let live = try XCTUnwrap(PathClaims(paths: Paths(home: home)).load().first)
        XCTAssertEqual(live.pattern, "lib/data/**")
        XCTAssertFalse(Glob.matches(live.pattern, "README.md"))
    }

    func testSayFailsLoudlyWhenTheMessageLogCannotBeWritten() throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("messages.jsonl"),
                                                withIntermediateDirectories: true)
        let out = run(["say", "important blocker", "--global"], in: root)
        XCTAssertEqual(out.status, 1, out.stdout)
        XCTAssertFalse(out.stdout.contains("Sent as"), "it claimed to have sent: \(out.stdout)")
        XCTAssertTrue(out.stderr.contains("Not sent"), out.stderr)
    }
}
