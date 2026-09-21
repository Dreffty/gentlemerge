import Foundation

public struct SnapshotRef: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var commit: String
    public var label: String
    public var createdAt: Date
    public var repository: String
    /// How many files differed from HEAD when the snapshot was taken.
    public var dirtyFiles: Int

    public var reference: String { "refs/gentlemerge/snapshots/\(id)" }
}

public struct RestoreReport: Sendable, Equatable {
    /// Files written back to their snapshot contents.
    public var restored: [String]
    /// Files the agent created after the snapshot. We never delete; you decide.
    public var created: [String]
    /// The snapshot taken of the current state before restoring, so this is undoable.
    public var safety: SnapshotRef?

    public var summary: String {
        var parts = ["restored \(restored.count) \(restored.count == 1 ? "file" : "files")"]
        if !created.isEmpty {
            parts.append("left \(created.count) new \(created.count == 1 ? "file" : "files") in place")
        }
        return parts.joined(separator: ", ")
    }
}

/// Restore points made with git plumbing: a real commit object on a private ref,
/// built through a temporary index so your staging area is never touched.
///
/// Restoring only ever *writes* files back. Nothing is deleted, and the state you
/// are leaving is snapshotted first — an undo that cannot eat your work.
public struct GitSnapshot: Sendable {
    public let repository: URL

    private static let namespace = "refs/gentlemerge/snapshots"

    public init?(anyPathInside path: String?) {
        guard let path, !path.isEmpty else { return nil }
        var directory = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue {
            directory = directory.deletingLastPathComponent()
        }

        let output = Shell.run("/usr/bin/env", ["git", "rev-parse", "--show-toplevel"], in: directory, timeout: 10)
        guard output.succeeded else { return nil }
        let root = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { return nil }
        repository = URL(fileURLWithPath: root)
    }

    public init(repository: URL) {
        self.repository = repository
    }

    public static func isRepository(_ path: String?) -> Bool {
        GitSnapshot(anyPathInside: path) != nil
    }

    // MARK: - Creating

    @discardableResult
    public func create(label: String) throws -> SnapshotRef {
        let indexFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("gentlemerge-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: indexFile) }

        let head = git(["rev-parse", "HEAD"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasHead = !head.isEmpty

        if hasHead {
            let read = git(["read-tree", head], index: indexFile)
            guard read.succeeded else { throw SnapshotError.git(read.text) }
        }

        // `add -A` against a throwaway index records the working tree —
        // including untracked files, excluding anything .gitignore excludes.
        let add = git(["add", "-A", "."], index: indexFile, timeout: 120)
        guard add.succeeded else { throw SnapshotError.git(add.text) }

        let tree = git(["write-tree"], index: indexFile).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tree.isEmpty else { throw SnapshotError.git("git write-tree produced nothing") }

        var arguments = ["commit-tree", tree]
        if hasHead { arguments += ["-p", head] }
        arguments += ["-m", "gentlemerge snapshot: \(label)"]
        let commitOutput = git(arguments)
        let commit = commitOutput.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard commitOutput.succeeded, !commit.isEmpty else { throw SnapshotError.git(commitOutput.text) }

        let id = "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))"
        let update = git(["update-ref", "\(Self.namespace)/\(id)", commit])
        guard update.succeeded else { throw SnapshotError.git(update.text) }

        let dirty = hasHead
            ? git(["diff", "--name-only", head, tree]).lines.count
            : git(["ls-tree", "-r", "--name-only", tree]).lines.count

        return SnapshotRef(
            id: id,
            commit: commit,
            label: label,
            createdAt: Date(),
            repository: repository.path,
            dirtyFiles: dirty
        )
    }

    // MARK: - Listing

    public func list() -> [SnapshotRef] {
        let output = git([
            "for-each-ref",
            "--sort=-creatordate",
            "--format=%(refname:short)%09%(objectname)%09%(creatordate:unix)%09%(subject)",
            Self.namespace,
        ])
        guard output.succeeded else { return [] }

        return output.lines.compactMap { line in
            let fields = line.components(separatedBy: "\t")
            guard fields.count >= 4 else { return nil }
            let id = fields[0].replacingOccurrences(of: "gentlemerge/snapshots/", with: "")
            let label = fields[3].replacingOccurrences(of: "gentlemerge snapshot: ", with: "")
            return SnapshotRef(
                id: id,
                commit: fields[1],
                label: label,
                createdAt: Date(timeIntervalSince1970: Double(fields[2]) ?? 0),
                repository: repository.path,
                dirtyFiles: 0
            )
        }
    }

    public func delete(_ snapshot: SnapshotRef) {
        _ = git(["update-ref", "-d", snapshot.reference])
    }

    /// Keeps the ref namespace from growing forever.
    public func prune(keeping limit: Int = 30) {
        for snapshot in list().dropFirst(limit) {
            delete(snapshot)
        }
    }

    // MARK: - Restoring

    public func restore(_ snapshot: SnapshotRef) throws -> RestoreReport {
        let safety = try? create(label: "before restoring \(snapshot.label)")

        let diff = git(["diff", "--name-status", "-z", snapshot.commit])
        guard diff.succeeded else { throw SnapshotError.git(diff.text) }

        var restored: [String] = []
        var created: [String] = []

        for (status, path) in Self.parseNameStatus(diff.stdout) {
            switch status.first {
            case "M", "T", "D":
                // Present in the snapshot and different (or missing) now.
                try writeFromSnapshot(commit: snapshot.commit, path: path)
                restored.append(path)
            case "A":
                created.append(path)
            default:
                continue
            }
        }

        // Untracked files never appear in a diff; they are the agent's new
        // files, and deleting them silently is exactly what we refuse to do.
        for line in git(["status", "--porcelain"]).lines where line.hasPrefix("??") {
            created.append(String(line.dropFirst(3)))
        }

        return RestoreReport(restored: restored, created: created.sorted(), safety: safety)
    }

    private func writeFromSnapshot(commit: String, path: String) throws {
        let output = git(["show", "\(commit):\(path)"], timeout: 60)
        guard output.succeeded else { throw SnapshotError.git(output.text) }

        let destination = repository.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try output.stdoutData.write(to: destination)
    }

    static func parseNameStatus(_ raw: String) -> [(status: String, path: String)] {
        let fields = raw.components(separatedBy: "\0").filter { !$0.isEmpty }
        var results: [(String, String)] = []
        var index = 0
        while index < fields.count {
            let status = fields[index]
            // Renames and copies carry two paths; the second is the current name.
            let extraPaths = status.hasPrefix("R") || status.hasPrefix("C") ? 2 : 1
            guard index + extraPaths < fields.count else { break }
            let path = fields[index + extraPaths]
            results.append((status, path))
            index += extraPaths + 1
        }
        return results
    }

    // MARK: - Plumbing

    @discardableResult
    private func git(_ arguments: [String], index: URL? = nil, timeout: TimeInterval = 30) -> Shell.Output {
        var environment = ["GIT_OPTIONAL_LOCKS": "0"]
        if let index { environment["GIT_INDEX_FILE"] = index.path }
        return Shell.run(
            "/usr/bin/env",
            ["git"] + arguments,
            in: repository,
            environment: environment,
            timeout: timeout
        )
    }
}

public enum SnapshotError: LocalizedError {
    case notARepository(String)
    case git(String)

    public var errorDescription: String? {
        switch self {
        case .notARepository(let path): return "\(path) is not inside a git repository."
        case .git(let message): return message.isEmpty ? "git failed" : message
        }
    }
}
