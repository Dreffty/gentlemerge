#if canImport(CryptoKit)
import CryptoKit
#endif
import Foundation

/// A file one agent left for another.
///
/// A long report used to travel as a message too short to be the report, or as
/// a path pasted by hand into a note nobody could verify. This is the formal
/// version of "I left you this": the message says what it is, and this says
/// where it is.
///
/// Never the content. The receiving agent opens the file with its own tools
/// when it decides the file is worth opening — inlining a 400 KB diff into a
/// briefing would cost the session the very turn the diff was meant to help.
public struct Attachment: Codable, Sendable, Equatable {
    /// What the sender called it, reduced to a plain file name.
    public var name: String
    /// Where it landed, relative to `~/.gentlemerge`: `artifacts/<key>/<name>`.
    /// Relative on purpose — `GENTLEMERGE_HOME` moves the whole tree, and a
    /// stored absolute path would survive the move as a lie.
    public var storedPath: String
    public var bytes: Int
    public var sha256: String
    /// The head of the stored text, already scrubbed, so a reader can tell a
    /// migration plan from a stack trace before opening anything. nil means
    /// nothing read this file as text — see `isBinary`.
    public var summary: String?

    public init(name: String, storedPath: String, bytes: Int, sha256: String, summary: String?) {
        self.name = name
        self.storedPath = storedPath
        self.bytes = bytes
        self.sha256 = sha256
        self.summary = summary
    }

    /// Nothing decoded this as text, so nothing scrubbed it either. The one
    /// case where bytes cross between agents unread, and every place that shows
    /// an attachment says so out loud.
    public var isBinary: Bool { summary == nil }

    public var sizeLabel: String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    /// The one line a reader gets: where it is, how big, and whether anybody
    /// looked at what is inside it. Shared by the briefing and by the sender's
    /// own confirmation so the two can never describe the same file differently.
    public func line(at path: String) -> String {
        "  → attachment: \(path) (\(sizeLabel)\(isBinary ? ", binary — not scrubbed" : ""))"
    }
}

/// Where attachments live, and the rules for getting in.
///
/// Content-addressed: the directory is the head of the digest of what is
/// stored, so the same report attached twice — by two agents, or by one agent
/// twice — is one copy on disk and one directory to collect later.
public struct ArtifactStore: Sendable {
    public enum Failure: Error, CustomStringConvertible {
        case unreadable(String)
        case tooLarge(name: String, bytes: Int)
        case suppressed(name: String, summary: String)
        case empty(String)

        public var description: String {
            switch self {
            case .unreadable(let path):
                return "cannot attach \(path): no readable file there"
            case .tooLarge(let name, let bytes):
                return "cannot attach \(name): \(bytes / 1024) KB is over the "
                    + "\(ArtifactStore.byteLimit / 1024 / 1024) MB limit — leave it where it is and say where"
            case .suppressed(let name, let summary):
                return "cannot attach \(name): it is almost entirely \(summary), so the scrubbed copy "
                    + "would be the shape of the secret with the secret taken out"
            case .empty(let name):
                return "cannot attach \(name): there is nothing in it to share"
            }
        }
    }

    /// 2 MB. Big enough for any report, diff or log an agent writes on purpose;
    /// small enough that `--attach node_modules.tar` is a mistake we name
    /// rather than a copy we make.
    public static let byteLimit = 2 * 1024 * 1024

    public let paths: Paths

    public init(paths: Paths) {
        self.paths = paths
    }

    /// Put a file in the store and describe what went in.
    ///
    /// Text is stored **scrubbed**: the hard rule is that everything crossing
    /// into another agent's context goes through the Redactor, and a file is
    /// not an exception just because it arrived as a path. What the store keeps
    /// is the clean copy — the original stays where the sender wrote it.
    public func store(contentsOf url: URL) throws -> Attachment {
        guard
            let name = Self.safeName(url.lastPathComponent),
            FileManager.default.fileExists(atPath: url.path)
        else { throw Failure.unreadable(url.path) }

        // Asked of the file system before reading: the point of a limit is not
        // to load a gigabyte into memory and then object to it.
        let declared = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        if let declared, declared > Self.byteLimit { throw Failure.tooLarge(name: name, bytes: declared) }

        guard let data = try? Data(contentsOf: url) else { throw Failure.unreadable(url.path) }
        guard data.count <= Self.byteLimit else { throw Failure.tooLarge(name: name, bytes: data.count) }
        guard !data.isEmpty else { throw Failure.empty(name) }

        var stored = data
        var summary: String?

        if let text = String(data: data, encoding: .utf8) {
            let result = Redactor.scrub(text)
            if result.isSuppressed { throw Failure.suppressed(name: name, summary: result.summary) }
            let head = Self.summarize(result.text)
            // Whitespace and nothing else reads as text but says nothing, and
            // storing it would leave an attachment with no summary — which is
            // how this file says "binary".
            guard !head.isEmpty else { throw Failure.empty(name) }
            stored = Data(result.text.utf8)
            summary = head
        }

        let digest = Self.digest(stored)
        let key = Self.key(for: digest)
        let file = paths.artifacts.appendingPathComponent(key, isDirectory: true).appendingPathComponent(name)
        // Same bytes, same place. Two agents attaching the same log is the
        // normal case on a bus, not the exception.
        if !FileManager.default.fileExists(atPath: file.path) {
            try AtomicFile.write(stored, to: file)
        }

        return Attachment(
            name: name,
            storedPath: "artifacts/\(key)/\(name)",
            bytes: stored.count,
            sha256: digest,
            summary: summary
        )
    }

