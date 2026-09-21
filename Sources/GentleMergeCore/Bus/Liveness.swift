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
    /// Caveat we accept: the system reuses pids, so a long-dead session's pid
    /// could belong to an unrelated process and read as alive. Wrapping the pid
    /// space takes far longer than the hours a session lives, and the cost of
    /// being wrong is one stale line in a briefing. Pinning the identity would
    /// mean storing the process start time and reading it back through sysctl
    /// on every probe — a real cost on every turn of every agent, against a
    /// failure nobody has seen.
    public static func isProcessAlive(_ pid: Int?) -> Bool? {
        // Nothing above the pid_t range was ever a pid; the conversion would
        // trap rather than tell us so.
        guard let pid, pid > 0, pid <= Int(pid_t.max) else { return nil }
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }
}
