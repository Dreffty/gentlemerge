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
