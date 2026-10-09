import XCTest
@testable import GentleMergeCore

/// #12 — `Shell.run` started two reader `Thread`s *before* `process.run()`, and
/// returned without waiting for them when the spawn failed. The handoff claimed
/// they leaked permanently. They do not: when the function returns, the local
/// `Process` is released, Foundation closes the pipe write ends it held, and the
/// blocked `readDataToEndOfFile` calls see EOF and exit. So this is a *transient*
/// spike, not a leak.
///
/// That distinction matters, because the obvious fix — closing the read handles
/// to unblock the readers immediately — is actively harmful: closing a
/// `FileHandle` another thread is reading raises `NSFileHandleOperationException`
/// on that thread, turning a bounded spike into a crash. The fix that shipped is
/// instead "start the readers once the spawn succeeds".
///
/// This asserts the *contract* of that fix rather than the thread count. There
/// was a Mach-based thread counter here; it needed `mach_task_self_`, a mutable
/// C global that the Swift 6.0 toolchain the CI runs imports as plain shared
/// mutable state (it does not carry the newer SDK's `__swift_nonisolated_unsafe`
/// annotation through), so the file failed to compile there — and no spelling of
/// the escape hatch silenced it on that toolchain. A diagnostic that cannot
/// build on CI is worth less than a portable one, so what is asserted now is the
/// observable consequence: a failed spawn is reported, does not hang, and leaves
/// the process able to spawn again.
final class ShellSpawnFailureTests: XCTestCase {
    /// 200 failed spawns in a row — far past the 60 that exposed the spike.
    private let failedSpawns = 200

    /// A failed spawn reports through the return value rather than throwing,
    /// with a reason, and within its timeout.
    func testAFailedSpawnReportsRatherThanThrows() {
        let output = Shell.run("/nonexistent/definitely-not-here", ["--version"], timeout: 5)
        XCTAssertEqual(output.status, 127)
        XCTAssertFalse(output.timedOut)
        XCTAssertTrue(
            output.stderr.contains("could not run") || output.stderr.contains("No such file"),
            "the caller must be told why: \(output.stderr)"
        )
    }

    /// A path that exists but cannot be executed — a different failure mode from
    /// "missing" — is handled the same way and does not hang either.
    func testAFailedSpawnOfADirectoryIsAlsoHandled() {
        let output = Shell.run(NSTemporaryDirectory(), [], timeout: 5)
        XCTAssertNotEqual(output.status, 0)
        XCTAssertFalse(output.timedOut)
    }

    /// The spike is transient: after `failedSpawns` of them, the process still
    /// spawns and still reads a command's output. If the reader threads (or
    /// their pipes) were held by the failed process, this is what would break.
    func testFailedSpawnsDoNotStopLaterOnesWorking() throws {
        for _ in 0..<failedSpawns {
            _ = Shell.run("/nonexistent/definitely-not-here", ["--version"], timeout: 5)
        }
        // Long enough for a released Process's write ends to close and any
        // blocked reader to unwind — if it unwinds at all.
        Thread.sleep(forTimeInterval: 1.5)

        let output = Shell.run("/bin/sh", ["-c", "echo still-alive"], timeout: 10)
        XCTAssertFalse(output.timedOut, "a successful spawn hung after \(failedSpawns) failures")
        XCTAssertEqual(output.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "still-alive")
    }

    /// A failed spawn stays bounded: many in a row must not cost more than the
    /// sum of their timeouts would allow. A reader that never returns would.
    func testManyFailedSpawnsStayBounded() throws {
        let started = Date()
        for _ in 0..<failedSpawns {
            _ = Shell.run("/nonexistent/definitely-not-here", ["--version"], timeout: 5)
        }
        // Each failed spawn returns as soon as the kernel refuses it; the 5s
        // timeout is the ceiling for one of them, so 200 of them have no excuse
        // for taking a minute.
        XCTAssertLessThan(Date().timeIntervalSince(started), 60,
                          "\(failedSpawns) failed spawns took \(Date().timeIntervalSince(started))s — something is not returning")
    }
}
