import XCTest
@testable import GentleMergeCore

/// The socket half of delivery: what the hook reports, what the activity
/// keeps, and what the bridge refuses to invent.
final class SocketTests: XCTestCase {
    func testAnEnvelopeCarriesTheSocketAndOldOnesDecodeWithoutIt() throws {
        let decoder = JSONCoding.decoder()
        let with = try decoder.decode(
            SpoolEnvelope.self,
            from: Data(#"{"id":"e1","provider":"unknown","socket":"/tmp/x.sock","payload":{}}"#.utf8)
        )
        XCTAssertEqual(with.socket, "/tmp/x.sock")

        let without = try decoder.decode(
            SpoolEnvelope.self,
            from: Data(#"{"id":"e2","provider":"unknown","payload":{}}"#.utf8)
        )
        XCTAssertNil(without.socket)
    }

    func testAnActivityKeepsASocketItNeverHeardOf() throws {
        let decoder = JSONCoding.decoder()
        let old = try decoder.decode(
            AgentActivity.self,
            from: Data(#"{"id":"a","provider":"unknown","startedAt":"2026-09-01T10:00:00Z","updatedAt":"2026-09-01T10:00:00Z","state":"idle"}"#.utf8)
        )
        XCTAssertNil(old.socketPath)

        let encoder = JSONCoding.encoder()
        var activity = old
        activity.socketPath = "/tmp/x.sock"
        let roundTripped = try decoder.decode(AgentActivity.self, from: try encoder.encode(activity))
        XCTAssertEqual(roundTripped.socketPath, "/tmp/x.sock")
    }

    /// The wire format is undetermined (see SocketBridge): until the vendor's
    /// docs specify the message line, every send throws and the gate falls
    /// back — never a guess written into a live session's socket.
    func testWireLineThrowsUntilTheFormatIsVerified() {
        XCTAssertThrowsError(try SocketBridge.wireLine(for: "hello", token: nil)) { error in
            XCTAssertEqual(error as? SocketBridge.Failure, .unknownWireFormat)
        }
        XCTAssertThrowsError(try SocketBridge.send(notice: "hello", to: "/tmp/gentlemerge-no-such.sock")) { error in
            XCTAssertEqual(error as? SocketBridge.Failure, .unknownWireFormat)
        }
    }

    func testShortErrorsAreGreppable() {
        XCTAssertEqual(SocketBridge.shortError(SocketBridge.Failure.noSocket), "no socket")
        XCTAssertEqual(
            SocketBridge.shortError(SocketBridge.Failure.unknownWireFormat),
            "unknown wire format (needs verification)"
        )
    }

    /// Session ids are agent-controlled free text, but marker files live under
    /// delivered/: hostile ids must remap inside it, sane ids byte for byte.
    func testSessionIDsCannotEscapeTheDeliveredDirectory() throws {
        XCTAssertEqual(AgentBus.fileSafeSessionID("56593ac1-515e-4e33-b078-0810410f98b0"), "56593ac1-515e-4e33-b078-0810410f98b0")
        XCTAssertEqual(AgentBus.fileSafeSessionID("reader-hermes"), "reader-hermes")
        for hostile in ["../../evil", "a/b", "..", "", ".hidden", "x", String(repeating: "a", count: 200)] {
            let safe = AgentBus.fileSafeSessionID(hostile)
            XCTAssertFalse(safe.contains("/"), hostile)
            XCTAssertFalse(safe.contains(".."), hostile)
            XCTAssertFalse(safe.hasPrefix("."), hostile)
            XCTAssertFalse(safe.isEmpty, hostile)
        }

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gentlemerge-marker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = Paths(home: root)
        let bus = AgentBus(paths: paths)
        bus.record(delivery: "fp", delivered: [], for: "../../evil")
        let names = try FileManager.default.contentsOfDirectory(atPath: paths.delivered.path)
        XCTAssertEqual(names.count, 1)
        XCTAssertFalse(names[0].contains(".."))
    }
}
