#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

public enum JSONCoding {
    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : []
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                if let date = ISO8601DateFormatter.gentleMerge.date(from: text) { return date }
                if let date = ISO8601DateFormatter.gentleMergeFractional.date(from: text) { return date }
                if let seconds = Double(text) { return Date(timeIntervalSince1970: seconds) }
            }
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds)
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unreadable date")
        }
        return decoder
    }
}

/// One named lock per file, taken by everyone who touches it.
///
/// The lock lives in a sibling `<name>.lock` and never in the data file: a
/// rewrite (the prune) replaces the data file by rename, so a descriptor held
/// on it would point at an orphaned inode and the writes would vanish. The
/// sidecar keeps its identity across those rewrites, which is the whole point.
public enum LockedFile {
    public struct Error: Swift.Error, LocalizedError, CustomStringConvertible {
        public let path: String
        public let code: Int32
        public var description: String {
            "could not lock \(path): \(String(cString: strerror(code)))"
        }
        public var errorDescription: String? { description }
    }

    /// Run `body` with an exclusive hold on `url`. Blocks until the lock is
    /// free — the callers are a menu bar app and short-lived hooks, and every
    /// critical section here is a few kilobytes of JSON.
    @discardableResult
    public static func withExclusiveLock<T>(_ url: URL, _ body: () throws -> T) throws -> T {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lock = directory.appendingPathComponent("\(url.lastPathComponent).lock")

        guard let descriptor = try lockedDescriptor(lock, blocking: true) else {
            throw Error(path: lock.path, code: EWOULDBLOCK)   // a blocking lock never comes back empty
        }
        defer { flock(descriptor, LOCK_UN); close(descriptor) }

        return try body()
    }

    /// `withExclusiveLock`, but giving up after `patience` seconds: nil means
    /// somebody else held the lock the whole time and `body` did not run.
    ///
    /// For the short-lived commands that drain the spool before they answer.
    /// The app holds the drain lock while it ingests, and an ingest can stall
    /// for as long as macOS keeps a file-access prompt on screen — a freshly
    /// signed app reading a handoff in ~/Downloads does exactly that. Waiting
    /// without a limit hung `who`, `brief`, the MCP server and the git
    /// pre-commit gate behind a dialog nobody had seen (audit 2026-11-01).
    public static func withExclusiveLock<T>(_ url: URL, waitingAtMost patience: TimeInterval,
                                            _ body: () throws -> T) throws -> T? {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lock = directory.appendingPathComponent("\(url.lastPathComponent).lock")
        let deadline = Date().addingTimeInterval(patience)
        while true {
            if let descriptor = try lockedDescriptor(lock, blocking: false) {
                defer { flock(descriptor, LOCK_UN); close(descriptor) }
                return try body()
            }
            guard Date() < deadline else { return nil }
            usleep(50_000)
        }
    }

    /// Called between opening the sidecar and locking it. Tests only: it is
    /// how a test stands in for the sweep that deletes a sidecar mid-open.
    nonisolated(unsafe) static var afterOpenForTesting: (() -> Void)?

    /// Open the sidecar and lock it — and make sure what got locked is still
    /// the file at that path.
    ///
    /// Idle sidecars are swept (`Retention.pruneLocks`), and since 2026-11-01
    /// the app does it on its own every six hours. A sweep that unlinks a
    /// sidecar between another process's `open` and its `flock` leaves that
    /// process holding a lock on a file nobody else can reach: the next
    /// process creates a fresh sidecar, locks that, and both are inside the
    /// critical section at once — two writers on the claims or the task list.
    /// So after locking, the descriptor and the path are compared, and on a
    /// mismatch it lets go and starts over with whatever is there now.
    static func lockedDescriptor(_ lock: URL, blocking: Bool) throws -> Int32? {
        let operation = blocking ? LOCK_EX : (LOCK_EX | LOCK_NB)
        while true {
            let descriptor = open(lock.path, O_WRONLY | O_CREAT, 0o644)
            guard descriptor >= 0 else { throw Error(path: lock.path, code: errno) }
            afterOpenForTesting?()

            var result = flock(descriptor, operation)
            // A signal landing mid-wait is not a failure to lock.
            while result != 0 && errno == EINTR { result = flock(descriptor, operation) }
            if result != 0 {
                let code = errno
                close(descriptor)
                if !blocking && (code == EWOULDBLOCK || code == EAGAIN) { return nil }
                throw Error(path: lock.path, code: code)
            }

            var held = stat()
            var current = stat()
            if fstat(descriptor, &held) == 0, stat(lock.path, &current) == 0,
               held.st_dev == current.st_dev, held.st_ino == current.st_ino {
                return descriptor
            }
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
    }

    /// Try once, never wait: runs the body and returns true, or returns false
    /// when somebody else holds the lock. The landing queue of depth one — a
    /// second landing skips with a reason instead of stacking Stops behind a
    /// slow suite.
    @discardableResult
    public static func tryExclusiveLock<T>(_ url: URL, _ body: () throws -> T) throws -> Bool {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lock = directory.appendingPathComponent("\(url.lastPathComponent).lock")

        guard let descriptor = try lockedDescriptor(lock, blocking: false) else { return false }
        defer { flock(descriptor, LOCK_UN); close(descriptor) }

        _ = try body()
        return true
    }
}

public enum AtomicFile {
    public struct Error: Swift.Error, LocalizedError, CustomStringConvertible {
        public let path: String
        public let code: Int32
        public var description: String {
            "could not write \(path): \(String(cString: strerror(code)))"
        }
        /// Without this `localizedDescription` is "The operation couldn't be completed.
        /// (GentleMergeCore.AtomicFile.Error error 1.)" wherever a command prints it.
        public var errorDescription: String? { description }
    }

