import XCTest
@testable import GentleMergeCore

/// The same file, spelled two ways, is still one file.
final class GlobSpellingTests: XCTestCase {
    private let composed = "caf\u{e9}/men\u{fa}.txt"
    private let decomposed = "cafe\u{301}/menu\u{301}.txt"

    func testComposedAndDecomposedNamesAreOneFileForAWildcardClaim() {
        XCTAssertNotEqual(composed.unicodeScalars.count, decomposed.unicodeScalars.count)
        XCTAssertTrue(Glob.matches("caf\u{e9}/*.txt", decomposed))
        XCTAssertTrue(Glob.matches("cafe\u{301}/*.txt", composed))
        XCTAssertTrue(Glob.matches("cafe\u{301}/**", composed))
    }

    func testAPlainClaimStillMatchesEitherSpelling() {
        XCTAssertTrue(Glob.matches(composed, decomposed))
        XCTAssertTrue(Glob.matches("caf\u{e9}", decomposed))
    }

    func testTwoSpellingsOfTheSamePatternOverlap() {
        XCTAssertTrue(Glob.mayOverlap("caf\u{e9}/*.txt", "cafe\u{301}/*.txt"))
    }

    func testDotDotInTheMiddleCollapsesToTheRealPath() {
        XCTAssertTrue(Glob.matches("lib/../lib/x.txt", "lib/x.txt"))
        XCTAssertTrue(Glob.matches("lib/old/../store/**", "lib/store/a.dart"))
        XCTAssertEqual(Glob.normalize("a/b/../../c"), "c")
    }

    func testDotDotCannotCancelAWildcardOrEscapeTheStart() {
        XCTAssertEqual(Glob.normalize("**/../x"), "**/../x")
        XCTAssertEqual(Glob.normalize("../x"), "../x")
        XCTAssertEqual(Glob.normalize("../../x/./y"), "../../x/y")
    }

    func testAnAbsolutePathStaysAbsolute() {
        XCTAssertEqual(Glob.normalize("/x//y"), "/x/y")
        XCTAssertEqual(Glob.normalize("/a/../b"), "/b")
        XCTAssertEqual(Glob.normalize("/Users/../etc"), "/etc")
        XCTAssertEqual(Glob.normalize("/../x"), "/x")
        XCTAssertEqual(Glob.normalize("/plain/path"), "/plain/path")
        XCTAssertFalse(Glob.matches("etc/**", "/Users/../etc/hosts"), "/etc is not the repository's etc/")
    }

    func testNamesThatMerelyContainTwoDotsAreLeftAlone() {
        XCTAssertEqual(Glob.normalize("lib/a..b/c"), "lib/a..b/c")
        XCTAssertEqual(Glob.normalize("lib/..hidden/c"), "lib/..hidden/c")
    }
}
