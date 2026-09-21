import XCTest
@testable import GentleMergeCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Deep clean deletes only what no reader will miss — and says what went.
final class RetentionTests: XCTestCase {
    private var root: URL!
    private var paths: Paths!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gentlemerge-retention-\(UUID().uuidString)")
        paths = Paths(home: root.appendingPathComponent("home"))
        try paths.createDirectories()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func backdate(_ url: URL, days: Double) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-days * 86_400)],
            ofItemAtPath: url.path
        )
    }

    func testPresencePruneRemovesOnlyStaleMarks() throws {
        Presence.record(label: "fresh", project: nil, branch: nil, paths: paths)
        Presence.record(label: "stale", project: nil, branch: nil, paths: paths)
        let files = try FileManager.default.contentsOfDirectory(at: paths.presence, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 2)
        // Age the stale mark past its TTL by rewriting its date.
        let stale = try XCTUnwrap(files.first { $0.lastPathComponent.contains("stale") })
        var mark = try JSONCoding.decoder().decode(Presence.Mark.self, from: Data(contentsOf: stale))
        mark.updatedAt = Date().addingTimeInterval(-Presence.timeToLive - 60)
        try JSONCoding.encoder().encode(mark).write(to: stale)

        XCTAssertEqual(Presence.prune(paths: paths), 1)
        XCTAssertEqual(Presence.marks(paths: paths).map(\.label), ["fresh"])
    }

    func testDispatchPruneKeepsRecentLogs() throws {
        try FileManager.default.createDirectory(at: paths.dispatch, withIntermediateDirectories: true)
        let old = paths.dispatch.appendingPathComponent("req-old.log")
        let oldPrompt = paths.dispatch.appendingPathComponent("req-old.prompt.md")
        let fresh = paths.dispatch.appendingPathComponent("req-new.log")
        try Data("x".utf8).write(to: old)
        try Data("x".utf8).write(to: oldPrompt)
        try Data("x".utf8).write(to: fresh)
        try backdate(old, days: 31)
        try backdate(oldPrompt, days: 31)

        XCTAssertEqual(Retention.pruneDispatch(paths: paths, olderThanDays: 30), 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }

    func testCompactCollectsOrphansAndReports() throws {
        var request = AgentRequest(id: "req-old-friend", from: "a", fromVerified: true,
            to: "b", projectPath: "/p", title: "t", spec: "s")
        request.state = .done
        request.updatedAt = Date().addingTimeInterval(-8 * 86_400)
        // save() would stamp now; write the file directly to fabricate age.
        let store = Requests(paths: paths)
        try FileManager.default.createDirectory(at: paths.requests, withIntermediateDirectories: true)
        try JSONCoding.encoder().encode(request).write(to: store.url(request.id))
        Presence.record(label: "ghost", project: nil, branch: nil, paths: paths)
        let ghosts = try FileManager.default.contentsOfDirectory(at: paths.presence, includingPropertiesForKeys: nil)
        var mark = try JSONCoding.decoder().decode(Presence.Mark.self, from: Data(contentsOf: ghosts[0]))
        mark.updatedAt = Date().addingTimeInterval(-Presence.timeToLive - 60)
        try JSONCoding.encoder().encode(mark).write(to: ghosts[0])

        let report = Retention.compact(paths: paths)
        XCTAssertEqual(report.requests, 1)
        XCTAssertEqual(report.presence, 1)
        XCTAssertTrue(Requests(paths: paths).all().isEmpty)

        let again = Retention.compact(paths: paths)
        XCTAssertEqual(again.requests, 0)
        XCTAssertEqual(again.presence, 0)
    }

    func testTheHomeIsPrivateToItsUser() throws {
        #if canImport(Darwin)
        if geteuid() == 0 { throw XCTSkip("running as root: permission bits do not apply") }
        #elseif canImport(Glibc)
        if geteuid() == 0 { throw XCTSkip("running as root: permission bits do not apply") }
        #endif
        _ = try paths.createDirectories()
        let perms = try FileManager.default.attributesOfItem(atPath: paths.home.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o700, "ledger, presence and tasks are not for other users")
    }

    func testRetentionDaysSurvivesARoundTripAndDefaults() throws {        var config = AppConfig()
        config.retentionDays = 7
        let data = try JSONCoding.encoder().encode(config)
        XCTAssertEqual(try JSONCoding.decoder().decode(AppConfig.self, from: data).retentionDays, 7)
        XCTAssertEqual(try JSONCoding.decoder().decode(AppConfig.self, from: Data("{}".utf8)).retentionDays, 30,
            "an old config without the key keeps the default, like every other key")
    }
}