    /// Where an agent should go and look.
    public func url(for attachment: Attachment) -> URL {
        paths.home.appendingPathComponent(attachment.storedPath)
    }

    /// The same, spelt the way a person reads it.
    public func displayPath(for attachment: Attachment) -> String {
        #if os(macOS)
        (url(for: attachment).path as NSString).abbreviatingWithTildeInPath
        #else
        // swift-corelibs Foundation does not expose NSString's abbreviation API.
        let path = url(for: attachment).path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        #endif
    }

    /// Drop the directories no surviving message points at any more.
    ///
    /// `grace` is the gap between storing a file and appending the note that
    /// names it: for that moment the artifact is an orphan by every measure we
    /// have, and a sweep landing in it would delete exactly the file somebody
    /// is about to talk about. An hour is enormous next to that window and
    /// nothing next to the log's seven days.
    ///
    /// Returns how many directories went away.
    @discardableResult
    public func collect(keeping keys: Set<String>, now: Date = Date(), grace: TimeInterval = 3600) -> Int {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: paths.artifacts.path) else { return 0 }
        var collected = 0
        for name in names where !keys.contains(name) {
            let directory = paths.artifacts.appendingPathComponent(name, isDirectory: true)
            let modified = (try? FileManager.default.attributesOfItem(atPath: directory.path)[.modificationDate] as? Date) ?? nil
            guard let modified, now.timeIntervalSince(modified) > grace else { continue }
            if (try? FileManager.default.removeItem(at: directory)) != nil { collected += 1 }
        }
        return collected
    }

    /// The directories a set of messages is keeping alive.
    public static func keys(referencedBy messages: [AgentMessage]) -> Set<String> {
        var keys: Set<String> = []
        for message in messages {
            for attachment in message.attachments ?? [] {
                if let key = key(inStoredPath: attachment.storedPath) { keys.insert(key) }
            }
        }
        return keys
    }

    /// `artifacts/ab12cd34ef56/report.md` → `ab12cd34ef56`. nil for anything
    /// that does not look like one of ours, which is the safe answer: an
    /// unrecognised path keeps nothing, and keeping nothing only ever collects
    /// a directory the path was not naming anyway.
    static func key(inStoredPath path: String) -> String? {
        let parts = path.split(separator: "/")
        guard parts.count == 3, parts[0] == "artifacts", !parts[1].isEmpty else { return nil }
        return String(parts[1])
    }

    // MARK: - Naming

    static func digest(_ data: Data) -> String {
        #if canImport(CryptoKit)
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        PortableSHA256.digest(data)
        #endif
    }

    /// The directory a piece of content lives in: enough of its digest that two
    /// different files landing in the same one is not a thing that happens here.
    ///
    /// Nudged off any run of pure digits on purpose. A briefing is scrubbed on
    /// its way out and `\d{7,}` reads as an account number, so an all-digit
    /// directory would come back as "[redacted number]" — and the path the
    /// receiving agent is meant to open is the one part of the line that has to
    /// survive intact.
    static func key(for digest: String) -> String {
        let hex = Array(digest)
        guard hex.count >= 12 else { return digest }
        for start in 0...(hex.count - 12) {
            let window = String(hex[start..<(start + 12)])
            if window.contains(where: { $0.isLetter }) { return window }
        }
        return String(hex.prefix(12))
    }

    /// A file name and nothing else. The argument is typed by hand and becomes
    /// a path component of ours; `../../.ssh/id_rsa` is not a name.
    static func safeName(_ raw: String) -> String? {
        // Split by hand rather than through `URL.lastPathComponent`: that one
        // resolves ".." against the working directory and hands back the name
        // of a real parent folder, which is the opposite of what is wanted here.
        let base = raw.split(separator: "/").last.map(String.init) ?? ""
        let cleaned = String(base.map { character in
            character == "/" || character == ":" || character == "\0" ? "-" : character
        })
        guard !cleaned.isEmpty, cleaned != ".", cleaned != ".." else { return nil }
        return String(cleaned.prefix(120))
    }

    static let summaryLines = 10
    static let summaryColumns = 120

    /// The first few lines, wrapped short. Long enough to recognise the file,
    /// short enough that ten of them are still cheaper than opening one.
    static func summarize(_ text: String) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(summaryLines)
            .map { $0.count > summaryColumns ? String($0.prefix(summaryColumns)) + "…" : String($0) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
