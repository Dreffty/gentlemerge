import Foundation

/// Every path the app touches. `GENTLEMERGE_HOME` redirects the whole tree,
/// which is what tests and dry runs use so nothing escapes into the real home.
public struct Paths: Sendable {
    public let home: URL
    private let claudeSettingsOverride: URL?
    private let codexConfigOverride: URL?

    public init(home: URL, claudeSettings: URL? = nil, codexConfig: URL? = nil) {
        self.home = home
        self.claudeSettingsOverride = claudeSettings
        self.codexConfigOverride = codexConfig
    }

    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Paths {
        func url(_ key: String) -> URL? {
            guard let value = environment[key], !value.isEmpty else { return nil }
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
        }

        #if os(Linux)
        let platformHome = environment["XDG_STATE_HOME"].flatMap { value -> URL? in
            guard value.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: value).appendingPathComponent("gentlemerge", isDirectory: true)
        }
        #else
        let platformHome: URL? = nil
        #endif
        let home = url("GENTLEMERGE_HOME") ?? platformHome
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".gentlemerge", isDirectory: true)

        return Paths(
            home: home,
            claudeSettings: url("GENTLEMERGE_CLAUDE_SETTINGS"),
            codexConfig: url("GENTLEMERGE_CODEX_CONFIG")
        )
    }

    /// Envelopes dropped by hook scripts, waiting to be ingested.
    public var spool: URL { home.appendingPathComponent("spool", isDirectory: true) }
    /// Verbatim stdout for a blocking hook to replay, one file per request id.
    public var answers: URL { home.appendingPathComponent("answers", isDirectory: true) }
    /// Envelopes already ingested; kept briefly so a crash is debuggable.
    public var processed: URL { home.appendingPathComponent("processed", isDirectory: true) }
    /// Installed copies of the hook scripts, referenced from agent configs.
    public var bin: URL { home.appendingPathComponent("bin", isDirectory: true) }
    public var backups: URL { home.appendingPathComponent("backups", isDirectory: true) }

    public var ledger: URL { home.appendingPathComponent("ledger.jsonl") }
    /// Where Ledger.archive moves lines older than the window. Same shape,
    /// read by Stats alongside the hot file, so totals survive the move.
    public var ledgerArchive: URL { home.appendingPathComponent("ledger.archive.jsonl") }
    public var state: URL { home.appendingPathComponent("state.json") }
    public var config: URL { home.appendingPathComponent("config.json") }
    public var policy: URL { home.appendingPathComponent("policy.json") }
    public var sessions: URL { home.appendingPathComponent("sessions.json") }
    public var projects: URL { home.appendingPathComponent("projects.json") }
    /// What every live agent session is doing, written by the app.
    public var activities: URL { home.appendingPathComponent("activities.json") }
    /// Notes agents leave each other, append-only.
    public var messages: URL { home.appendingPathComponent("messages.jsonl") }
    /// Who is on which task, across every project. Kept here and not in the
    /// projects' own handoff files: a claim is coordination that goes stale in
    /// hours, not something worth committing next to the task list.
    public var claims: URL { home.appendingPathComponent("claims.json") }
    /// "Tell me when X happens": one line per rule, append-only, and only the
    /// app ever rewrites it. Absent means nobody asked for anything, which is
    /// what every install that predates watches has.
    public var watches: URL { home.appendingPathComponent("watches.jsonl") }
    /// Files agents left each other, one directory per distinct content. Made
    /// on the first `say --attach` and swept by the prune, so an install where
    /// nobody attaches anything never grows one.
    public var artifacts: URL { home.appendingPathComponent("artifacts", isDirectory: true) }
    /// One marker per session, written only by that session's own hook.
    public var delivered: URL { home.appendingPathComponent("delivered", isDirectory: true) }
    /// One mark per working agent, written only by that agent. The same
    /// one-writer-per-file shape as `delivered`, and for the same reason: it
    /// lets an agent say "I am here" without contending with the app for
    /// `activities.json`.
    public var presence: URL { home.appendingPathComponent("presence", isDirectory: true) }
    /// "I am editing these paths." One JSON array, several processes may
    /// read-modify-write it — hooks for the explicit claims, the app for the
    /// implicit ones — so every write goes through the sidecar lock.
    public var pathClaims: URL { home.appendingPathComponent("claims-paths.json") }
    /// When the conflict radar last swept each project, and which
    /// branch-pair signatures it already announced. Absent means it never ran,
    /// which is what every install that predates the radar has.
    public var radar: URL { home.appendingPathComponent("radar.json") }
    /// One file per delegated request. Created on the first `delegate`, so an
    /// install where nobody delegates anything never grows one.
    public var dispatch: URL { home.appendingPathComponent("dispatch", isDirectory: true) }
    public var requests: URL { home.appendingPathComponent("requests", isDirectory: true) }
    /// One file per finished review, newest kept.
    public var reviews: URL { home.appendingPathComponent("reviews", isDirectory: true) }
    public var log: URL { home.appendingPathComponent("gentlemerge.log") }
    /// Present and alive means the menu bar is there to answer parked hooks.
    public var appPID: URL { home.appendingPathComponent("app.pid") }

    public var hookScript: URL { bin.appendingPathComponent("gentlemerge-hook.sh") }
    public var codexNotifyScript: URL { bin.appendingPathComponent("gentlemerge-codex-notify.sh") }

    public var claudeSettings: URL {
        claudeSettingsOverride
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/settings.json")
    }

    public var codexConfig: URL {
        codexConfigOverride
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/config.toml")
    }

    @discardableResult
    public func createDirectories() throws -> Paths {
        for directory in [home, spool, answers, processed, bin, backups, reviews, delivered, presence, requests] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        // The home holds scrubbed-but-sensitive coordination state (ledger,
        // presence, tasks). Other users on a shared machine get nothing.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
        return self
    }
}
