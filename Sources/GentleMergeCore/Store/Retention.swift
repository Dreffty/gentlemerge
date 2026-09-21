import Foundation

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

        public var lines: [String] {
            [
                "requests finished >7d ago: \(requests)",
                "watches lapsed or spent: \(watches)",
                "presence marks past TTL: \(presence)",
                "dispatch logs >retention: \(dispatch)",
                "processed spool files: \(processed)",
                "messages older than 7d / over 500: \(messages)",
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
        for name in names where name.hasSuffix(".log") || name.hasSuffix(".prompt.md") {
            let url = paths.dispatch.appendingPathComponent(name)
            let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
            guard let modified, modified < cutoff else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
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
            messages: AgentBus(paths: paths).pruneMessages(now: now)
        )
    }
}
