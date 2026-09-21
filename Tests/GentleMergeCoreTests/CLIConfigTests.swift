import XCTest
@testable import GentleMergeCore

/// `config get/set` through the real binary: the knobs a human turns without
/// the app, validated before anything is written.
final class CLIConfigTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var binary: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cli-config-\(UUID())")
        home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        binary = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GENTLEMERGE_BIN"] ?? ".build/debug/gentlemerge").standardizedFileURL.path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func config(_ args: [String]) -> Shell.Output {
        Shell.run(binary, ["config"] + args, in: root,
            environment: ["GENTLEMERGE_HOME": home.path], timeout: 60)
    }

    func testSetAndGetRoundTrips() throws {
        XCTAssertEqual(config(["set", "dispatchMode", "strict"]).status, 0)
        XCTAssertEqual(config(["get", "dispatchMode"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines), "strict")
        XCTAssertEqual(AppConfig.load(from: Paths(home: home).config).dispatchMode, "strict")
        XCTAssertEqual(config(["set", "dispatchDailyBudgetMinutes", "45"]).status, 0)
        XCTAssertEqual(config(["get", "dispatchDailyBudgetMinutes"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines), "45")
    }

    func testInvalidValuesAreRefusedBeforeWriting() throws {
        XCTAssertEqual(config(["set", "dispatchMode", "turbo"]).status, 64)
        XCTAssertEqual(config(["set", "dispatchDailyBudgetMinutes", "-5"]).status, 64)
        XCTAssertEqual(config(["set", "nope", "1"]).status, 64)
        XCTAssertEqual(config(["get", "nope"]).status, 64)
        // Nothing was written: a refusal must not leave a half config behind.
        XCTAssertFalse(FileManager.default.fileExists(atPath: Paths(home: home).config.path))
    }
}
