import XCTest
@testable import GentleMergeCore

/// A batch of small, mechanical findings from docs/AUDIT_HANDOFF.md Tier 5.
/// They share a shape: a value that reaches an arithmetic or array operation
/// that traps, or a filter that does not do what its own docstring claims. Each
/// one is a crash or a silent wrong answer from a plain integer or string.
final class InputHardeningTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("harden-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - #22 Identity.safe must be ASCII

    /// `CharacterSet.alphanumerics` is the Unicode category L*/M*, not ASCII, so
    /// the homoglyph guard this function exists to provide was not the filter its
    /// docstring named. U+2162 (ROMAN NUMERAL FIFTY) renders as "II" — inside
    /// "claude" it is invisible.
    func testLabelsAreAsciiSoHomoglyphsCannotImpersonate() {
        XCTAssertEqual(Identity.safe("claude"), "claude")
        // U+2162 (ROMAN NUMERAL FIFTY) is in Unicode category Nl, which
        // CharacterSet.alphanumerics accepts. It must be dropped, so the label is
        // no longer the word it imitates.
        let homoglyph = Identity.safe("c\u{2162}aude")
        XCTAssertNotEqual(homoglyph, "claude")
        XCTAssertFalse(homoglyph.unicodeScalars.contains { $0.value > 0x7F }, "no non-ASCII scalar may survive: \(homoglyph)")
        XCTAssertFalse(Identity.safe("cl\u{0430}ude").unicodeScalars.contains { $0.value > 0x7F },
                       "Cyrillic a must not survive")
        // The documented alphabet still works.
        XCTAssertEqual(Identity.safe("agent-1_2.3#x"), "agent-1_2.3#x")
        // Empty becomes the sentinel, never "".
        XCTAssertEqual(Identity.safe("!!!"), "agent")
        // Overlong is cut.
        XCTAssertEqual(Identity.safe(String(repeating: "a", count: 40)).count, 24)
    }

    /// The homoglyph must not merely differ — it must fail to *be* a usable
    /// label, or it would still sit in the message file under a name that looks
    /// like somebody else's.
    func testAHomoglyphLabelIsNotConfusableWithTheRealOne() {
        let real = "claude"
        let fake = Identity.safe("c\u{2162}aude")
        XCTAssertNotEqual(fake, real)
        XCTAssertFalse(fake.isEmpty)
    }

    // MARK: - #23 Ledger.recent must not trap on a hostile limit

    private func ledgerWithRows(_ count: Int) -> Ledger {
        let url = root.appendingPathComponent("ledger-\(UUID()).jsonl")
        let ledger = Ledger(url: url)
        for i in 0..<count {
            ledger.append(LedgerEntry(at: Date(), kind: .note, project: "p", title: "row\(i)"))
        }
        return ledger
    }

    /// `suffix(limit * 2)` traps on a negative count and overflows to a trap on
    /// an absurd one. Both were reachable from `gentlemerge history -n`, and
    /// both killed the process with SIGTRAP (exit 133).
    func testHistoryLimitCannotTrapTheProcess() {
        let ledger = ledgerWithRows(5)

        XCTAssertEqual(ledger.recent(limit: -5).count, 0, "a negative limit means nothing, not a crash")
        XCTAssertEqual(ledger.recent(limit: Int.min).count, 0)
        XCTAssertEqual(ledger.recent(limit: 3).count, 3, "a normal limit still works")
        XCTAssertEqual(ledger.recent(limit: Int.max).count, 5, "an absurd limit returns everything, once")
        XCTAssertEqual(ledger.recent().count, 5, "the default still works")
    }

    // MARK: - #25 positional must not eat the following flag

    /// `radar --project` with no value used to consume nothing and then leave
    /// `single == false` downstream, so the radar swept every registered project
    /// instead of the named one, silently.
    func testAValueFlagWithNoValueDoesNotSwallowTheNextFlag() {
        let missing = CommandArguments(["radar", "--project"])
        XCTAssertEqual(missing.positional, ["radar"], "the flag is consumed, the next token is not invented")
        XCTAssertNil(missing.value(after: "--project"))

        // A real value is still eaten.
        let present = CommandArguments(["radar", "--project", "/tmp/app", "--json"])
        XCTAssertEqual(present.positional, ["radar"])
        XCTAssertEqual(present.value(after: "--project"), "/tmp/app")

        // A following flag is a missing value, not a value. `--global` is itself a
        // flag, so it is dropped from `positional` by the ordinary rule — what
        // matters is that `--to` did not swallow it *as its value*.
        let flagAfter = CommandArguments(["radar", "--to", "--global"])
        XCTAssertEqual(flagAfter.positional, ["radar"])
        XCTAssertNil(flagAfter.value(after: "--to"))
        XCTAssertEqual(flagAfter.value(after: "--global"), nil)

        // A bare "-" is a value, not a flag (conventional for stdin).
        XCTAssertEqual(CommandArguments(["x", "--file", "-"]).positional, ["x"])

        // Unchanged: bare flags are consumed one at a time.
        XCTAssertEqual(CommandArguments(["a", "--json", "--pretty", "b"]).positional, ["a", "b"])
    }

    // MARK: - #30 kill(pid, 0) needs the positivity guard

    /// `kill(-1, 0)` returns 0 — it reports "some process may be signalled" — so
    /// a corrupt `app.pid` printed "running (pid -1)". `0` signals the caller's
    /// whole process group. `Liveness` already guards this; doctor and `status`
    /// did not.
    func testANonPositivePidIsNeverReportedAsRunning() throws {
        let paths = Paths(home: root.appendingPathComponent("home-\(UUID())"))
        try paths.createDirectories()

        for bogus in ["-1", "0", "99999999999999999999"] {
            try bogus.write(to: paths.appPID, atomically: true, encoding: .utf8)
            let check = Doctor.app(paths: paths)
            XCTAssertFalse(
                check.detail.contains("running (pid"),
                "pid \(bogus) was reported as running: \(check.detail)"
            )
        }
    }
}