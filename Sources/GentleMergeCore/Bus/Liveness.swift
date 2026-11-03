import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Whether the process behind a session is still there.
///
/// An agent that falls over — a 529, a session limit, a `kill -9` — never gets
/// to say goodbye, so the last thing it wrote about itself is "working". Asking
/// the kernel is the only way to find out that it lied.
public enum Liveness {
    /// `nil` means we do not know, and callers must never read that as dead:
    /// every activity written before we started keeping pids has none, and some
    /// agents' hooks will never report one.
    ///
    /// `kill(pid, 0)` sends no signal; it only asks whether a process with that
    /// id exists and whether we may signal it. `EPERM` is a yes — it exists and
    /// belongs to somebody else.
    ///
    /// The system reuses pids, and after a restart it hands out the same low
    /// numbers again: the pid of a session that died with the machine soon
    /// belongs to some other program, which answered "alive" and kept the dead
    /// session in every briefing until its mark expired (audit 2026-11-03).
    /// `seenAt` — when the pid was last reported by its session — settles it:
    /// a process that started after that moment is not the one that reported.
    /// A minute of slack, so a clock nudged by NTP never buries a live agent.
    public static func isProcessAlive(_ pid: Int?, seenAt: Date? = nil) -> Bool? {
        // Nothing above the pid_t range was ever a pid; the conversion would
        // trap rather than tell us so.
        guard let pid, pid > 0, pid <= Int(pid_t.max) else { return nil }
        guard kill(pid_t(pid), 0) == 0 || errno == EPERM else { return false }
        if let seenAt, let started = startTime(of: pid_t(pid)),
           started > seenAt.addingTimeInterval(60) {
            return false
        }
        return true
    }

    /// When the process with this pid started, or nil when the system will
    /// not say. One sysctl (macOS) or two small reads of /proc (Linux).
    static func startTime(of pid: pid_t) -> Date? {
        #if canImport(Darwin)
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        guard start.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
        #else
        // Field 22 of /proc/<pid>/stat is the start in clock ticks after boot;
        // the name before it is in parentheses and may hold spaces.
        guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let close = stat.lastIndex(of: ")") else { return nil }
        let fields = stat[stat.index(after: close)...].split(separator: " ")
        guard fields.count > 19, let ticks = Double(fields[19]) else { return nil }
        let hertz = Double(sysconf(Int32(_SC_CLK_TCK)))
        guard hertz > 0,
              let system = try? String(contentsOfFile: "/proc/stat", encoding: .utf8),
              let line = system.split(separator: "\n").first(where: { $0.hasPrefix("btime ") }),
              let boot = Double(line.dropFirst(6).trimmingCharacters(in: .whitespaces)) else { return nil }
        return Date(timeIntervalSince1970: boot + ticks / hertz)
        #endif
    }
}
