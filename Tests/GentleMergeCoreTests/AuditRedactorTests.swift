import XCTest
@testable import GentleMergeCore

/// The long-number rule broke file paths and dates; it must keep hiding real numbers.
final class RedactorLongNumberTests: XCTestCase {
    private func scrubbed(_ text: String) -> String { Redactor.scrub(text).text }

    func testADigitFolderInAFilePathSurvives() {
        for path in ["/backups/20261026/log.txt", "/var/run/1234567890/app.sock", "~/Downloads/87654321/x.md",
                     "./out/12345678901/report.html", "../runs/9876543210/a.txt"] {
            XCTAssertEqual(scrubbed("see \(path) for the log"), "see \(path) for the log", path)
        }
        XCTAssertEqual(scrubbed("copied to '/srv/data/11223344/f' ok"), "copied to '/srv/data/11223344/f' ok")
    }

    func testACalendarDateSurvives() {
        XCTAssertEqual(scrubbed("build 20261026 is green"), "build 20261026 is green")
        XCTAssertEqual(scrubbed("release-20260101"), "release-20260101")
    }

    func testRealLongNumbersAreStillHidden() {
        XCTAssertEqual(scrubbed("account 21452098"), "account [redacted number]")
        XCTAssertEqual(scrubbed("mi teléfono es 1234567890 por si acaso"), "mi teléfono es [redacted number] por si acaso")
        XCTAssertEqual(scrubbed("call 611234567 now"), "call [redacted number] now")
        // 8 digits that are not a calendar date
        XCTAssertEqual(scrubbed("id 99881234"), "id [redacted number]")
        // a URL is not a file path, whatever it contains
        XCTAssertEqual(scrubbed("https://bank.example/accounts/12345678"), "https://bank.example/accounts/[redacted number]")
    }

    func testANumberOutsideAPathNextToOneIsStillHidden() {
        XCTAssertEqual(scrubbed("/tmp/x and 12345678"), "/tmp/x and [redacted number]")
    }
}
