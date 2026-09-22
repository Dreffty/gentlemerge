import XCTest
@testable import GentleMergeCore

final class DispatcherTests: XCTestCase {
    func testPromptAndPlaceholdersReachChild() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = try Paths(home: home).createDirectories()
        let store = Requests(paths: paths)
        var request = AgentRequest(id: store.freshID(), from: "a", fromVerified: true, to: "b", projectPath: home.path, title: "Prompt test", spec: "Stay local", state: .assigned)
        request.resolvedTo = "b"
        try store.save(request)
        let runner = Dispatcher(paths: paths)
        let task = try runner.run(request, target: AgentTarget(label: "b", command: ["/usr/bin/printf", "%s\n", "{request_id}", "{worktree}", "{prompt_file}", "@{prompt_file}"]))
        await task.value
        let prompt = try String(contentsOf: paths.dispatch.appendingPathComponent("\(request.id).prompt.md"), encoding: .utf8)
        let log = try String(contentsOf: paths.dispatch.appendingPathComponent("\(request.id).log"), encoding: .utf8)
        XCTAssertTrue(prompt.contains("gentlemerge request accept \(request.id)"))
        XCTAssertTrue(prompt.contains("Stay local"))
        XCTAssertTrue(log.hasPrefix(request.id + "\n" + home.path + "\n"))
        XCTAssertTrue(log.contains(prompt))
        XCTAssertFalse(log.contains("{prompt_file}"))
    }

    func testChildReceivesTargetIdentity() async throws {
        // No long digit runs in the home name: the dispatch log is scrubbed,
        // and a random UUID trips the long-number rule one run in fourteen.
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "dispatch-test-" + UUID().uuidString.replacingOccurrences(of: "[0-9]", with: "a", options: .regularExpression)
        )
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = try Paths(home: home).createDirectories()
        let store = Requests(paths: paths)
        var request = AgentRequest(id: store.freshID(), from: "a", fromVerified: true, to: "dispatch-test-target", projectPath: home.path, title: "Identity test", spec: "", state: .assigned)
        request.resolvedTo = "dispatch-test-target"
        try store.save(request)
        let task = try Dispatcher(paths: paths).run(request,
            target: AgentTarget(label: "dispatch-test-target", command: ["/bin/sh", "-c", "printf '%s\n%s\n' \"$GENTLEMERGE_LABEL\" \"$GENTLEMERGE_HOME\""]))
        await task.value
        let log = try String(contentsOf: paths.dispatch.appendingPathComponent("\(request.id).log"), encoding: .utf8)
        XCTAssertEqual(log.components(separatedBy: "\n").first, "dispatch-test-target")
        XCTAssertEqual(log.components(separatedBy: "\n").dropFirst().first, home.path)
    }

    func testFailedProcessProducesLogAndRejectsUnacceptedRequest() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = try Paths(home: home).createDirectories()
        let store = Requests(paths: paths)
        var request = AgentRequest(id: store.freshID(), from: "a", fromVerified: true, to: "b", projectPath: home.path, title: "Local test", spec: "", state: .assigned)
        request.resolvedTo = "b"
        try store.save(request)
        let task = try Dispatcher(paths: paths).run(request, target: AgentTarget(label: "b", command: ["/usr/bin/false"]))
        await task.value
        XCTAssertEqual(store.load(request.id)?.state, .rejected)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.dispatch.appendingPathComponent("\(request.id).log").path))
        XCTAssertTrue(store.load(request.id)?.result?.contains("failed") == true)
        let events = Ledger(url: paths.ledger).recent().compactMap(\.title)
        XCTAssertTrue(events.contains("dispatch.start"))
        XCTAssertTrue(events.contains("dispatch.end"))
    }
}
