import Foundation

/// Installs the gate hooks in the **effective** hooks directory of the
/// repository, so one install covers every worktree — the same rule
/// RepoIdentity applies to identity: the common dir is the one directory
/// every worktree shares.
///
/// Effective means `core.hooksPath` wins when it is set: if the repo uses
/// husky/lefthook, git ignores the common dir entirely and a hook installed
/// there would silently never run while the user believes they are
/// protected. A custom path inside the repo gets our hooks chained into it;
/// a path outside the repo (typically a global `~/.config/git/hooks`)
/// refuses loudly instead of hiding a repo gate where nobody looks.
///
/// Two gate hooks share one script: `pre-commit` (staged changes) and
/// `pre-merge-commit` (merge commits bypass `pre-commit`). A third hook,
/// `post-commit`, releases the committer's claims on what just landed and
/// can never block (git ignores its exit code; ours is 0 regardless).
public struct GitHookInstaller: Sendable {
    /// Bump when `script`/`postCommitScript` change: a reinstall replaces an
    /// outdated gate instead of leaving silent old behavior behind.
    public static let gateRevision = 2
    public static let marker = "# gentlemerge pre-commit (gate \(gateRevision))"
    public static let hookNames = ["pre-commit", "pre-merge-commit"]
    public static let postCommitMarker = "# gentlemerge post-commit (gate \(gateRevision))"
    /// Any gate we ever installed, current or outdated. Outdated ones are
    /// replaced, never chained — chaining is for foreign hooks.
    static let legacyMarkers = ["# gentlemerge pre-commit", "# gentlemerge post-commit"]
    public let paths: Paths
    public init(paths: Paths) { self.paths = paths }

    /// The gate binary this install resolves: the home's own bin link. Baked
    /// into the script when the home is not the default one, so a custom
    /// GENTLEMERGE_HOME install looks where `install` actually put the
    /// binary instead of a fixed path that was never filled.
    static func gateDefault(paths: Paths) -> String {
        let link = paths.bin.appendingPathComponent("gentlemerge").path
        let standard = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gentlemerge/bin/gentlemerge").path
        return link == standard ? "$HOME/.gentlemerge/bin/gentlemerge" : link
    }

    public static func script(gateDefault: String = "$HOME/.gentlemerge/bin/gentlemerge") -> String {
        """
        #!/bin/sh
        \(marker)
        # Enforces PathClaims / Ownership / request.mayTouch on staged files. Deterministic, zero tokens.
        # Escape hatch for humans: GENTLEMERGE_SKIP=1 git commit ...
        # (handled inside the binary so the skip is published on the bus, never silent)
        AI="${GENTLEMERGE_BIN:-\(gateDefault)}"
        if [ -x "$AI" ]; then
          "$AI" precommit --enforce --staged --project "$(git rev-parse --show-toplevel)" || exit 1
        else
          echo "gentlemerge: gate binary not found at $AI — this commit is NOT checked. Reinstall (gentlemerge install) or set GENTLEMERGE_BIN." >&2
        fi
        # Chain whatever was here before us (husky, lint-staged, ...).
        PREV="$0.gentlemerge-prev"
        [ -x "$PREV" ] && exec "$PREV" "$@"
        exit 0
        """
    }

    public static func postCommitScript(gateDefault: String = "$HOME/.gentlemerge/bin/gentlemerge") -> String {
        """
        #!/bin/sh
        \(postCommitMarker)
    # Releases my claims on what just landed. Never blocks, never fails: git
    # ignores a post-commit exit code, and this exits 0 regardless.
    [ -n "$GENTLEMERGE_SKIP" ] && exit 0
    AI="${GENTLEMERGE_BIN:-\(gateDefault)}"
    if [ -x "$AI" ]; then
      "$AI" postcommit --project "$(git rev-parse --show-toplevel)" >/dev/null 2>&1 || true
    else
      echo "gentlemerge: gate binary not found at $AI — claims on this commit are NOT released (they expire). Reinstall or set GENTLEMERGE_BIN." >&2
    fi
    # Chain whatever was here before us.
    PREV="$0.gentlemerge-prev"
    [ -x "$PREV" ] && exec "$PREV" "$@"
    exit 0
    """
    }

    public func hooksDir(for repo: URL) throws -> URL {
        let output = Shell.run(
            "/usr/bin/env",
            ["git", "rev-parse", "--git-common-dir"],
            in: repo,
            environment: ["GIT_OPTIONAL_LOCKS": "0"],
            timeout: 10
        )
        guard output.succeeded, let common = output.lines.first else {
            throw InstallError.notARepo(repo.path)
        }
        let base = common.hasPrefix("/")
            ? URL(fileURLWithPath: common)
            : repo.appendingPathComponent(common)
        return base.appendingPathComponent("hooks", isDirectory: true)
    }

    /// The raw `core.hooksPath` value, or nil when git falls back to the
    /// common dir. Empty counts as unset: an empty hooksPath protects nobody.
    public func configuredHooksPath(for repo: URL) -> String? {
        let output = Shell.run(
            "/usr/bin/env",
            ["git", "config", "core.hooksPath"],
            in: repo,
            environment: ["GIT_OPTIONAL_LOCKS": "0"],
            timeout: 10
        )
        guard output.succeeded, let line = output.lines.first, !line.isEmpty else { return nil }
        return line
    }