    /// Write via a sibling temp file + `rename(2)`, so a reader (or a shell
    /// script in a polling loop) never sees half a file — and never sees *no*
    /// file.
    ///
    /// `rename(2)` is the whole trick, and it is not interchangeable with
    /// `FileManager.moveItem`. `rename` replaces an existing destination
    /// atomically when both names live on one filesystem, which a sibling temp
    /// file guarantees. `moveItem` refuses to overwrite, so the obvious
    /// implementation is `removeItem` + `moveItem` — and that reintroduces the
    /// hole the temp file exists to close: between the remove and the move the
    /// destination does not exist. Measured against the pre-commit gate, that
    /// window let 54% of evaluations of a *blocked* commit pass (audit
    /// 2026-10-07). The second writer in that race also lost: `moveItem` threw
    /// "file exists", destroying the previous content and leaking its temp file
    /// (4125 orphans in 3s on the cursor).
    public static func write(_ data: Data, to requested: URL) throws {
        // A symlink is written *through*. `rename` onto the link replaced it with a
        // regular file, so `CLAUDE.md -> AGENTS.md` stopped being a link the first
        // time anything here touched it.
        let url = resolvingLink(at: requested)
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)

        // What the file already is: its permission bits come along, and a file its
        // owner made read-only is refused, as a plain write would refuse it —
        // renaming over it got around both. A file that is not there yet gets the
        // default, as before.
        let existing = try? manager.attributesOfItem(atPath: url.path)
        if existing != nil, !manager.isWritableFile(atPath: url.path) {
            throw Error(path: requested.path, code: EACCES)
        }

        let temporary = directory.appendingPathComponent(".tmp-\(UUID().uuidString)")
        try data.write(to: temporary)
        if let mode = (existing?[.posixPermissions] as? NSNumber)?.uint16Value {
            chmod(temporary.path, mode_t(mode))
        }
        guard rename(temporary.path, url.path) == 0 else {
            // Never leave the temp behind: there is no sweeper for these.
            let code = errno
            _ = try? FileManager.default.removeItem(at: temporary)
            throw Error(path: url.path, code: code)
        }
    }

    /// Add one line to a file several processes may be adding lines to at the
    /// same moment.
    ///
    /// Three things have to hold at once. The sidecar lock keeps us out of a
    /// prune that is rewriting the file underneath us. `O_APPEND` makes the
    /// kernel resolve the end-of-file offset at write time, so no writer can
    /// seek to a stale end and overwrite somebody else's line — which is
    /// exactly what the old seek-then-write did, and why `messages.jsonl` has
    /// spliced lines in it. `flock` on the data file itself is the belt to
    /// that braces, and the one another tool could honour.
    /// Follows a symlink at the end of `url` (a few levels, relative targets
    /// against the link's own directory). A link that loops or cannot be read
    /// is left as it is.
    static func resolvingLink(at url: URL) -> URL {
        var current = url
        for _ in 0..<16 {
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: current.path) else {
                return current
            }
            current = target.hasPrefix("/")
                ? URL(fileURLWithPath: target)
                : current.deletingLastPathComponent().appendingPathComponent(target).standardized
        }
        return url
    }

    public static func append(_ line: String, to url: URL) throws {
        let data = Data((line + "\n").utf8)

        try LockedFile.withExclusiveLock(url) {
            let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            guard descriptor >= 0 else { throw LockedFile.Error(path: url.path, code: errno) }
            defer { close(descriptor) }

            while flock(descriptor, LOCK_EX) != 0 {
                guard errno == EINTR else { throw LockedFile.Error(path: url.path, code: errno) }
            }
            defer { flock(descriptor, LOCK_UN) }

            try data.withUnsafeBytes { buffer in
                guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return }
                var written = 0
                while written < buffer.count {
                    #if canImport(Darwin)
                    let count = Darwin.write(descriptor, base + written, buffer.count - written)
                    #elseif canImport(Glibc)
                    let count = Glibc.write(descriptor, base + written, buffer.count - written)
                    #endif
                    if count < 0 {
                        guard errno == EINTR else { throw LockedFile.Error(path: url.path, code: errno) }
                        continue
                    }
                    written += count
                }
            }
        }
    }
}
