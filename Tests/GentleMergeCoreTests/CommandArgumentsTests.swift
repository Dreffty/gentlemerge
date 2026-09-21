import XCTest
@testable import GentleMergeCore

/// Three bugs shipped in one commit and every one of them was here, in code
/// nothing could reach: taking a command line apart lived inside the CLI, whose
/// only test was running the binary and looking at it.
final class CommandArgumentsTests: XCTestCase {
    // MARK: - Reading a value

    func testAFlagGivesUpTheArgumentAfterIt() {
        let arguments: CommandArguments = ["say", "hola", "--to", "codex"]
        XCTAssertEqual(arguments.value(after: "--to"), "codex")
    }

    func testAFlagThatIsNotThereHasNoValue() {
        let arguments: CommandArguments = ["say", "hola"]
        XCTAssertNil(arguments.value(after: "--to"))
    }

    func testAFlagAtTheEndHasNoValue() {
        let arguments: CommandArguments = ["say", "hola", "--to"]
        XCTAssertNil(arguments.value(after: "--to"))
    }

    /// `--to --global` is somebody who forgot to say who. Reading "--global" as
    /// the addressee would route the note to an agent of that name, which is to
    /// say to nobody.
    func testAnotherFlagIsNotAValue() {
        let arguments: CommandArguments = ["say", "hola", "--to", "--global"]
        XCTAssertNil(arguments.value(after: "--to"))
    }

    func testARepeatableFlagGivesUpEveryValue() {
        let arguments: CommandArguments = ["say", "x", "--attach", "a.txt", "--attach", "b.txt"]
        XCTAssertEqual(arguments.values(after: "--attach"), ["a.txt", "b.txt"])
    }

    // MARK: - What is left over

    func testPositionalArgumentsAreWhatIsNotAFlag() {
        let arguments: CommandArguments = ["add", "arreglar el tablón", "--by", "claude"]
        XCTAssertEqual(arguments.positional, ["add", "arreglar el tablón"])
    }

    /// The failure the declaration exists to prevent, pinned as a test: with
    /// `--project` declared, the path it eats is not mistaken for text.
    func testADeclaredFlagDoesNotLeakItsValueIntoTheText() {
        let arguments: CommandArguments = ["add", "fix it", "--project", "/tmp/x"]
        XCTAssertEqual(arguments.positional, ["add", "fix it"])
        XCTAssertFalse(arguments.positional.contains("/tmp/x"))
    }

    /// And the same line with the flag *not* declared, so the cost of
    /// forgetting is written down rather than rediscovered. This is exactly
    /// what `say --replaces 3f8a "…"` did: the handle ended up inside the note.
    func testAnUndeclaredFlagLeaksItsValueIntoTheText() {
        let arguments: CommandArguments = ["say", "--not-declared", "3f8a", "la nota"]
        // "3f8a" is the flag's value and has no business being here; it is, and
        // that is the bug. ("say" belongs — it is the subcommand.)
        XCTAssertEqual(arguments.positional, ["say", "3f8a", "la nota"])
        XCTAssertFalse(
            CommandArguments.valueFlags.contains("--not-declared"),
            "if this ever becomes a real flag, the test above is the one that will tell you"
        )
    }

    func testAFlagWithNoValueIsJustDropped() {
        let arguments: CommandArguments = ["say", "hola", "--global", "--nudge"]
        XCTAssertEqual(arguments.positional, ["say", "hola"])
    }

    func testContainsFindsABareFlag() {
        let arguments: CommandArguments = ["say", "hola", "--global"]
        XCTAssertTrue(arguments.contains("--global"))
        XCTAssertFalse(arguments.contains("--urgent"))
    }

    func testAnEmptyCommandLineIsNotAnError() {
        let arguments = CommandArguments([])
        XCTAssertTrue(arguments.positional.isEmpty)
        XCTAssertNil(arguments.value(after: "--to"))
    }

    // MARK: - The invariant that was broken

    /// Every flag the CLI reads a value from has to be declared as one that
    /// eats its argument. Forgetting is silent: the command works, and the
    /// value it consumed turns up inside whatever the command reads as text.
    ///
    /// Checked against the source because that is where the mistake is made.
    /// Adding a flag to one list and not the other is the whole bug, and no
    /// amount of testing the parser in isolation would ever catch it.
    func testEveryFlagTheCLIReadsAValueFromIsDeclared() throws {
        let cli = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // GentleMergeCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Sources/GentleMerge/CLI.swift")

        let source = try XCTUnwrap(
            try? String(contentsOf: cli, encoding: .utf8),
            "could not read \(cli.path) — if the CLI moved, point this at its new home rather than deleting it"
        )

        let pattern = try NSRegularExpression(pattern: #"values?\(after: "([^"]+)""#)
        let matches = pattern.matches(in: source, range: NSRange(source.startIndex..., in: source))
        XCTAssertFalse(matches.isEmpty, "found no flag reads at all, which means this test stopped testing anything")

        let read = Set(matches.compactMap { match -> String? in
            Range(match.range(at: 1), in: source).map { String(source[$0]) }
        })
        let undeclared = read.subtracting(CommandArguments.valueFlags).sorted()

        XCTAssertTrue(
            undeclared.isEmpty,
            "the CLI reads a value from \(undeclared.joined(separator: ", ")) but does not declare"
                + " it in CommandArguments.valueFlags, so that value will end up inside the"
                + " command's own text"
        )
    }
}
