import XCTest
@testable import GentleMergeCore

/// `TERM_PROGRAM` reaches `osascript` through `activities.json` and `state.json`,
/// and the value was interpolated into `tell application "<name>"` with only
/// `.app` stripped. A value containing a quote produced a script that ran
/// something else, with the app's Automation grant behind it.
///
/// `ScriptableTerminal` lives inside `#if os(macOS)` in `TerminalBridge.swift`
/// — AppleScript has no Linux surface — so this file is gated the same way. The
/// Linux CI job compiled it unconditionally and failed to find the type, which
/// made the whole package unbuildable there.
#if os(macOS)
final class TerminalScriptNameTests: XCTestCase {
    func testKnownTerminalsStillMapToTheirScriptingNames() {
        XCTAssertEqual(ScriptableTerminal.applicationName(for: "iTerm.app"), "iTerm2")
        XCTAssertEqual(ScriptableTerminal.applicationName(for: "iTerm2"), "iTerm2")
        XCTAssertEqual(ScriptableTerminal.applicationName(for: "ITERM"), "iTerm2")
        XCTAssertEqual(ScriptableTerminal.applicationName(for: "Apple_Terminal"), "Terminal")
        XCTAssertEqual(ScriptableTerminal.applicationName(for: "terminal"), "Terminal")
    }

    /// A real terminal name we do not have a case for must still come through.
    func testAnUnrecognisedButPlausibleNameIsKept() {
        XCTAssertEqual(ScriptableTerminal.applicationName(for: "Alacritty.app"), "Alacritty")
        XCTAssertEqual(ScriptableTerminal.applicationName(for: "WezTerm"), "WezTerm")
    }

    /// The injection: `tell application "evil" to quit to activate` is a
    /// different instruction, and osascript runs it.
    func testQuotesAndAppleScriptCannotEscapeTheName() {
        let hostile = [
            #"evil" to quit"#,
            #"evil" & "do shell script \"id\""#,
            "evil\" & (do shell script \"touch /tmp/pwned\") & \"",
            "a\nb",
            "Terminal\" to quit",
        ]
        for value in hostile {
            let name = ScriptableTerminal.applicationName(for: value)
            XCTAssertFalse(
                name.contains("\""), "a quote survived into an AppleScript string literal: \(name)"
            )
            XCTAssertFalse(name.contains("\n"), "a newline survived: \(name.debugDescription)")
            XCTAssertFalse(name.contains("&"), "an operator survived: \(name)")
        }
    }

    /// Nothing usable in, and the fallback is a real terminal rather than
    /// whatever the caller said.
    func testAnUnusableValueFallsBackToTerminal() {
        for junk in ["", "///", "\"\"\""] {
            XCTAssertEqual(
                ScriptableTerminal.applicationName(for: junk), "Terminal",
                "\(junk.debugDescription) must not name an application"
            )
        }
    }

    /// The property that makes the assembled `tell` safe: whatever survives is
    /// inert text *inside* the string literal, because no character that could
    /// close it is allowed through. "evil to quit" still reads as the words
    /// "evil to quit" inside the quotes, which is a missing application — not a
    /// second instruction.
    func testWhateverSurvivesStaysInsideTheStringLiteral() {
        let name = ScriptableTerminal.applicationName(for: #"evil" to quit"#)
        XCTAssertEqual(name, "evil to quit", "the words survive; only the delimiter is gone")
        XCTAssertFalse(name.contains("\""), "the literal cannot be closed early")
        XCTAssertFalse(name.contains("\\"), "no escape can be introduced")
    }
}
#endif
