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

    /// Tier 1 #5: the hook-resolved label travels in the envelope top level so
    /// implicit claims attribute to the worktree, not the provider default.
    func testHookEnvelopeCarriesTheResolvedLabel() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(Shell.run("/usr/bin/env", ["git", "init", "-q"], in: root).succeeded)
        _ = try WorktreeLabel.write(label: "hermes", in: root)
        let hook = root.appendingPathComponent("hook.sh")
        try HookScript.source.write(to: hook, atomically: true, encoding: .utf8)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = [hook.path, "--mode", "notify", "--provider", "claude-code"]
        child.currentDirectoryURL = root
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "GENTLEMERGE_LABEL")
        env["GENTLEMERGE_HOME"] = root.path
        env["CLAUDE_PROJECT_DIR"] = root.path
        child.environment = env
        let stdin = Pipe()
        child.standardInput = stdin
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        stdin.fileHandleForWriting.write(Data(#"{"hook_event_name":"Stop","session_id":"s1"}"#.utf8))
        try stdin.fileHandleForWriting.close()
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0)
        let spool = root.appendingPathComponent("spool")
        let files = (try? FileManager.default.contentsOfDirectory(at: spool, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" } ?? []
        XCTAssertEqual(files.count, 1, "hook must emit one envelope")
        let envelope = try JSONCoding.decoder().decode(
            SpoolEnvelope.self, from: Data(contentsOf: files[0]))
        XCTAssertEqual(envelope.label, "hermes", "envelope carries the resolved worktree label")
    }
}
