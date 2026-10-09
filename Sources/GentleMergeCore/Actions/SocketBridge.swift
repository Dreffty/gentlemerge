import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Delivers a one-line notice to a Claude Code session over its per-session Unix socket.
/// Preferred over TerminalBridge: works while idle, never types into a foreign tty.
public struct SocketBridge: Sendable {
    public enum Failure: Error, Sendable, Equatable {
        case noSocket
        case connect(Int32)
        case write
        case unknownWireFormat
    }

    /// IMPLEMENTER: the exact JSON line must come from the current Claude Code docs
    /// (cross-session-messaging → "The session's inbox socket"). Do NOT invent it.
    /// If undetermined, throw .unknownWireFormat so NudgeGate falls back and the ledger records why.
    ///
    /// What the docs do say today: alongside the path, Claude Code exports a
    /// per-session CLAUDE_CODE_MESSAGING_TOKEN, and a script posting to its own
    /// session's socket may send `{"type":"auth","token":"<token>"}` as the
    /// connection's first line (optional on macOS/Linux, required on native
    /// Windows). The message line itself is not specified there — until it is,
    /// this throws and delivery falls back to the tty on macOS.
    static func wireLine(for text: String, token: String?) throws -> String {
        throw Failure.unknownWireFormat
    }

    public static func send(notice: String, to socketPath: String, token: String? = nil) throws {
        let line = try wireLine(for: notice, token: token)
        // Glibc types SOCK_STREAM as __socket_type; Darwin as Int32.
        #if os(Linux)
        let streamType = Int32(SOCK_STREAM.rawValue)
        #else
        let streamType = SOCK_STREAM
        #endif
        let fd = socket(AF_UNIX, streamType, 0)
        guard fd >= 0 else { throw Failure.connect(errno) }
        defer { close(fd) }
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        guard socketPath.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw Failure.noSocket }
        withUnsafeMutablePointer(to: &addr.sun_path) { p in socketPath.withCString { _ = strcpy(UnsafeMutableRawPointer(p).assumingMemoryBound(to: CChar.self), $0) } }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        guard withUnsafePointer(to: &addr, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) } }) == 0 else { throw Failure.connect(errno) }
        // Loop the write and neutralise SIGPIPE, like every other raw-write site in
        // this codebase (`AgentBus` around :725, `JSONCoding` around :126).
        // `write` to a socket is allowed to be short, and the old single call
        // reported a partial write as success. A peer that closed between
        // `connect` and `write` raises SIGPIPE, whose default disposition on
        // Darwin is to terminate the process — and this is called from the
        // MainActor, inside the menu-bar app (audit Tier 5 #28).
        //
        // Unreachable today: `wireLine` always throws `.unknownWireFormat`, so
        // `NudgeGate` falls back to the tty. It is fixed because this is the
        // code the IMPLEMENTER note above is waiting for someone to complete,
        // and it should not be landmines on arrival.
        var bytesWritten = 0
        let total = line.utf8.count
        try line.withCString { pointer in
            while bytesWritten < total {
                #if canImport(Darwin)
                let sent = Darwin.write(fd, pointer + bytesWritten, total - bytesWritten)
                #elseif canImport(Glibc)
                let sent = Glibc.write(fd, pointer + bytesWritten, total - bytesWritten)
                #endif
                if sent < 0 {
                    // EPIPE means the peer went away; there is nothing to retry.
                    guard errno == EINTR else { throw Failure.write }
                    continue
                }
                bytesWritten += sent
            }
        }
    }

    /// One greppable word per failure, for the ledger.
    public static func shortError(_ error: Error) -> String {
        switch error as? Failure {
        case .noSocket: return "no socket"
        case .connect: return "connect failed"
        case .write: return "write failed"
        case .unknownWireFormat: return "unknown wire format (needs verification)"
        case nil: return error.localizedDescription
        }
    }
}
