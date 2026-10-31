import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Deep clean for a home the app has not opened in months: finished requests,
/// lapsed watches, stale presence, old dispatch logs, the processed spool,
/// and a ledger archive pass. The hot paths (messages, live claims) are
/// touched only by the app's own tick; this is the manual and headless
/// counterpart — `gentlemerge compact` — with a report of what went away.
///
/// Everything here deletes only what no reader will miss: terminal requests
/// past their week, marks past their TTL, logs past `retentionDays`. Readers
/// stay forgiving per 2.4, so an old binary sharing the home never trips on
/// a file this removed.
public enum Retention {
    public struct Report: Sendable, Equatable {
        public var requests: Int
        public var watches: Int
        public var presence: Int
        public var dispatch: Int
        public var processed: Int
        public var messages: Int
        public var locks: Int = 0

        public var lines: [String] {
            [
                "requests finished >7d ago: \(requests)",
                "watches lapsed or spent: \(watches)",
                "presence marks past TTL: \(presence)",
                "dispatch logs >retention: \(dispatch)",
                "processed spool files: \(processed)",
                "messages older than 7d / over 500: \(messages)",
                "idle lock files: \(locks)",
            ]
        }
    }

    /// Dispatch leaves a prompt file and a log per delegated request, and
    /// nothing ever collected them. Past `retentionDays` they are debugging
    /// archaeology. Returns files removed.
    @discardableResult
    public static func pruneDispatch(paths: Paths, olderThanDays days: Int, now: Date = Date()) -> Int {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: paths.dispatch.path) else { return 0 }
        var removed = 0
        for name in names where name.hasSuffix(".log") || name.hasSuffix(".prompt.md") || name.hasSuffix(".started") {
            let url = paths.dispatch.appendingPathComponent(name)
            let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
            guard let modified, modified < cutoff else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    /// The empty `*.lock` sidecars that `flock` needs. Nothing ever removed them: one
    /// `handoff-<hash>.lock` per project path ever touched, and one per delivery
    /// marker — 866 files in a home a few weeks old. They are recreated on demand, so
    /// an idle one is only clutter; one that somebody holds right now is left alone
    /// (the non-blocking lock below fails), and so is one touched in the last day.
    @discardableResult
    public static func pruneLocks(paths: Paths, olderThan interval: TimeInterval = 86_400, now: Date = Date()) -> Int {
        let cutoff = now.addingTimeInterval(-interval)
        var removed = 0
        for directory in [paths.home, paths.delivered] {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { continue }
            for name in names where name.hasSuffix(".lock") {
                let url = directory.appendingPathComponent(name)
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                      (attributes[.size] as? UInt64 ?? 1) == 0,
                      let modified = attributes[.modificationDate] as? Date, modified < cutoff
                else { continue }
                let descriptor = open(url.path, O_RDONLY)
                guard descriptor >= 0 else { continue }
                defer { close(descriptor) }
                guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { continue }   // held right now
                if (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
                flock(descriptor, LOCK_UN)
            }
        }
        return removed
    }

    public static func compact(paths: Paths, config: AppConfig = AppConfig(), now: Date = Date()) -> Report {
        let requests = Requests(paths: paths)
        let requestsBefore = requests.all().count
        requests.prune()
        let watches = Watches(paths: paths)
        let watchesBefore = watches.all().count
        _ = try? watches.compact(now: now)
        let processedBefore = ((try? FileManager.default.contentsOfDirectory(atPath: paths.processed.path)) ?? []).count
        SpoolStore(paths: paths).prune(olderThan: Double(config.retentionDays) * 86_400)
        let processedAfter = ((try? FileManager.default.contentsOfDirectory(atPath: paths.processed.path)) ?? []).count
        return Report(
            requests: max(requestsBefore - requests.all().count, 0),
            watches: max(watchesBefore - watches.all().count, 0),
            presence: Presence.prune(paths: paths, now: now),
            dispatch: pruneDispatch(paths: paths, olderThanDays: config.retentionDays, now: now),
            processed: max(processedBefore - processedAfter, 0),
            messages: AgentBus(paths: paths).pruneMessages(now: now),
            locks: pruneLocks(paths: paths, now: now)
        )
    }
}
