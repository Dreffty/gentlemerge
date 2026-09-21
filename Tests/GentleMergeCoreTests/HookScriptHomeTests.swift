import XCTest
@testable import GentleMergeCore

final class HookScriptHomeTests: XCTestCase {
    // Execute the unmodified generated hook, checking its spool and child lookup.
    private func checkHome(xdg: String?, explicit: Bool, usesXDG: Bool,
                           file: StaticString = #filePath, line: UInt = #line) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let state = root.appendingPathComponent("state with spaces")
        let expected = explicit ? root.appendingPathComponent("override")
            : usesXDG ? state.appendingPathComponent("gentlemerge") : home.appendingPathComponent(".gentlemerge")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: expected.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let hook = root.appendingPathComponent("hook.sh")
        try HookScript.source.write(to: hook, atomically: true, encoding: .utf8)
        let child = expected.appendingPathComponent("bin/gentlemerge")
        // Fixture proves context and advice locate the CLI in the selected inbox.
        try "#!/bin/sh\nprintf 'child:%s' \"$1\"\n".write(to: child, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: child.path)
        var env = ["PATH": "/usr/bin:/bin", "HOME": home.path, "CLAUDE_PROJECT_DIR": root.path]
        if let xdg { env["XDG_STATE_HOME"] = xdg == "absolute" ? state.path : xdg }
        if explicit { env["GENTLEMERGE_HOME"] = expected.path }
        for mode in ["context", "advise"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [hook.path, "--provider", "claude-code", "--mode", mode]
            process.environment = env
            process.currentDirectoryURL = root
            process.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, file: file, line: line)
            XCTAssertEqual(String(decoding: data, as: UTF8.self),
                           "child:\(mode == "context" ? "session-context" : "advise")", file: file, line: line)
        }
        let envelopes = (try? FileManager.default.contentsOfDirectory(at: expected.appendingPathComponent("spool"), includingPropertiesForKeys: nil)) ?? []
        XCTAssertEqual(envelopes.filter { $0.pathExtension == "json" }.count, 2, file: file, line: line)
        if usesXDG || explicit {
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".gentlemerge/spool").path), file: file, line: line)
        }
    }

    func testExplicitHomeWinsOverXDG() throws {
        try checkHome(xdg: "absolute", explicit: true, usesXDG: false)
    }
    func testEmptyExplicitHomeFallsBack() throws {
        try checkHome(xdg: nil, explicit: false, usesXDG: false)
    }
    #if os(Linux)
    func testLinuxHookFollowsXDGStateHome() throws {
        try checkHome(xdg: "absolute", explicit: false, usesXDG: true)
    }
    func testLinuxHookIgnoresRelativeXDGStateHome() throws {
        try checkHome(xdg: "relative", explicit: false, usesXDG: false)
    }
    #else
    func testMacHookIgnoresXDGStateHome() throws {
        try checkHome(xdg: "absolute", explicit: false, usesXDG: false)
    }
    #endif
}
