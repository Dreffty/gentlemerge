import Foundation
import XCTest
@testable import GentleMergeCore

final class SimAgentTests: XCTestCase {
    func testHelpDescribesSimulationAndIsolationOptions() throws {
        let binary = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GENTLEMERGE_BIN"] ?? ".build/debug/gentlemerge").standardizedFileURL.path
        let help = Shell.run(binary, ["help"])
        for text in ["gentlemerge sim --script", "gentlemerge demo", "--keep", "--home-real"] {
            XCTAssertTrue(help.stdout.contains(text), "missing \(text)")
        }
    }

    func testCLISimEmitsAndIngestsRealEnvelopes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("script.json")
        try Data(#"{"label":"claude","capabilities":[],"steps":[{"action":"edit","paths":["hello.txt"],"text":"hello"}]}"#.utf8).write(to: script)
        let home = root.appendingPathComponent("home")
        let binary = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GENTLEMERGE_BIN"] ?? ".build/debug/gentlemerge").standardizedFileURL.path
        let out = Shell.run(binary, ["sim", "--script", script.path, "--worktree", root.path], environment: ["GENTLEMERGE_HOME": home.path])
        XCTAssertEqual(out.status, 0, out.text)
        XCTAssertEqual(try? String(contentsOf: root.appendingPathComponent("hello.txt"), encoding: .utf8), "hello")
        let paths = Paths(home: home)
        let names = (try? FileManager.default.contentsOfDirectory(at: paths.processed, includingPropertiesForKeys: nil)) ?? []
        let events = names.compactMap { try? JSONCoding.decoder().decode(SpoolEnvelope.self, from: Data(contentsOf: $0)) }.compactMap(\.eventName)
        XCTAssertEqual(Set(events), Set(["SessionStart", "PostToolUse", "Stop", "SessionEnd"]))
        XCTAssertFalse(AgentBus(paths: paths).activities().isEmpty)
    }

