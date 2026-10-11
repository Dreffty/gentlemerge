import XCTest
@testable import GentleMergeCore

/// A batch of small correctness fixes from docs/AUDIT_HANDOFF.md Tier 4 and 5.
/// Each one is a function that answers the wrong question, or a tie broken by
/// nothing at all.
final class SpecificityAndParsingTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("spec-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - #20 which zone owns a path

    /// Ranking by the literal prefix alone threw away everything after the first
    /// wildcard, so a pattern naming an exact file could lose to one naming a
    /// directory, and two different patterns could tie and be separated only by
    /// their order in the file.
    func testTheMostSpecificZoneOwnsAPath() {
        let ownership = Ownership(rules: [
            .init(pattern: "lib/**", owner: "claude"),
            .init(pattern: "**/models.dart", owner: "codex"),
        ])
        XCTAssertEqual(
            ownership.owner(of: "lib/models.dart"), "codex",
            "a pattern naming an exact file is more specific than one naming a directory"
        )
        XCTAssertEqual(ownership.owner(of: "lib/store/x.dart"), "claude")
        XCTAssertEqual(ownership.owner(of: "other/models.dart"), "codex")
    }

    /// The case the handoff could not classify: declaration order used to decide.
    func testEqualCountsNoLongerDependOnDeclarationOrder() {
        let a = Ownership(rules: [
            .init(pattern: "lib/store/**", owner: "A"),
            .init(pattern: "lib/*", owner: "B"),
        ])
        let b = Ownership(rules: [
            .init(pattern: "lib/*", owner: "B"),
            .init(pattern: "lib/store/**", owner: "A"),
        ])
        XCTAssertEqual(a.owner(of: "lib/store/x.dart"), "A")
        XCTAssertEqual(
            a.owner(of: "lib/store/x.dart"), b.owner(of: "lib/store/x.dart"),
            "the same two patterns must resolve the same way in either order"
        )
    }

    func testTheLongestLiteralRunWins() {
        let ownership = Ownership(rules: [
            .init(pattern: "lib/api/**", owner: "api-owner"),
            .init(pattern: "lib/**/generated/**", owner: "gen-owner"),
        ])
        XCTAssertEqual(
            ownership.owner(of: "lib/api/generated/x"), "gen-owner",
            "\"generated/\" is the longer literal run"
        )
    }

    func testUnrelatedPathsStillHaveNoOwner() {
        let ownership = Ownership(rules: [.init(pattern: "lib/**", owner: "claude")])
        XCTAssertNil(ownership.owner(of: "assets/hero.png"))
    }

    // MARK: - #34 an absolute claim pattern must not silently protect nothing

    func testAnAbsolutePatternStillDescribesThePathItMeant() {
        XCTAssertTrue(
            Glob.matches("/Users/dev/code/app/lib/store/**", "lib/store/x.dart"),
            "an absolute claim must not match nothing"
        )
        XCTAssertTrue(Glob.matches("/abs/lib/store/**", "lib/store/x.dart"))
        // Relative behaviour is untouched.
        XCTAssertTrue(Glob.matches("lib/**", "lib/a.dart"))
        XCTAssertFalse(Glob.matches("lib/**", "assets/a.png"))
        XCTAssertTrue(Glob.matches("./lib/**", "lib/a.dart"))
        XCTAssertTrue(Glob.matches("lib/", "lib/a.dart"))
    }

    // MARK: - #35 counting a number out of a summary

    /// `range(of:)` found the *first* occurrence, and a summary can name the
    /// word before the count — inside a branch name — which made the count zero.
    func testTheCountIsTheNumberThatActuallyPrecedesTheWord() {
        XCTAssertEqual(
            Stats.count(before: "claim", in: "claim-fix -> main @ abc: 3 file(s), 1 claim(s) released"),
            1,
            "the word appears inside the branch name before the real count"
        )
        XCTAssertEqual(Stats.count(before: "path", in: "mypath/agent: 2 path(s) landed"), 2)
        XCTAssertEqual(Stats.count(before: "violation", in: "3 violation(s)"), 3)
        // Nothing numeric before it: still zero, not a crash and not the line count.
        XCTAssertEqual(Stats.count(before: "claim", in: "no numbers here at all"), 0)
        XCTAssertEqual(Stats.count(before: "claim", in: nil), 0)
        XCTAssertEqual(Stats.count(before: "claim", in: ""), 0)
        // Repeated with no number anywhere before any of them.
        XCTAssertEqual(Stats.count(before: "x", in: "x x x"), 0)
    }

    // MARK: - #19 a request decoded as .queued could never be accepted

    func testARequestWithAnUnreadableStateCanStillBeAccepted() throws {
        let paths = Paths(home: root.appendingPathComponent("home"))
        try paths.createDirectories()
        let store = Requests(paths: paths)
        let url = paths.requests.appendingPathComponent("req-broken.json")
        try FileManager.default.createDirectory(at: paths.requests, withIntermediateDirectories: true)

        // Written by a newer binary, or hand-edited: the `state` key is missing
        // or unknown, so it decodes to `.queued`.
        let json = """
        {"id":"req-broken","from":"claude","to":"codex","projectPath":"\(root.path)",
         "title":"t","spec":"s","budgetMinutes":30,"state":"queued-v2-future"}
        """
        try json.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertEqual(store.load("req-broken")?.state, .queued)
        XCTAssertNoThrow(
            try store.transition("req-broken", to: .inProgress, by: "codex", result: nil),
            "accept must work, or a stale file is permanently un-actionable"
        )
        XCTAssertEqual(store.load("req-broken")?.state, .inProgress)
    }

    // MARK: - #42 equal counts came out in reverse alphabetical order

    func testEqualCountsSortAlphabetically() throws {
        var scan = ProjectMap.Scan()
        scan.byTopLevel = ["Tests": 30, "Sources": 30, "Docs": 10]
        let top = ProjectMap.topDirectories(scan)
        XCTAssertEqual(Array(top.prefix(2)), ["Sources (30)", "Tests (30)"])
    }
}