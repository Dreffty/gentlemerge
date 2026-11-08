import GentleMergeCore
import GentleMergePorts
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension CLI {
    // MARK: - test

    /// Fires a synthetic event through the real hook script, so this exercises
    /// the same path a live agent takes.
    static func testEvent(_ arguments: [String]) -> Int32 {
        let paths = Paths.fromEnvironment()
        let installer = HookInstaller(paths: paths)
        let blocking = isSet("--blocking", in: arguments)
        // Refused rather than faked. The hook script has three modes — notify,
        // context and advise — and a fourth named `blocking` was passed here and
        // silently ignored, so `--blocking` produced an ordinary notify and then
        // reported success.
        //
        // It stays unimplemented on purpose: a blocking mode answers a
        // permission prompt on the agent's behalf, and "GentleMerge approving
        // tool calls on its own" is named in NudgeGate as precisely the failure
        // this project exists to avoid. So the flag says no.
        if blocking {
            FileHandle.standardError.write(Data("""
            test-event --blocking is not supported: the hook has no blocking mode.
            \nA blocking hook answers a permission prompt for the agent, which is exactly what this
            project refuses to do. Use `gentlemerge advise` to see what would be
            blocked before you commit, or the pre-commit gate to enforce it.

            """.utf8))
            return 64
        }

        do {
            try installer.writeScripts()
        } catch {
            FileHandle.standardError.write(Data("could not write hook script: \(error)\n".utf8))
            return 1
        }

        let payload: String
        payload = """
            {"session_id":"test-session","hook_event_name":"Notification",\
            "cwd":"\(FileManager.default.currentDirectoryPath)",\
            "message":"Claude needs your permission to use Bash"}
            """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            paths.hookScript.path,
            "--provider", "claude-code",
            // No `--timeout`: the script's argument loop discards it, so passing
            // one only looked like configuration.
            "--mode", "notify",
        ]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output

        do {
            try process.run()
        } catch {
            FileHandle.standardError.write(Data("could not run hook: \(error)\n".utf8))
            return 1
        }
        input.fileHandleForWriting.write(Data(payload.utf8))
        try? input.fileHandleForWriting.close()

        if blocking {
            print("Parked a permission request in the inbox. Answer it in the menu bar…")
        }
        let response = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let text = String(decoding: response, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            print(blocking
                ? "Hook returned nothing — the decision went back to the terminal."
                : "Event queued.")
        } else {
            print("Hook replied to the agent with:\n\(text)")
        }
        return 0
    }
}
