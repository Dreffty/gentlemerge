import Foundation

/// The binary that is running right now, as a path.
///
/// `CommandLine.arguments[0]` is *not* that. It is whatever the shell put in
/// argv[0], which for a command found on `$PATH` is the bare word you typed —
/// `gentlemerge`, not `/usr/local/bin/gentlemerge`. Turning it into a URL gives
/// `<cwd>/gentlemerge`, which does not exist, so anything that hands this path
/// to a subprocess gets "not found" and quietly does nothing.
///
/// That is exactly what happened to `gentlemerge demo`: it installs its gate
/// hooks with `GENTLEMERGE_BIN` taken from argv[0], every commit then printed
/// "gate binary not found … this commit is NOT checked" and passed unchecked,
/// and the demo's own headline step reported `commit ok` where the README
/// advertises `commit BLOCKED` (audit 2026-10-08). `Bundle.main` is the honest
/// answer and is already what `GitHookInstaller.ensureBinaryLink` uses.
public enum CurrentExecutable {
    public static var url: URL {
        if let executable = Bundle.main.executableURL { return executable }
        // A host that has no bundle (a `swift run`-style launcher, some test
        // runners) still has a plausible argv[0] — so fall back to it only
        // when there is nothing better, and only when it looks like a path.
        let raw = CommandLine.arguments.first ?? "gentlemerge"
        if raw.contains("/") { return URL(fileURLWithPath: raw).standardizedFileURL }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(raw)
    }
}