    @MainActor
    func testSimulationLeavesUnrelatedQueuedEnvelopeUntouched() async throws {
        let root = Demo.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = Paths(home: root.appendingPathComponent("home"))
        try paths.createDirectories()
        let store = SpoolStore(paths: paths)
        let unrelated = SpoolEnvelope(receivedAt: Date(timeIntervalSince1970: 100), cwd: root.path, payload: .object([
            "hook_event_name": .string("SessionEnd"), "session_id": .string("unrelated-session")
        ]))
        try store.enqueue(unrelated)
        let queued = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: paths.spool, includingPropertiesForKeys: nil).first)
        let original = try Data(contentsOf: queued)
        try SimAgent(paths: paths, worktree: root,
            script: SimScript(label: "claude", capabilities: [], steps: [])).run { _ in }
        XCTAssertEqual(try? Data(contentsOf: queued), original)
        XCTAssertFalse(AgentBus(paths: paths).activities().contains { $0.id == "unrelated-session" })
        XCTAssertEqual(store.drain(), [unrelated])
        XCTAssertTrue(store.drain().isEmpty)
    }

    @MainActor
    func testImplicitClaimsUseScriptIdentityAndRepoRelativePathsAcrossWorktrees() async throws {
        let root = Demo.temporaryRoot()
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ args: [String]) throws {
            let result = Shell.run("/usr/bin/env", ["git", "-c", "commit.gpgsign=false"] + args, in: repo,
                environment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"])
            XCTAssertTrue(result.succeeded, result.text)
            if !result.succeeded { throw SimError.expectationFailed(result.text) }
        }
        try git(["init", "-q", "-b", "main"])
        try git(["-c", "user.name=sim", "-c", "user.email=sim@example.test", "commit", "--allow-empty", "-qm", "initial"])
        let paths = Paths(home: root.appendingPathComponent("home"))
        let project = ProjectRegistry.canonicalPath(for: repo.path)
        for label in ["hermes", "claude", "codex"] {
            let worktree = root.appendingPathComponent("wt-" + label)
            try git(["worktree", "add", "-qb", label, worktree.path])
            try SimAgent(paths: paths, worktree: worktree, script: SimScript(label: label, capabilities: [],
                steps: [.init(action: "edit", paths: ["lib/\(label).swift"])] )).run { _ in }
        }
        let claims = PathClaims(paths: paths).load().filter(\.implicit)
        XCTAssertEqual(claims.count, 3)
        for label in ["hermes", "claude", "codex"] {
            let claim = try XCTUnwrap(claims.first { $0.pattern.hasSuffix("\(label).swift") })
            XCTAssertEqual(claim.label, label)
            XCTAssertEqual(claim.pattern, "lib/\(label).swift")
            XCTAssertEqual(claim.projectPath, project)
        }
        let sessions = AgentBus(paths: paths).activities().filter { $0.id.hasPrefix("sim-") }
        XCTAssertEqual(sessions.count, 3)
        XCTAssertTrue(sessions.allSatisfy { $0.state == .ended })
    }

    @MainActor
    func testEnvelopeProviderAndActivityLifecycleUseRealIngestion() async throws {
        let root = Demo.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = Paths(home: root.appendingPathComponent("home"))
        try paths.createDirectories()
        for (label, provider) in [("claude", AgentProvider.claudeCode), ("codex", .codex), ("hermes", .unknown)] {
            let agent = SimAgent(paths: paths, worktree: root,
                script: SimScript(label: label, capabilities: [], steps: []))
            for (event, state) in [("SessionStart", AgentActivity.State.working), ("Stop", .idle), ("SessionEnd", .ended)] {
                try agent.emit(event)
                let activity = try XCTUnwrap(AgentBus(paths: paths).activities().first { $0.id == agent.sessionID })
                XCTAssertEqual(activity.provider, provider)
                XCTAssertEqual(activity.state, state)
            }
        }
        let files = try FileManager.default.contentsOfDirectory(at: paths.processed, includingPropertiesForKeys: nil)
        let envelopes = try files.map { try JSONCoding.decoder().decode(SpoolEnvelope.self, from: Data(contentsOf: $0)) }
        XCTAssertEqual(envelopes.count, 9)
        for envelope in envelopes {
            let label = try XCTUnwrap(envelope.payload.string("label"))
            XCTAssertEqual(envelope.provider, label == "claude" ? .claudeCode : label == "codex" ? .codex : .unknown)
        }
    }

    @MainActor
    func testEditRejectsEscapesIncludingSymlinks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let wt = root.appendingPathComponent("wt")
        try FileManager.default.createDirectory(at: wt, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: wt.appendingPathComponent("link"), withDestinationURL: root)
        for path in ["../outside.txt", root.appendingPathComponent("absolute.txt").path, "link/escaped.txt"] {
            let agent = SimAgent(paths: Paths(home: root.appendingPathComponent("home")), worktree: wt,
                script: SimScript(label: "claude", capabilities: [], steps: [.init(action: "edit", paths: [path])]))
            XCTAssertThrowsError(try agent.run { _ in }, path)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("outside.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escaped.txt").path))
    }

    @MainActor
    func testProtocolActionsRouteAndCompleteRealRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = Paths(home: root.appendingPathComponent("home"))
        func run(_ label: String, _ capabilities: [String], _ steps: [SimStep]) throws {
            try SimAgent(paths: paths, worktree: root, script: SimScript(label: label, capabilities: capabilities, steps: steps)).run { _ in }
        }
        try run("codex", ["image_generation"], [])
        try run("claude", [], [.init(action: "claim", paths: ["lib/**"]),
            .init(action: "release"), .init(action: "say", text: "please add sku", to: "hermes"),
            .init(action: "delegate", text: "hero", to: "capability:image_generation", mayTouch: ["assets/**"])])
        try run("codex", ["image_generation"], [.init(action: "brief"), .init(action: "request_accept"),
            .init(action: "sleep", seconds: 0), .init(action: "request_done", text: "hero complete")])
        let request = try XCTUnwrap(Requests(paths: paths).all().first)
        XCTAssertEqual(request.state, .done)
        XCTAssertEqual(request.resolvedTo, "codex")
        XCTAssertEqual(request.result, "hero complete")
        XCTAssertTrue(PathClaims(paths: paths).load().isEmpty)
        let brief = AgentBus(paths: paths).briefing(sessionID: "hermes", me: "hermes", project: ProjectRegistry.canonicalPath(for: root.path))
        XCTAssertTrue(brief?.contains("please add sku") == true)
    }

    @MainActor
    func testHeadlessIngestionDisablesReviewWithoutChangingConfig() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = Paths(home: root.appendingPathComponent("home"))
        try paths.createDirectories()
        AppConfig(reviewOnSessionEnd: true).save(to: paths.config)
        let original = try Data(contentsOf: paths.config)
        let model = InboxModel(paths: paths)
        model.ingest(SpoolEnvelope(cwd: root.path, payload: .object([
            "hook_event_name": .string("SessionEnd"), "session_id": .string("sim-review")
        ])), allowReview: false)
        XCTAssertNil(model.activeReview)
        XCTAssertEqual(try Data(contentsOf: paths.config), original)
    }

    func testEnqueueRoundTripsHookEnvelope() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SpoolStore(paths: Paths(home: root))
        let envelope = SpoolEnvelope(id: "../../unsafe", receivedAt: Date(timeIntervalSince1970: 100), payload: .object([
            "hook_event_name": .string("SessionStart"), "session_id": .string("sim-test")
        ]))
        try store.enqueue(envelope)
        XCTAssertEqual(store.drain(), [envelope])
        XCTAssertTrue(store.drain().isEmpty)
    }
}
