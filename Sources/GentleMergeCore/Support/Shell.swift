import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Runs the tools a developer already has — git, swift, npm — and reports what
/// they actually said. Output is captured on background queues before waiting,
/// so a chatty command can never deadlock on a full pipe.
public enum Shell {
    public struct Output: Sendable, Equatable {
        public var status: Int32
        /// Raw bytes, so restoring a binary file out of git stays lossless.
        public var stdoutData: Data
        public var stderr: String
        public var timedOut: Bool
        public var duration: TimeInterval

        public var stdout: String { String(decoding: stdoutData, as: UTF8.self) }

        public var succeeded: Bool { status == 0 && !timedOut }

        /// stdout when there is any, stderr otherwise — what a human would read.
        public var text: String {
            let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if out.isEmpty { return err }
            if err.isEmpty { return out }
            return out + "\n" + err
        }

        public var lines: [String] {
            stdout.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        }
    }

    public static func run(
        _ executable: String,
        _ arguments: [String] = [],
        in directory: URL? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 60,
        onStart: (@Sendable (Process) -> Void)? = nil
    ) -> Output {
        let started = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let outBox = DataBox()
        let errBox = DataBox()
        let readers = DispatchGroup()
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            // No reader threads exist yet, so there is nothing to leak — which is
            // the entire point of starting them after the spawn.
            return Output(
                status: 127,
                stdoutData: Data(),
                stderr: "could not run \(executable): \(error.localizedDescription)",
                timedOut: false,
                duration: Date().timeIntervalSince(started)
            )
        }

        // Two detached threads, not the global dispatch pool: readDataToEndOfFile
        // blocks, and once enough Shell.run calls stack up (every ingest that
        // canonicalizes a path spawns git), the pool's blocked readers starve the
        // very handlers needed to unblock them — a deadlock of our own making.
        //
        // Started only once the spawn succeeded. Each closure captures its Pipe
        // strongly, so a thread that is still blocked keeps that Pipe alive,
        // which keeps the write end open, so the reader never sees EOF: start
        // them first and a failed spawn leaked two threads and two descriptors
        // *permanently* (120 threads over 60 failures, measured audit Tier 2
        // #12). Closing the read handles instead is not an option — closing a
        // FileHandle another thread is reading raises on that thread, which the
        // suite caught when it turned the leak into a crash.
        readers.enter()
        let outReader = Thread {
            outBox.set(outPipe.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }
        outReader.name = "gentlemerge.shell.stdout"
        outReader.start()
        readers.enter()
        let errReader = Thread {
            errBox.set(errPipe.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }
        errReader.name = "gentlemerge.shell.stderr"
        errReader.start()

        onStart?(process)

        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if finished.wait(timeout: .now() + 3) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 2)
            }
        }
        readers.wait()

        return Output(
            status: process.terminationStatus,
            stdoutData: outBox.value,
            stderr: String(decoding: errBox.value, as: UTF8.self),
            timedOut: timedOut,
            duration: Date().timeIntervalSince(started)
        )
    }

    /// A command line the way you would type it, so project config can say
    /// `make test` or `npm run build && npm test`.
    public static func sh(
        _ command: String,
        in directory: URL? = nil,
        timeout: TimeInterval = 60,
        onStart: (@Sendable (Process) -> Void)? = nil
    ) -> Output {
        // A login shell picks up the PATH the user's tools actually live on
        // (homebrew, mise, nvm), which a GUI app does not inherit.
        run("/bin/sh", ["-lc", command], in: directory, timeout: timeout, onStart: onStart)
    }

    /// Single-quote a value for a POSIX shell.
    ///
    /// Single quotes are literal in sh, so the only character that has to be
    /// escaped is `'` itself — as `'\''`, which closes the quoted run, emits a
    /// quoted quote, and reopens. Nothing else can escape: `$`, `` ` ``, `"`,
    /// `\`, `;` and `&` are all inert inside single quotes.
    ///
    /// This exists for the values we interpolate into a command string, and it
    /// is the difference between a command and a shell injection. An Xcode
    /// scheme name read out of the repository was interpolated bare into
    /// `xcodebuild -scheme '<name>'`, so a scheme file called
    /// `ok'; touch PWNED; echo '` ran `touch PWNED` the next time anybody ran
    /// `gentlemerge review` or `gentlemerge land` (audit 2026-10-08).
    public static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Cancellable variant: cancelling the task terminates the process.
    public static func runAsync(
        _ executable: String,
        _ arguments: [String] = [],
        in directory: URL? = nil,
        timeout: TimeInterval = 60
    ) async -> Output {
        let holder = ProcessHolder()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    let output = run(
                        executable,
                        arguments,
                        in: directory,
                        timeout: timeout,
                        onStart: { holder.adopt($0) }
                    )
                    continuation.resume(returning: output)
                }
            }
        } onCancel: {
            holder.terminate()
        }
    }

    public static func shAsync(
        _ command: String,
        in directory: URL? = nil,
        timeout: TimeInterval = 60
    ) async -> Output {
        await runAsync("/bin/sh", ["-lc", command], in: directory, timeout: timeout)
    }
}

final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func set(_ data: Data) {
        lock.lock()
        storage = data
        lock.unlock()
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

final class ProcessHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func adopt(_ process: Process) {
        lock.lock()
        defer { lock.unlock() }
        if cancelled {
            process.terminate()
        } else {
            self.process = process
        }
    }

    func terminate() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if process?.isRunning == true { process?.terminate() }
    }
}
