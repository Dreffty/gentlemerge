import Foundation

/// What the coordination costs, read off the ledger.
///
/// Every hook injection — full or delta, content or silence — is recorded as
/// `briefing.injected {session, mode, chars}`, so this is a count of what was
/// actually handed to agents, not a guess. Tokens are chars/4, said out loud
/// as an estimate everywhere the number appears.
public enum Stats {
    public struct Summary: Sendable, Equatable {
        /// Hook injections recorded.
        public var turns: Int
        /// Injections that carried something (chars > 0).
        public var nonEmpty: Int
        /// Characters handed out across all of them.
        public var chars: Int
        /// Characters handed out in full briefings.
        public var fullChars: Int

        public init(turns: Int = 0, nonEmpty: Int = 0, chars: Int = 0, fullChars: Int = 0) {
            self.turns = turns
            self.nonEmpty = nonEmpty
            self.chars = chars
            self.fullChars = fullChars
        }

        public var estTokens: Int { chars / 4 }
        public var avgPerTurn: Int { turns == 0 ? 0 : estTokens / turns }

        mutating func add(chars: Int, mode: String?) {
            turns += 1
            if chars > 0 { nonEmpty += 1 }
            self.chars += chars
            if mode == "full" { fullChars += chars }
        }
    }

    public static let eventTitle = "briefing.injected"

    /// Only what the aggregation reads. Decoding a whole LedgerEntry per line
    /// (dates included) dominated a full-ledger scan at ~1s per 20k lines;
    /// this skips everything but the four fields that matter.
    private struct Injection: Decodable {
        var title: String?
        var sessionID: String?
        var mode: String?
        var chars: Int?
    }

    private static let cacheLock = NSLock()
    /// Tuples cannot conform to Equatable, so the fingerprint is a struct.
    private struct Fingerprint: Sendable, Equatable {
        var size: UInt64
        var mtime: Date
    }
    // Guarded by cacheLock on every access (same pattern as Log.fileURL).
    nonisolated(unsafe) private static var cache: (hot: Fingerprint?, archive: Fingerprint?, total: Summary, bySession: [String: Summary])?

    /// The files a total covers: the hot ledger plus the archive when the
    /// prune has moved old lines there.
    static func ledgerFiles(paths: Paths) -> [URL] {
        var files = [paths.ledger]
        if FileManager.default.fileExists(atPath: paths.ledgerArchive.path) {
            files.append(paths.ledgerArchive)
        }
        return files
    }

