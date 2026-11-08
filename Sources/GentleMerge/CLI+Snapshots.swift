import GentleMergeCore
import GentleMergePorts
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension CLI {
    // MARK: - snapshots (phase 3)

    static func snapshot(_ arguments: [String]) -> Int32 {
        let projectPath = value(after: "--project", in: arguments)
            ?? FileManager.default.currentDirectoryPath
        guard let git = GitSnapshot(anyPathInside: projectPath) else {
            FileHandle.standardError.write(Data("\(projectPath) is not inside a git repository.\n".utf8))
            return 1
        }

        switch arguments.first {
        case nil, "list":
            let snapshots = git.list()
            if snapshots.isEmpty { print("No restore points.") }
            for snapshot in snapshots {
                print("\(snapshot.id)  \(snapshot.commit.prefix(8))  \(snapshot.label)")
            }
            return 0

        case "create":
            let label = positional(Array(arguments.dropFirst())).first ?? "manual"
            do {
                let reference = try git.create(label: label)
                print("\(reference.id)  \(reference.commit.prefix(8))  \(reference.dirtyFiles) changed files")
                return 0
            } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                return 1
            }

        case "restore":
            guard let id = positional(Array(arguments.dropFirst())).first, !id.isEmpty else {
                FileHandle.standardError.write(Data("usage: gentlemerge snapshot restore <id>\n".utf8))
                return 64
            }
            guard let reference = git.list().first(where: { $0.id.hasPrefix(id) }) else {
                FileHandle.standardError.write(Data(
                    "no restore point starts with “\(id)”. `gentlemerge snapshot list` shows them.\n".utf8))
                return 1
            }
            do {
                let report = try git.restore(reference)
                print("Restored “\(reference.label)”: \(report.summary).")
                for path in report.restored.prefix(20) { print("  ← \(path)") }
                for path in report.created.prefix(20) { print("  left in place: \(path)") }
                for path in report.skipped.prefix(20) { print("  skipped (submodule): \(path)") }
                print("Undo this restore with: gentlemerge snapshot restore \(report.safety.id)")
                return 0
            } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                return 1
            }

        default:
            FileHandle.standardError.write(Data("usage: gentlemerge snapshot [list|create|restore <id>]\n".utf8))
            return 64
        }
    }
}