    private func toplevel(for repo: URL) throws -> URL {
        let output = Shell.run(
            "/usr/bin/env",
            ["git", "rev-parse", "--show-toplevel"],
            in: repo,
            environment: ["GIT_OPTIONAL_LOCKS": "0"],
            timeout: 10
        )
        guard output.succeeded, let top = output.lines.first else {
            throw InstallError.notARepo(repo.path)
        }
        return URL(fileURLWithPath: top)
    }

    /// Where the hooks must land, plus a human line when the answer is not
    /// the obvious one. Throws loudly on a hooksPath outside the repo: git
    /// would run our gate from a global directory for every repository, and
    /// a gate the user cannot see is worse than no gate.
    public func targetHooksDir(for repo: URL) throws -> (dir: URL, note: String?) {
        let classic = try hooksDir(for: repo)
        guard let configured = configuredHooksPath(for: repo) else { return (classic, nil) }
        let toplevel = try self.toplevel(for: repo)
        let custom = configured.hasPrefix("/")
            ? URL(fileURLWithPath: configured)
            : toplevel.appendingPathComponent(configured)
        let customPath = custom.standardizedFileURL.path
        if customPath == classic.standardizedFileURL.path { return (classic, nil) }
        let topPath = toplevel.standardizedFileURL.path
        guard customPath == topPath || customPath.hasPrefix(topPath + "/") else {
            throw InstallError.hooksPathOutsideRepo(path: customPath, configured: configured)
        }
        return (custom, "core.hooksPath=\(configured): installing into the hooks dir git actually uses")
    }

    public func install(repo: URL, dryRun: Bool = false) throws -> String {
        let (directory, note) = try targetHooksDir(for: repo)
        let gate = Self.gateDefault(paths: paths)
        let hooks: [(name: String, script: String, marker: String)] =
            Self.hookNames.map { ($0, Self.script(gateDefault: gate), Self.marker) }
            + [("post-commit", Self.postCommitScript(gateDefault: gate), Self.postCommitMarker)]
        if dryRun {
            for hook in hooks {
                let path = directory.appendingPathComponent(hook.name)
                if !((try? String(contentsOf: path))?.contains(hook.marker) ?? false) {
                    return "would install \(path.path)"
                }
            }
            return "already installed at \(directory.path)"
        }
        let fm = FileManager.default
        var fresh: [String] = []
        for hook in hooks {
            if try placeHook(name: hook.name, script: hook.script, marker: hook.marker, in: directory) {
                fresh.append(hook.name)
            }
        }
        // The hooks resolve the gate through this link. Without it they warn
        // on every commit but check nothing — so installing the gate installs
        // the link, not just the scripts.
        if !dryRun { Self.ensureBinaryLink(paths: paths) }
        let suffix = note.map { " (\($0))" } ?? ""
        if fresh.isEmpty { return "already installed at \(directory.path)" + suffix }
        return "installed \(fresh.joined(separator: " + ")) at \(directory.path)" + suffix
    }

    /// `<home>/bin/gentlemerge` pointing at this binary. Skipped when the
    /// current executable is not gentlemerge itself (tests, previews), so a
    /// test run never plants a bogus link in a real or fake home.
    @discardableResult
    public static func ensureBinaryLink(paths: Paths) -> Bool {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath(),
              executable.lastPathComponent == "gentlemerge" else { return false }
        let link = paths.bin.appendingPathComponent("gentlemerge")
        do {
            try FileManager.default.createDirectory(at: paths.bin, withIntermediateDirectories: true)
            if let existing = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path),
               URL(fileURLWithPath: existing).resolvingSymlinksInPath() == executable { return true }
            try? FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
            return true
        } catch {
            return false
        }
    }

    /// Places one hook, chaining a foreign predecessor. Returns whether the
    /// file is newly ours. Our own outdated gate is replaced, never chained:
    /// chaining it would keep the old behavior alive behind the new one.
    private func placeHook(name: String, script: String, marker: String, in directory: URL) throws -> Bool {
        let hook = directory.appendingPathComponent(name)
        if let existing = try? String(contentsOf: hook) {
            if existing.contains(marker) { return false }
            if Self.legacyMarkers.contains(where: existing.contains) {
                try? FileManager.default.removeItem(at: hook)
            }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: hook.path) {
            // Keep the foreign hook and chain it; never destroy someone else's
            // tooling — a hook we moved over would be husky silently disabled.
            try FileManager.default.moveItem(at: hook, to: hook.appendingPathExtension("gentlemerge-prev"))
        }
        try AtomicFile.write(Data(script.utf8), to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        return true
    }

    public func uninstall(repo: URL) throws -> String {
        let (directory, _) = try targetHooksDir(for: repo)
        let hooks: [(name: String, marker: String)] =
            Self.hookNames.map { ($0, Self.marker) } + [("post-commit", Self.postCommitMarker)]
        var removed = 0
        for hook in hooks {
            let path = directory.appendingPathComponent(hook.name)
            let previous = path.appendingPathExtension("gentlemerge-prev")
            guard let existing = try? String(contentsOf: path), existing.contains(hook.marker) else {
                continue
            }
            try FileManager.default.removeItem(at: path)
            if FileManager.default.fileExists(atPath: previous.path) {
                try FileManager.default.moveItem(at: previous, to: path)
            }
            removed += 1
        }
        return removed > 0 ? "removed" : "not ours; left alone"
    }
}
