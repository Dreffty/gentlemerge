import Foundation
import XCTest
@testable import GentleMergeCore

final class DemoTests: XCTestCase {
    func testTemporaryNameSurvivesRedactionOfNumericUUIDs() {
        let id = UUID(uuidString: "12345678-1234-4567-8912-123456789012")!
        let root = Demo.temporaryRoot(id: id)
        XCTAssertEqual(Redactor.scrub(root.lastPathComponent).text, root.lastPathComponent)
    }

    func testCLIRealDemoIsIsolatedAndHookBlocksDespiteInheritedSkip() throws {
        let realHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: realHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: realHome) }
        let binary = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GENTLEMERGE_BIN"] ?? ".build/debug/gentlemerge").standardizedFileURL.path
        let output = Shell.run(binary, ["demo", "--keep"], environment: [
            "GENTLEMERGE_HOME": realHome.path, "GENTLEMERGE_SKIP": "1", "GENTLEMERGE_BIN": "/nonexistent-old-binary"
        ])
        XCTAssertEqual(output.status, 0, output.text)
        for marker in ["commit ok", "delegated req-", "commit BLOCKED: ✖", "accepted req-", "done req-", "[hermes] briefing:", "claude", "need a nullable `sku`"] {
            XCTAssertTrue(output.stdout.contains(marker), "Missing \(marker): \(output.text)")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: realHome.path), [])
        let repoLine = try XCTUnwrap(output.lines.first(where: { $0.hasPrefix("repo: ") }))
        let repo = URL(fileURLWithPath: String(repoLine.dropFirst(6)))
        let root = repo.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = Paths(home: root.appendingPathComponent("home"))
        XCTAssertEqual(Requests(paths: paths).all().first?.state, .done)
        let worktrees = Shell.run("/usr/bin/env", ["git", "worktree", "list", "--porcelain"], in: repo)
        XCTAssertEqual(worktrees.lines.filter { $0.hasPrefix("worktree ") }.count, 4)
        let commits = Shell.run("/usr/bin/env", ["git", "log", "--all", "--format=%s"], in: repo)
        XCTAssertTrue(commits.stdout.contains("feat(store): product page"))
        XCTAssertFalse(commits.stdout.contains("add sku to Product"))
        let hook = repo.appendingPathComponent(".git/hooks/pre-commit")
        XCTAssertTrue(try String(contentsOf: hook, encoding: .utf8).contains(GitHookInstaller.marker))
    }

    func testCLIRefusesInheritedGitRepositoryBeforeAnyWrites() throws {
        let binary = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GENTLEMERGE_BIN"] ?? ".build/debug/gentlemerge").standardizedFileURL.path
        for command in ["demo", "sim"] {
            let root = Demo.temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let caller = root.appendingPathComponent("caller")
            let worktree = root.appendingPathComponent("simulation")
            let home = root.appendingPathComponent("home")
            try FileManager.default.createDirectory(at: caller, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
            func git(_ arguments: [String]) throws {
                let output = Shell.run("/usr/bin/env", ["git"] + arguments, in: caller,
                    environment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"])
                XCTAssertEqual(output.status, 0, output.text)
            }
            try git(["init", "-q", "-b", "main"])
            try git(["config", "user.name", "caller"])
            try git(["config", "user.email", "caller@example.invalid"])
            try AtomicFile.write(Data("original\n".utf8), to: caller.appendingPathComponent("sentinel.txt"))
            try git(["add", "."])
            try git(["-c", "commit.gpgsign=false", "commit", "-qm", "caller initial"])
            try AtomicFile.write(Data("uncommitted caller work\n".utf8), to: caller.appendingPathComponent("sentinel.txt"))
            let script = root.appendingPathComponent("script.json")
            try AtomicFile.write(JSONEncoder().encode(SimScript(label: "claude", capabilities: [], steps: [
                .init(action: "edit", paths: ["sim.txt"]), .init(action: "commit", text: "sim change")
            ])), to: script)
            let before = try fileSnapshot(caller)
            let arguments = command == "demo" ? ["demo", "--home-real"]
                : ["sim", "--script", script.path, "--worktree", worktree.path]
            let output = Shell.run(binary, arguments, in: root, environment: [
                "GENTLEMERGE_HOME": home.path, "GIT_DIR": caller.appendingPathComponent(".git").path,
                "GIT_WORK_TREE": caller.path
            ])
            XCTAssertEqual(output.status, 1, output.text)
            XCTAssertTrue(output.stderr.contains("refusing inherited Git environment"), output.text)
            XCTAssertTrue(output.stderr.contains("GIT_DIR"), output.text)
            XCTAssertTrue(output.stderr.contains("GIT_WORK_TREE"), output.text)
            XCTAssertTrue(before == (try fileSnapshot(caller)), "\(command) mutated caller repository")
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.path), "\(command) wrote home before refusing")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: worktree.path), [])
        }
    }

    private func fileSnapshot(_ root: URL) throws -> [String: Data] {
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        var result: [String: Data] = [:]
        for case let file as URL in files {
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[String(file.path.dropFirst(root.path.count))] = try Data(contentsOf: file)
            }
        }
        return result
    }

    func testCLIDemoCleansTemporaryRoot() throws {
        let binary = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GENTLEMERGE_BIN"] ?? ".build/debug/gentlemerge").standardizedFileURL.path
        let output = Shell.run(binary, ["demo"])
        XCTAssertEqual(output.status, 0, output.text)
        let repoLine = try XCTUnwrap(output.lines.first(where: { $0.hasPrefix("repo: ") }))
        let root = URL(fileURLWithPath: String(repoLine.dropFirst(6))).deletingLastPathComponent()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
}
