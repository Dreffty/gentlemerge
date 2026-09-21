#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Reads what the hook scripts drop into the spool. Nothing here talks back to
/// an agent: the bridge reports, it never gates.
public struct SpoolStore: Sendable {
    public let paths: Paths

    public init(paths: Paths) {
        self.paths = paths
    }

    /// Publish the same envelope as a hook, with an independent safe filename.
    /// Owner-only, like everything the hook script writes: the payload is the
    /// agent's tool input verbatim, and the Redactor only sees it later.
    public func enqueue(_ envelope: SpoolEnvelope) throws {
        let url = paths.spool.appendingPathComponent(UUID().uuidString + ".json")
        try AtomicFile.write(JSONCoding.encoder().encode(envelope), to: url)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: - Reading

    /// Consume every queued envelope. Files are moved out of the spool first,
    /// so a decode failure can never turn into an infinite retry loop.
    public func drain() -> [SpoolEnvelope] {
        drain(matching: nil)
    }

    /// Consume only this envelope; unrelated and unreadable files stay queued.
    public func drain(envelopeID: String) -> [SpoolEnvelope] {
        drain(matching: envelopeID)
    }

    private func drain(matching envelopeID: String?) -> [SpoolEnvelope] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: paths.spool.path) else { return [] }

        let decoder = JSONCoding.decoder()
        var envelopes: [SpoolEnvelope] = []

        for name in names.sorted() where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let source = paths.spool.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: source) else { continue }

            do {
                let envelope = try decoder.decode(SpoolEnvelope.self, from: data)
                guard envelopeID == nil || envelope.id == envelopeID else { continue }
                guard let claimed = claim(source) else { continue }
                envelopes.append(envelope)
                move(claimed, toProcessedNamed: name)
            } catch {
                guard envelopeID == nil, let claimed = claim(source) else { continue }
                Log.error("unreadable envelope \(name): \(error.localizedDescription)")
                move(claimed, toProcessedNamed: name + ".bad")
            }
        }

        return envelopes
    }

    /// Atomic rename arbitrates between selective and ordinary consumers.
    /// A losing reader must not return the envelope it read before the rename.
    private func claim(_ source: URL) -> URL? {
        let claimed = paths.spool.appendingPathComponent(".consuming-" + UUID().uuidString)
        guard rename(source.path, claimed.path) == 0 else { return nil }
        return claimed
    }

    private func move(_ source: URL, toProcessedNamed name: String) {
        let destination = paths.processed.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: paths.processed, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: source)
        }
    }

    /// Keep the debugging trail small; anything older than a few days is noise.
    public func prune(olderThan interval: TimeInterval = 3 * 24 * 3600) {
        let manager = FileManager.default
        let cutoff = Date().addingTimeInterval(-interval)

        for directory in [paths.processed] {
            guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { continue }
            for name in names {
                let url = directory.appendingPathComponent(name)
                let modified = (try? manager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? nil
                if let modified, modified < cutoff {
                    try? manager.removeItem(at: url)
                }
            }
        }
    }

    /// Lets `gentlemerge status` tell you whether the app is up.
    public func writeAppPID() {
        try? AtomicFile.write(Data(String(ProcessInfo.processInfo.processIdentifier).utf8), to: paths.appPID)
    }

    /// Only ever clears our own entry: when one instance replaces another, the
    /// dying one must not delete the newcomer's pid.
    public func clearAppPID() {
        let mine = String(ProcessInfo.processInfo.processIdentifier)
        let stored = (try? String(contentsOf: paths.appPID, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard stored == mine else { return }
        try? FileManager.default.removeItem(at: paths.appPID)
    }

}
