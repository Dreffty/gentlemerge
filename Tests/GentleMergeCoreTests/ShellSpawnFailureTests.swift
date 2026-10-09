import XCTest
#if canImport(Darwin)
import Darwin
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
/// on that thread, turning a bounded spike into a crash.
final class ShellSpawnFailureTests: XCTestCase {
    /// The task port, read once into a constant the concurrency checker has been
    /// told not to police.
    ///
    /// `mach_task_self_` is a mutable C global. Newer SDKs mark it
    /// `__swift_nonisolated_unsafe`; the Swift 6.0 toolchain the CI runs does not
    /// carry that annotation through the older macOS SDK it imports, so it arrives
    /// as plain shared mutable state and referencing it from an isolated context
    /// is an error there. Reading it through a `nonisolated(unsafe)` constant and
    /// a `nonisolated` reader is the escape hatch: this value never changes for
    /// the life of the process, which is literally what `unsafe` asserts.
    private nonisolated(unsafe) static let machTask = mach_task_self_

    /// Total live threads in this process.
    ///
    /// Not filtered by name: `task_threads` yields mach port names, which are
    /// not `pthread_t`s, so reading names back would need a conversion this test
    /// does not justify. A permanent leak of 60 failed spawns would be 120
    /// threads, which no amount of background noise can hide behind.
    ///
    /// `nonisolated` because the value it reads is free function state, not
    /// actor state: XCTest isolates test methods, and forcing the read through
    /// that actor is what the CI toolchain refuses.
    nonisolated private func readerThreadCount() -> Int {
        var list: thread_act_array_t?
        var count = mach_msg_type_number_t(0)
        let task = Self.machTask
        guard task_threads(task, &list, &count) == KERN_SUCCESS, let list else { return -1 }
        defer {
            for index in 0..<Int(count) { mach_port_deallocate(task, list[index]) }
            vm_deallocate(
                task,
                vm_address_t(UInt(bitPattern: list)),
                vm_size_t(MemoryLayout<thread_act_t>.stride) * vm_size_t(count)
            )
        }
        return Int(count)
    }

    func testAFailedSpawnDoesNotAccumulateReaderThreads() throws {
        // Warm up once so any first-call allocation is not counted as growth.
        _ = Shell.run("/nonexistent/definitely-not-here", ["--version"], timeout: 5)
        Thread.sleep(forTimeInterval: 0.4)
        let before = readerThreadCount()
        XCTAssertGreaterThanOrEqual(before, 0, "could not read the thread list")

        for _ in 0..<60 {
            _ = Shell.run("/nonexistent/definitely-not-here", ["--version"], timeout: 5)
        }
        // Long enough for the released Process's write ends to close and the
        // blocked readers to unwind — if they unwind at all.
        Thread.sleep(forTimeInterval: 1.5)
        let after = readerThreadCount()

        XCTAssertLessThanOrEqual(
            after - before, 8,
            "reader threads accumulated: \(before) before, \(after) after 60 failed spawns — that is a leak"
        )
    }

    func testAFailedSpawnReportsRatherThanThrows() {
        let output = Shell.run("/nonexistent/definitely-not-here", ["--version"], timeout: 5)
        XCTAssertEqual(output.status, 127)
        XCTAssertFalse(output.timedOut)
        XCTAssertTrue(
            output.stderr.contains("could not run") || output.stderr.contains("No such file"),
            "the caller must be told why: \(output.stderr)"
        )
    }

    func testAFailedSpawnOfADirectoryIsAlsoHandled() {
        // A path that exists but cannot be executed — a different failure mode
        // from "missing", and one that must not hang either.
        let output = Shell.run("/tmp", [], timeout: 5)
        XCTAssertNotEqual(output.status, 0)
        XCTAssertFalse(output.timedOut)
    }
}
#endif