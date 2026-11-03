import XCTest
@testable import GentleMergeCore

/// Attachments are scrubbed and may be 2 MB; so is a pasted prompt. Text shaped to
/// make a backtracking rule rescan the rest of itself at every word boundary must
/// still be scrubbed in about the time it takes to read it (audit 2026-11-01).
final class RedactorSpeedTests: XCTestCase {
    private func assertQuick(_ text: String, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let start = Date()
        _ = Redactor.scrub(text)
        let seconds = Date().timeIntervalSince(start)
        XCTAssertLessThan(seconds, 5, "\(name): \(text.count) characters took \(seconds)s", file: file, line: line)
    }

    func testKebabCaseDoesNotMakeTheNameRuleQuadratic() {
        assertQuick(String(repeating: "a-", count: 200_000), "a-a-a")
    }

    func testDottedTextDoesNotMakeTheEmailAndURLRulesQuadratic() {
        assertQuick(String(repeating: "a.", count: 200_000), "a.a.a")
        assertQuick(String(repeating: "a-", count: 200_000) + "@x", "a-a-a@")
    }

    func testALongLineOfURLsDoesNotMakeTheCurlRuleQuadratic() {
        assertQuick(String(repeating: "see http://example.com/x ", count: 16_000), "many http")
        assertQuick(String(repeating: "curl http://e.com/x && ", count: 17_000), "many curl")
    }

    func testTheBoundsStillCatchWhatTheyAreFor() {
        XCTAssertFalse(Redactor.scrub("MY_APP_PROD_DB_ADMIN_PASSWORD=hunter2hunter2").text.contains("hunter2hunter2"))
        XCTAssertFalse(Redactor.scrub("mail first.last+tag@sub.example.co.uk now").text.contains("first.last"))
        XCTAssertFalse(Redactor.scrub("git+ssh://deploy:s3cretPassw0rd@host/repo").text.contains("s3cretPassw0rd"))
        let longCurl = "curl " + String(repeating: "-H 'X-A: b' ", count: 10) + "-u admin:s3cretPassw0rd https://x"
        XCTAssertFalse(Redactor.scrub(longCurl).text.contains("s3cretPassw0rd"))
    }
}