    private static func fingerprint(_ url: URL) -> Fingerprint? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? UInt64,
              let mtime = attributes[.modificationDate] as? Date
        else { return nil }
        return Fingerprint(size: size, mtime: mtime)
    }

    /// Total plus per-session breakdowns in a single pass. Memoized on both
    /// files' size and modification date: the ledger is append-only and the
    /// archive barely moves, so unchanged fingerprints mean unchanged numbers,
    /// and the menu bar can ask every few seconds without re-scanning.
    public static func summaries(paths: Paths) -> (total: Summary, bySession: [String: Summary]) {
        let files = ledgerFiles(paths: paths)
        let hot = fingerprint(files[0])
        let archived = files.count > 1 ? fingerprint(files[1]) : nil

        cacheLock.lock()
        if let cache, cache.hot == hot, cache.archive == archived {
            let result = (cache.total, cache.bySession)
            cacheLock.unlock()
            return result
        }
        cacheLock.unlock()

        let computed = scan(files: files)
        cacheLock.lock()
        cache = (hot, archived, computed.total, computed.bySession)
        cacheLock.unlock()
        return computed
    }

    private static func scan(files: [URL]) -> (total: Summary, bySession: [String: Summary]) {
        var total = Summary()
        var bySession: [String: Summary] = [:]
        let decoder = JSONDecoder()
        for file in files {
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in contents.split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                      let entry = try? decoder.decode(Injection.self, from: data),
                      entry.title == eventTitle
                else { continue }
                let chars = entry.chars ?? 0
                total.add(chars: chars, mode: entry.mode)
                if let session = entry.sessionID {
                    var summary = bySession[session] ?? Summary()
                    summary.add(chars: chars, mode: entry.mode)
                    bySession[session] = summary
                }
            }
        }
        return (total, bySession)
    }

    /// Aggregate over the whole ledger, or one session's share of it. A line
    /// that does not decode, or an injection from before `{mode, chars}` were
    /// recorded, counts as an empty turn rather than breaking the total.
    public static func summary(paths: Paths, session: String? = nil) -> Summary {
        let computed = summaries(paths: paths)
        guard let session else { return computed.total }
        return computed.bySession[session] ?? Summary()
    }

    public static func summaryLine(paths: Paths) -> String {
        let s = summary(paths: paths)
        return "coordination cost: \(s.turns) briefings (\(s.nonEmpty) non-empty) · ≈ \(s.estTokens) tokens total · ≈ \(s.avgPerTurn) tokens/turn (estimate: chars/4)"
    }

    // MARK: - Value

    /// What the coordination saved, read off the same ledger as the cost: the
    /// skeptic's answer to "what does this do for me when everything works".
    /// Every count comes from lines the system already writes — no new
    /// bookkeeping, so old ledgers report value too.
    public struct Value: Sendable, Equatable {
        /// Commits the gate stopped (`precommit.blocked`).
        public var blockedCommits: Int = 0
        /// Violations named on those lines.
        public var violations: Int = 0
        /// Conflicts the radar announced early (`radar.conflict`).
        public var conflictsAnnounced: Int = 0
        /// Pre-edit warnings at the tool call (`advise`).
        public var preEditWarnings: Int = 0
        /// Dead sessions' claims cleared (`claim.reaped` lines).
        public var staleClaimsCleared: Int = 0
        /// Claims released because the work landed (`claim.released` paths
        /// plus `land.ok` claims).
        public var claimsReleased: Int = 0
        /// Branches brought home (`land.ok`).
        public var landings: Int = 0
    }

    private struct Note: Decodable {
        var title: String?
        var summary: String?
    }

    /// First integer before `word` in a summary ("3 violation(s)" → 3).
    /// Summaries are ours, but parsed forgivingly: an unfamiliar shape counts
    /// the line, not the number.
    static func count(before word: String, in summary: String?) -> Int {
        guard let summary,
              let range = summary.range(of: word),
              let number = summary[..<range.lowerBound].split(separator: " ").last.flatMap({ Int($0) })
        else { return 0 }
        return number
    }

    /// One pass over the hot ledger plus the archive. Uncached: this runs on
    /// an explicit command, never per turn.
    public static func value(paths: Paths) -> Value {
        var value = Value()
        let decoder = JSONDecoder()
        for file in ledgerFiles(paths: paths) {
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in contents.split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                      let entry = try? decoder.decode(Note.self, from: data)
                else { continue }
                switch entry.title {
                case "precommit.blocked":
                    value.blockedCommits += 1
                    value.violations += count(before: "violation", in: entry.summary)
                case "radar.conflict":
                    value.conflictsAnnounced += 1
                case "advise":
                    value.preEditWarnings += 1
                case "claim.reaped":
                    value.staleClaimsCleared += 1
                case "claim.released":
                    value.claimsReleased += count(before: "path", in: entry.summary)
                case "land.ok":
                    value.landings += 1
                    value.claimsReleased += count(before: "claim", in: entry.summary)
                default:
                    break
                }
            }
        }
        return value
    }

    public static func valueLine(paths: Paths) -> String {
        let v = value(paths: paths)
        guard v.blockedCommits + v.conflictsAnnounced + v.preEditWarnings
            + v.staleClaimsCleared + v.claimsReleased + v.landings > 0
        else {
            return "coordination value: nothing recorded yet — peace, or an uninstalled hook."
                + " `gentlemerge doctor` tells which."
        }
        return """
        coordination value (from the ledger):
          \(v.blockedCommits) commit(s) blocked before they could collide (\(v.violations) violation(s))
          \(v.conflictsAnnounced) conflict(s) announced early by the radar
          \(v.preEditWarnings) pre-edit warning(s) at the tool call
          \(v.staleClaimsCleared) dead session(s) cleared from claims
          \(v.claimsReleased) claim(s) released because the work landed · \(v.landings) landing(s)
        """
    }
}
