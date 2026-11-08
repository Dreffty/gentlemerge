import XCTest
@testable import GentleMergeCore

/// A phone number written the way people write one, in groups, went through whole:
/// the long-number rule only sees a run of seven digits.
final class RedactorPhoneTests: XCTestCase {
    func testAnInternationalNumberInGroupsIsTakenOut() {
        for text in ["llámame al +34 612 345 678 mañana", "+34-612-345-678", "+1 415 555 0132", "+44 20 7946 0958"] {
            let result = Redactor.scrub(text)
            XCTAssertTrue(result.didRedact, text)
            XCTAssertFalse(result.text.contains("345"), result.text)
            XCTAssertFalse(result.text.contains("555 0132"), result.text)
        }
    }

    func testScrubbingTwiceChangesNothing() {
        let once = Redactor.scrub("llámame al +34 612 345 678").text
        XCTAssertEqual(Redactor.scrub(once).text, once)
    }

    /// What must stay: versions, sums, counts and short figures with a plus sign.
    func testOrdinaryFiguresStay() {
        for text in ["+1 on this", "975 tests, +12 today", "v2.1 +3 fixes", "C++ 20 and 17", "+34 está bien", "1 + 2 = 3"] {
            XCTAssertEqual(Redactor.scrub(text).text, text, text)
        }
    }
}
