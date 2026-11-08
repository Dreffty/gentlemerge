import XCTest
@testable import GentleMergeCore

/// A test with a fake `HOME` must never reach the real one.
///
/// `claudeSettings` and `codexConfig` asked macOS for the user's home, which ignores
/// `$HOME`: `HOME=/tmp/x gentlemerge install` rewrote the real `~/.claude/settings.json`
/// (it happened on 2026-10-31). Checked on the paths alone, so that a regression
/// cannot do it again while the test runs.
final class FakeHomeTests: XCTestCase {
    func testSettingsFollowHome() {
        let paths = Paths.fromEnvironment(["HOME": "/tmp/fake-home"])
        XCTAssertEqual(paths.claudeSettings.path, "/tmp/fake-home/.claude/settings.json")
        XCTAssertEqual(paths.codexConfig.path, "/tmp/fake-home/.codex/config.toml")
    }

    func testTheStateHomeFollowsHomeToo() {
        XCTAssertEqual(Paths.fromEnvironment(["HOME": "/tmp/fake-home"]).home.path, "/tmp/fake-home/.gentlemerge")
    }

    func testExplicitOverridesStillWin() {
        let paths = Paths.fromEnvironment(["HOME": "/tmp/fake-home", "GENTLEMERGE_CLAUDE_SETTINGS": "/tmp/s.json",
                                           "GENTLEMERGE_CODEX_CONFIG": "/tmp/c.toml", "GENTLEMERGE_HOME": "/tmp/gm"])
        XCTAssertEqual(paths.claudeSettings.path, "/tmp/s.json")
        XCTAssertEqual(paths.codexConfig.path, "/tmp/c.toml")
        XCTAssertEqual(paths.home.path, "/tmp/gm")
    }

    func testAnEmptyHomeFallsBackToTheAccount() {
        let account = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(Paths.fromEnvironment(["HOME": ""]).claudeSettings.path, account + "/.claude/settings.json")
    }

    /// The same mistake through the binary, with nothing written: `--dry-run` only
    /// names the file it would change.
    func testInstallNamesTheFakeHomesSettings() throws {
        let binary = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GENTLEMERGE_BIN"] ?? ".build/debug/gentlemerge")
            .standardizedFileURL.path
        let fake = FileManager.default.temporaryDirectory.appendingPathComponent("fake-home-\(UUID())")
        try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fake) }
        var environment = ProcessInfo.processInfo.environment
        for key in ["GENTLEMERGE_HOME", "GENTLEMERGE_CLAUDE_SETTINGS", "GENTLEMERGE_CODEX_CONFIG"] {
            environment.removeValue(forKey: key)
        }
        environment["HOME"] = fake.path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["install", "--dry-run"]
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertTrue(output.contains(fake.path + "/.claude/settings.json"), output)
    }
}
