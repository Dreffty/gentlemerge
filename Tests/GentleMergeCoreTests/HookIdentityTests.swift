import Foundation
import XCTest
@testable import GentleMergeCore

final class HookIdentityTests: XCTestCase {
    func testHookExportsWorktreeIdentityToContextChild() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        XCTAssertTrue(Shell.run("/usr/bin/env", ["git", "init", "-q"], in: root).succeeded)
        _ = try WorktreeLabel.write(label: "hook-agent", in: root)
        let recorder = bin.appendingPathComponent("gentlemerge")
        try "#!/bin/sh\nprintf '%s' \"${GENTLEMERGE_LABEL:-missing}\" > \"$GENTLEMERGE_HOME/observed-label\"\n".write(to: recorder, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: recorder.path)
        let hook = root.appendingPathComponent("hook.sh")
        try HookScript.source.write(to: hook, atomically: true, encoding: .utf8)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = [hook.path, "--mode", "context", "--provider", "claude-code"]
        child.currentDirectoryURL = root
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "GENTLEMERGE_LABEL")
        env["GENTLEMERGE_HOME"] = root.path
        env["CLAUDE_PROJECT_DIR"] = root.path
        child.environment = env
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("observed-label"), encoding: .utf8), "hook-agent")
    }
}
