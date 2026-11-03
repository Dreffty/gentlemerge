import Foundation
import XCTest
@testable import GentleMergeCore

/// The app's own clock sweeps what `gentlemerge compact` used to be the only way to sweep.
@MainActor
final class AppSweepTests: XCTestCase {
    func testTheAppTickRemovesIdleLockFiles() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gentlemerge-sweep-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = Paths(home: root)
        try paths.createDirectories()

        let old = Date().addingTimeInterval(-3 * 86_400)
        func lock(_ name: String, modified: Date) throws -> URL {
            let url = paths.home.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: Data())
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
            return url
        }
        let idle = try lock("handoff-0123456789abcdef.lock", modified: old)
        let fresh = try lock("handoff-fedcba9876543210.lock", modified: Date())

        let model = InboxModel(paths: paths)
        model.pruneIfDue()

        XCTAssertFalse(FileManager.default.fileExists(atPath: idle.path), "an idle lock sidecar outlives the sweep")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path), "a lock touched today is left alone")
    }
}

/// `gentlemerge config set` while the app is running (audit 2026-11-01).
@MainActor
final class AppConfigReloadTests: XCTestCase {
    private var root: URL!
    private var paths: Paths!

    override func setUp() async throws {
        try await MainActor.run {
            root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gentlemerge-config-\(UUID().uuidString)")
            paths = Paths(home: root)
            try paths.createDirectories()
        }
    }
    override func tearDown() async throws {
        await MainActor.run { try? FileManager.default.removeItem(at: root) }
    }

    /// What `gentlemerge config set` does: load, change, save.
    private func setFromTheTerminal(_ change: (inout AppConfig) -> Void) throws {
        var config = AppConfig.load(from: paths.config)
        change(&config)
        try config.save(to: paths.config)
    }

    func testATerminalChangeReachesTheRunningApp() throws {
        let model = InboxModel(paths: paths)
        XCTAssertFalse(model.config.allowDispatch)
        try setFromTheTerminal { $0.allowDispatch = true }
        model.reloadConfigIfChanged()
        XCTAssertTrue(model.config.allowDispatch)
    }

    func testAnAppChangeAfterATerminalChangeKeepsBoth() throws {
        let model = InboxModel(paths: paths)
        try setFromTheTerminal { $0.allowDispatch = true }
        model.reloadConfigIfChanged()
        model.config.retentionDays = 9
        let onDisk = AppConfig.load(from: paths.config)
        XCTAssertTrue(onDisk.allowDispatch, "the app's save undid the terminal's change")
        XCTAssertEqual(onDisk.retentionDays, 9)
    }

    func testAReloadDoesNotWriteTheFileBack() throws {
        let model = InboxModel(paths: paths)
        try setFromTheTerminal { $0.retentionDays = 12 }
        let before = InboxModel.modificationDate(of: paths.config)
        model.reloadConfigIfChanged()
        model.reloadConfigIfChanged()
        XCTAssertEqual(InboxModel.modificationDate(of: paths.config), before)
        XCTAssertEqual(model.config.retentionDays, 12)
    }

    func testAnUnreadableFileDoesNotResetTheApp() throws {
        let model = InboxModel(paths: paths)
        model.config.retentionDays = 9
        try Data("{ not json".utf8).write(to: paths.config)
        model.reloadConfigIfChanged()
        XCTAssertEqual(model.config.retentionDays, 9)
    }
}
