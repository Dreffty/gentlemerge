import Foundation
import XCTest
@testable import GentleMergeCore

final class PortabilityTests: XCTestCase {
    func testDependencyFreeSHA256KnownVectors() {
        let vectors = [
            ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
            ("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"),
        ]
        for (input, expected) in vectors {
            XCTAssertEqual(PortableSHA256.digest(Data(input.utf8)), expected)
            XCTAssertEqual(ArtifactStore.digest(Data(input.utf8)), expected)
        }
    }

    func testSHA256BinaryPaddingBoundaries() {
        // Fixed vectors from Python hashlib/OpenSSL, independent of either Swift implementation.
        let vectors: [(Int, String)] = [
            (55, "463eb28e72f82e0a96c0a4cc53690c571281131f672aa229e0d45ae59b598b59"),
            (56, "da2ae4d6b36748f2a318f23e7ab1dfdf45acdc9d049bd80e59de82a60895f562"),
            (63, "29af2686fd53374a36b0846694cc342177e428d1647515f078784d69cdb9e488"),
            (64, "fdeab9acf3710362bd2658cdc9a29e8f9c757fcf9811603a8c447cd1d9151108"),
            (65, "4bfd2c8b6f1eec7a2afeb48b934ee4b2694182027e6d0fc075074f2fabb31781"),
            (1024, "785b0751fc2c53dc14a4ce3d800e69ef9ce1009eb327ccf458afe09c242c26c9"),
        ]
        for (count, expected) in vectors {
            let data = Data((0..<count).map { UInt8(truncatingIfNeeded: $0) })
            XCTAssertEqual(PortableSHA256.digest(data), expected)
            XCTAssertEqual(ArtifactStore.digest(data), expected)
        }
    }

    #if os(macOS)
    func testMacIgnoresXDGStateHome() {
        XCTAssertEqual(Paths.fromEnvironment(["XDG_STATE_HOME": "/tmp/xdg-state"]).home.path,
                       FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gentlemerge").path)
    }
    #endif

    func testExplicitHomeOverridesXDGStateHome() {
        XCTAssertEqual(Paths.fromEnvironment([
            "GENTLEMERGE_HOME": "/tmp/explicit-inbox",
            "XDG_STATE_HOME": "/tmp/xdg-state",
        ]).home.path, "/tmp/explicit-inbox")
    }

    #if os(Linux)
    func testLinuxUsesXDGStateHome() {
        XCTAssertEqual(Paths.fromEnvironment(["XDG_STATE_HOME": "/tmp/xdg-state"]).home.path,
                       "/tmp/xdg-state/gentlemerge")
    }

    func testLinuxFallsBackToLegacyHomeForMissingOrInvalidXDG() {
        let expected = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gentlemerge").path
        for environment in [[:], ["XDG_STATE_HOME": ""], ["XDG_STATE_HOME": "relative"]] {
            XCTAssertEqual(Paths.fromEnvironment(environment).home.path, expected)
        }
    }

    func testLinuxTerminalBridgeHasNoDeliveryChannel() {
        let bridge = TerminalBridge()
        XCTAssertEqual(bridge.focus(tty: "/dev/pts/1", terminalProgram: "xterm"), .unsupported("no delivery channel on this platform"))
        XCTAssertEqual(bridge.send(text: "hello", tty: "/dev/pts/1", terminalProgram: "xterm"), .unsupported("no delivery channel on this platform"))
    }
    #endif
}
