import XCTest
@testable import GentleMergeCore

/// The shared task list is a read-modify-write several agents perform at once,
/// and until it took a sidecar lock it was a lost update: eight concurrent
/// `gentlemerge task add` printed "Added" eight times and left one task on the
/// board, the other seven overwritten by whoever wrote last (audit
/// 2026-10-08). `PathClaims.mutate` has always locked; the handoff simply had
/// no such guard.
///
/// Real processes on purpose — in-process threads would serialise on nothing
/// and pass either way, which is how the bug stayed invisible.
final class ConcurrentTaskAddTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var binary: String!

    private let workers = 8

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("taskadd-\(UUID())")
        home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for arguments in [["init", "-q", "-b", "main"], ["config", "user.email", "t@example.com"],
                          ["config", "user.name", "t"]] {
            let out = Shell.run("/usr/bin/env", ["git"] + arguments, in: root, timeout: 30)
            XCTAssertTrue(out.succeeded, out.stderr)
        }
        try "seed\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let added = Shell.run("/usr/bin/env", ["git", "add", "-A"], in: root, timeout: 30)
        XCTAssertTrue(added.succeeded, added.stderr)
        let committed = Shell.run("/usr/bin/env", ["git", "commit", "-qm", "seed"], in: root, timeout: 30)
        XCTAssertTrue(committed.succeeded, committed.stderr)

        binary = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GENTLEMERGE_BIN"]
            ?? ".build/debug/gentlemerge").standardizedFileURL.path
        let initd = Shell.run(binary, ["project", "init", "--project", root.path],
            in: root, environment: ["GENTLEMERGE_HOME": home.path], timeout: 60)
        XCTAssertTrue(initd.succeeded, initd.stderr)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testConcurrentTaskAddsAllLand() throws {
        // Locals: the escaping closure is @Sendable and XCTestCase is not.
        let binary: String = self.binary, home: URL = self.home, root: URL = self.root
        let workers = self.workers
        let group = DispatchGroup()
        for w in 0..<workers {
            group.enter()
            DispatchQueue.global().async {
                let env = ["GENTLEMERGE_HOME": home.path, "GENTLEMERGE_LABEL": "w\(w)"]
                _ = Shell.run(binary, ["task", "add", "task from w\(w)", "--project", root.path],
                    in: root, environment: env, timeout: 60)
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 120), .success)

        let text = try String(
            contentsOf: ProjectHandoff.fileURL(for: root.path), encoding: .utf8
        )
        let landed = text.split(separator: "\n").filter { $0.hasPrefix("- [ ] task from w") }.count
        XCTAssertEqual(landed, workers, "every add must survive the race")
    }

    /// The same task from everybody at once is one task, not eight copies.
    func testConcurrentAddsOfTheSameTaskLandOnce() throws {
        let binary: String = self.binary, home: URL = self.home, root: URL = self.root
        let workers = self.workers
        let group = DispatchGroup()
        for w in 0..<workers {
            group.enter()
            DispatchQueue.global().async {
                let env = ["GENTLEMERGE_HOME": home.path, "GENTLEMERGE_LABEL": "w\(w)"]
                _ = Shell.run(binary, ["task", "add", "the same task", "--project", root.path],
                    in: root, environment: env, timeout: 60)
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 120), .success)

        let text = try String(
            contentsOf: ProjectHandoff.fileURL(for: root.path), encoding: .utf8
        )
        XCTAssertEqual(
            text.split(separator: "\n").filter { $0.contains("the same task") }.count, 1,
            "the duplicate check has to hold under the lock too"
        )
    }
}
