import XCTest
@testable import GentleMergeCore

final class CLIIdentityTests: XCTestCase {
    func testVerifiedCallerCannotUseAnotherIdentityBeforeSideEffects() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cli-identity-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GENTLEMERGE_BIN"] ?? ".build/debug/gentlemerge").standardizedFileURL.path
        let home = root.appendingPathComponent("home")
        for args in [["release", "--from", "other"], ["request", "accept", "req-missing", "--as", "other"],
                     ["presence", "--label", "other"], ["precommit", "--as", "other"], ["advise", "--from", "other"]] {
            let output = Shell.run(binary, args + ["--project", root.path], in: root,
                environment: ["GENTLEMERGE_HOME": home.path, "GENTLEMERGE_LABEL": "worker"])
            XCTAssertEqual(output.status, 1, args.joined(separator: " "))
            XCTAssertTrue(output.stderr.contains("refusing to speak as"), output.stdout + output.stderr)
            XCTAssertFalse(Presence.marks(paths: Paths(home: home)).contains { $0.label == "other" })
        }
    }

    func testVerifiedCallerCannotClaimAsAnotherAgent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cli-identity-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GENTLEMERGE_BIN"] ?? ".build/debug/gentlemerge").standardizedFileURL.path
        let output = Shell.run(binary, ["claim", "--paths", "Sources/**", "--from", "other", "--project", root.path], in: root,
            environment: ["GENTLEMERGE_HOME": root.appendingPathComponent("home").path, "GENTLEMERGE_LABEL": "worker"])
        XCTAssertEqual(output.status, 1)
        XCTAssertTrue(output.stderr.contains("refusing to speak as"), output.stdout + output.stderr)
    }
}
