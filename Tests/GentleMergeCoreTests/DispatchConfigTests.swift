import XCTest
@testable import GentleMergeCore

final class DispatchConfigTests: XCTestCase {
    /// The three opt-ins stay decisions, never defaults — and claims stay a
    /// warning until somebody says otherwise.
    func testDangerousDefaultsAreOff() {
        let config = AppConfig()
        XCTAssertFalse(config.allowNudges)
        XCTAssertFalse(config.allowDispatch)
        XCTAssertFalse(config.autoLand)
        XCTAssertEqual(config.claimsPolicy, "warn")
    }

    func testLegacyAndMalformedConfigurationKeepsDispatchOff() throws {
        for json in ["{}", #"{"playSound":false,"allowDispatch":"yes","dispatchQuietPeriod":"bad"}"#] {
            let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
            XCTAssertFalse(config.allowDispatch)
            XCTAssertEqual(config.dispatchAutoApproveMinutes, 15)
            XCTAssertEqual(config.dispatchAutoApproveTiers, ["cheap"])
            XCTAssertEqual(config.dispatchQuietPeriod, 300)
            XCTAssertEqual(config.agents, [])
        }
        let json = #"{"playSound":false,"allowDispatch":true,"agents":[{"label":"worker","capabilities":["tests"],"command":["/usr/bin/true"],"costTier":"cheap"}]}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        XCTAssertFalse(config.playSound)
        XCTAssertTrue(config.allowDispatch)
        XCTAssertEqual(config.agents.first?.label, "worker")
        XCTAssertEqual(try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config)), config)
    }
}
