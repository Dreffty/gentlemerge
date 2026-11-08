import GentleMergeCore
import GentleMergePorts
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension CLI {
    // MARK: - install

    static func install(_ arguments: [String]) -> Int32 {
        let paths = Paths.fromEnvironment()
        let installer = HookInstaller(paths: paths)
        let dryRun = isSet("--dry-run", in: arguments)
        let minimal = isSet("--minimal", in: arguments)
        let codex = isSet("--codex", in: arguments)

        var plan = HookInstaller.Plan()
        if minimal {
            plan.notifyEvents = ["Stop"]
        }

        do {
            let result = try installer.installClaudeCode(plan: plan, dryRun: dryRun)
            print("Claude Code (\(paths.claudeSettings.path)):")
            for note in result.notes { print("  • \(note)") }
            if let backup = result.backup {
                print("  backup: \(backup.path)")
            }

            if codex {
                try installCodex(installer: installer, paths: paths, dryRun: dryRun)
            }

            if !dryRun {
                print("\nRestart your agent sessions to pick up the hooks.")
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("install failed: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    static func installCodex(
        installer: HookInstaller,
        paths: Paths,
        dryRun: Bool
    ) throws {
        let configURL = paths.codexConfig
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            print("\nCodex: no config at \(configURL.path) — skipped.")
            return
        }

        let original = try String(contentsOf: configURL, encoding: .utf8)
        let (contents, found) = installer.codexConfigContents(
            original: original,
            scriptPath: paths.codexNotifyScript.path
        )
        // What the user had before us, even when this is the second install and
        // the file already points at our own bridge.
        let previous = installer.codexPreviousNotify(found: found)
        let script = installer.codexNotifyScript(chaining: previous)

        print("\nCodex (\(configURL.path)):")
        if previous.isEmpty {
            print("  • notify → \(paths.codexNotifyScript.lastPathComponent)")
        } else {
            print("  • notify → \(paths.codexNotifyScript.lastPathComponent)")
            print("    (chained after your existing \(previous[0]))")
        }

        guard !dryRun else {
            print("  (dry run — nothing written)")
            return
        }

        try installer.writeScripts()
        // Remembered so `uninstall` can put it back and a repeat install does
        // not take our own bridge for somebody else's program.
        if found.first?.contains(HookInstaller.codexMarker) != true {
            try installer.saveCodexPrevious(found)
        }
        try AtomicFile.write(Data(script.utf8), to: paths.codexNotifyScript)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: paths.codexNotifyScript.path
        )
        if let backup = try installer.backupIfPresent(configURL) {
            print("  backup: \(backup.path)")
        }
        try AtomicFile.write(Data(contents.utf8), to: configURL)
    }

    static func uninstall() -> Int32 {
        let paths = Paths.fromEnvironment()
        let installer = HookInstaller(paths: paths)
        do {
            let result = try installer.uninstallClaudeCode()
            for note in result.notes { print("  • \(note)") }
            if let backup = result.backup { print("  backup: \(backup.path)") }
            print(result.changed ? "Claude Code hooks removed." : "Nothing to remove.")
            let codex = try installer.uninstallCodex()
            for note in codex.notes { print("  • \(note)") }
            if let backup = codex.backup { print("  backup: \(backup.path)") }
            return 0
        } catch {
            FileHandle.standardError.write(Data("uninstall failed: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }
}
