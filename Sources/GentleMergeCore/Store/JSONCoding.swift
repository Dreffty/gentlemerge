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
    public struct Error: Swift.Error, CustomStringConvertible {
        public let path: String
        public let code: Int32
        public var description: String {
            "could not lock \(path): \(String(cString: strerror(code)))"
        }
    }

    /// Run `body` with an exclusive hold on `url`. Blocks until the lock is
    /// free — the callers are a menu bar app and short-lived hooks, and every
    /// critical section here is a few kilobytes of JSON.
    @discardableResult
    public static func withExclusiveLock<T>(_ url: URL, _ body: () throws -> T) throws -> T {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lock = directory.appendingPathComponent("\(url.lastPathComponent).lock")

        let descriptor = open(lock.path, O_WRONLY | O_CREAT, 0o644)
        guard descriptor >= 0 else { throw Error(path: lock.path, code: errno) }
        defer { close(descriptor) }

        while flock(descriptor, LOCK_EX) != 0 {
            // A signal landing mid-wait is not a failure to lock.
            guard errno == EINTR else { throw Error(path: lock.path, code: errno) }
        }
        defer { flock(descriptor, LOCK_UN) }

        return try body()
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

        let descriptor = open(lock.path, O_WRONLY | O_CREAT, 0o644)
        guard descriptor >= 0 else { throw Error(path: lock.path, code: errno) }
        defer { close(descriptor) }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK || errno == EAGAIN { return false }
            throw Error(path: lock.path, code: errno)
        }
        defer { flock(descriptor, LOCK_UN) }

        _ = try body()
        return true
    }
}

public enum AtomicFile {
    /// Write via a sibling temp file + rename, so a reader (or a shell script in
    /// a polling loop) never sees half a file.
    public static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".tmp-\(UUID().uuidString)")
        try data.write(to: temporary)
        _ = try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: temporary, to: url)
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
