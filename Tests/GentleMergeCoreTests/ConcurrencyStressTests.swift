import XCTest
@testable import GentleMergeCore

/// Several processes hitting the same home at once: the domain of this
/// project is concurrent file access, and forty sequential unit tests do not
/// protect it. Workers are real `gentlemerge` processes (separate pids,
/// separate file descriptors), each saying and claiming in a loop; the
/// invariants afterwards are: no message lost, no corrupt JSON line, no lost
/// claim rewrite, no double bus delivery.
///
/// Bounded to seconds. The full thirty-second soak with the same invariants
/// lives in Scripts/stress-test.sh (runnable on mac and Linux).
final class ConcurrencyStressTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var binary: String!

    private let workers = 6
    private let rounds = 15

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("concurrency-\(UUID())")
        home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        binary = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GENTLEMERGE_BIN"] ?? ".build/debug/gentlemerge").standardizedFileURL.path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func run(_ args: [String], label: String, extraEnv: [String: String] = [:]) -> Shell.Output {
        var env = ["GENTLEMERGE_HOME": home.path, "GENTLEMERGE_LABEL": label]
        for (key, value) in extraEnv { env[key] = value }
        return Shell.run(binary, args + ["--project", root.path], in: root, environment: env, timeout: 60)
    }

    /// N processes × K `say` each, all at once.
    func testConcurrentSaysLoseNothingAndCorruptNothing() throws {
        // Locals, not self: the async closure is @Sendable and XCTestCase is not.
        let binary: String = self.binary, home: URL = self.home, root: URL = self.root
        let workers = self.workers, rounds = self.rounds
        let group = DispatchGroup()
        for w in 0..<workers {
            group.enter()
            DispatchQueue.global().async {
                for k in 0..<rounds {
                    let env = ["GENTLEMERGE_HOME": home.path, "GENTLEMERGE_LABEL": "worker-\(w)"]
                    _ = Shell.run(binary, ["say", "note w\(w)-\(k)", "--project", root.path],
                        in: root, environment: env, timeout: 60)
                }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 300), .success)

        let url = Paths(home: home).messages
        let contents = try String(contentsOf: url, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, workers * rounds, "every say must land")
        let decoder = JSONCoding.decoder()
        var texts: [String] = []
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let message = try? decoder.decode(AgentMessage.self, from: data)
            else {
                return XCTFail("corrupt JSON line in messages.jsonl: \(line.prefix(120))")
            }
            texts.append(message.text)
        }
        for w in 0..<workers {
            for k in 0..<rounds {
                XCTAssertTrue(texts.contains("note w\(w)-\(k)"), "lost w\(w)-\(k)")
            }
        }
    }

    /// N processes claiming disjoint patterns: no rewrite may lose another
    /// worker's claim.
    func testConcurrentClaimsKeepEveryWorker() throws {
        let binary: String = self.binary, home: URL = self.home, root: URL = self.root
        let workers = self.workers
        let group = DispatchGroup()
        for w in 0..<workers {
            group.enter()
            DispatchQueue.global().async {
                let env = ["GENTLEMERGE_HOME": home.path, "GENTLEMERGE_LABEL": "worker-\(w)"]
                _ = Shell.run(binary, ["claim", "--paths", "mod-\(w)/**", "--project", root.path],
                    in: root, environment: env, timeout: 60)
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 120), .success)

        let live = PathClaims(paths: Paths(home: home)).live(project: root.path)
        for w in 0..<workers {
            XCTAssertTrue(live.contains { $0.label == "worker-\(w)" && $0.pattern == "mod-\(w)/**" },
                "lost worker-\(w)'s claim")
        }
    }

    /// Two processes racing for the same pattern: exactly one holds it.
    func testARacingClaimHasExactlyOneWinner() throws {
        let binary: String = self.binary, home: URL = self.home, root: URL = self.root
        let group = DispatchGroup()
        for w in 0..<2 {
            group.enter()
            DispatchQueue.global().async {
                let env = ["GENTLEMERGE_HOME": home.path, "GENTLEMERGE_LABEL": "racer-\(w)"]
                _ = Shell.run(binary, ["claim", "--paths", "prize/**", "--project", root.path],
                    in: root, environment: env, timeout: 60)
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 120), .success)

        let holders = PathClaims(paths: pathsForHome()).live(project: root.path)
            .filter { $0.pattern == "prize/**" }
        XCTAssertEqual(holders.count, 1, "a double claim is a protection that lied")
    }

    private func pathsForHome() -> Paths { Paths(home: home) }

    /// Two readers, one bus: each sees everything once, and a second read
    /// shows nothing twice.
    func testTwoReadersShareNothingAndLoseNothing() throws {
        for k in 0..<5 {
            _ = run(["say", "shared \(k)"], label: "writer")
        }
        let first1 = run(["brief", "--as", "r1"], label: "r1").stdout
        let first2 = run(["brief", "--as", "r2"], label: "r2").stdout
        for k in 0..<5 {
            XCTAssertTrue(first1.contains("shared \(k)"), "r1 lost \(k)")
            XCTAssertTrue(first2.contains("shared \(k)"), "r2 lost \(k)")
        }
        let second1 = run(["brief", "--as", "r1"], label: "r1").stdout
        let second2 = run(["brief", "--as", "r2"], label: "r2").stdout
        for k in 0..<5 {
            XCTAssertFalse(second1.contains("shared \(k)"), "r1 double-delivered \(k)")
            XCTAssertFalse(second2.contains("shared \(k)"), "r2 double-delivered \(k)")
        }
    }
}
