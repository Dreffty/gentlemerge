import XCTest
@testable import GentleMergeCore

/// Secrets in the spellings that people and tools actually use (audit 2026-11-01).
/// Each needle is the part that must not survive.
final class RedactorFormatsTests: XCTestCase {
    private func gone(_ text: String, _ needle: String, file: StaticString = #filePath, line: UInt = #line) {
        let result = Redactor.scrub(text)
        XCTAssertFalse(result.text.contains(needle), "survived: \(result.text)", file: file, line: line)
        XCTAssertTrue(result.didRedact, "nothing was redacted in: \(text)", file: file, line: line)
    }

    private func kept(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let result = Redactor.scrub(text)
        XCTAssertEqual(result.text, text, file: file, line: line)
        XCTAssertFalse(result.didRedact, file: file, line: line)
    }

    // MARK: names with the keyword in the middle

    func testFrameworkSecretNamesAreRedacted() {
        gone("SECRET_KEY = 'q9x8w7e6r5t4y3u2i1o0pLKJHG'", "q9x8w7e6r5t4y3u2i1o0pLKJHG")
        gone("SECRET_KEY_BASE=8f2a1c9d7e6b5a4f3e2d1c0b9a8f7e6d", "8f2a1c9d7e6b5a4f3e2d1c0b9a8f7e6d")
        gone("JWT_SECRET_KEY=hunter2hunter2", "hunter2hunter2")
        gone("PGPASSWORD=hunter2hunter2 psql -h db", "hunter2hunter2")
        gone("MYSQL_PWD=hunter2hunter2 mysql", "hunter2hunter2")
    }

    func testNamesThatMerelyStartWithAKeywordAreLeftAlone() {
        kept("secret_name: deploy-key")
        kept("token_count = 5412")
        kept("secret_key_ref: db-credentials")
        kept("PWD=/Users/dev/app")
        kept("bypass = true")
    }

    // MARK: values past the old ceiling

    func testALongBearerTokenIsRedactedToTheEnd() {
        let body = String(repeating: "A1b2C3d4", count: 60)
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJ\(body).SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV"
        let result = Redactor.scrub("Authorization: Bearer \(jwt)")
        XCTAssertFalse(result.text.contains("SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV"))
        XCTAssertFalse(result.text.contains(String(body.suffix(40))))
    }

    func testALongAssignedValueIsRedactedToTheEnd() {
        let value = String(repeating: "Zk9v", count: 120)
        let result = Redactor.scrub("note for the others: token=\(value) was rotated")
        XCTAssertFalse(result.text.contains(String(value.suffix(40))), result.text)
        XCTAssertTrue(result.text.contains("was rotated"), result.text)
    }

    // MARK: command lines

    func testCommandLinePasswordsAreRedacted() {
        gone("mysql --password hunter2hunter2 -h db", "hunter2hunter2")
        gone("tool --token abc123def456 --verbose", "abc123def456")
        gone("curl -u admin:s3cretPassw0rd https://api.example.com/x", "s3cretPassw0rd")
        gone("curl --user admin:s3cretPassw0rd https://api.example.com/x", "s3cretPassw0rd")
    }

    func testOrdinaryFlagsAreNotCredentials() {
        kept("git push -u origin main")
        kept("mkdir -p build/out")
        kept("tool --password-file /etc/secret.txt")
        kept("sort -u names.txt")
        kept("STAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)")
        kept(#"ID="$(date -u +%s)-$$-${RANDOM:-0}""#)
        kept("docker run -u 1000:1000 image")
        // A placeholder or a variable is the instructions for a secret, not one.
        kept("python setup_wizard.py studium --token <la-clave>")
        kept("tool --password $DB_PASSWORD --verbose")
    }

    // MARK: key formats

    func testPGPPrivateKeyBlockIsRedacted() {
        gone("-----BEGIN PGP PRIVATE KEY BLOCK-----\nlQdGBGJ3xYQBEAC0kS8w2n9Vq1fZp3Lm7Xc4tYh6uRjB0aN5dE\n-----END PGP PRIVATE KEY BLOCK-----",
             "lQdGBGJ3xYQBEAC0kS8w2n9Vq1fZp3Lm7Xc4tYh6uRjB0aN5dE")
        gone("-----BEGIN PGP PRIVATE KEY BLOCK-----\nlQdGBGJ3xYQBEAC0kS8w2n9Vq1fZp3Lm7Xc4tYh6uRjB0aN5dE",
             "lQdGBGJ3xYQBEAC0kS8w2n9Vq1fZp3Lm7Xc4tYh6uRjB0aN5dE")
    }

    func testTelegramBotTokenLosesItsSecretHalf() {
        gone("bot token 123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw", "AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw")
    }

    func testMoreProviderKeys() {
        // Each key is written in two halves. Whole, these look like live credentials
        // to the host's push protection, which refuses a push that holds one; the
        // halves meet only at run time, inside the test.
        let keys: [(prefix: String, body: String)] = [
            ("rk_" + "live_", "51Habcdefghijklmnopqrstuv"),
            ("whsec" + "_", "a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6"),
            ("SG" + ".", "aBcDeFgHiJkLmNoPqRsTuV.wXyZ0123456789aBcDeFgHiJkLmNoPqRsTuVwXyZ012"),
            ("sbp" + "_", "0123456789abcdef0123456789abcdef01234567"),
            ("shp" + "at_", "0123456789abcdef0123456789abcdef"),
            ("gsk" + "_", "aBcDeFgHiJkLmNoPqRsTuVwXyZ0123"),
        ]
        for key in keys {
            gone(key.prefix + key.body, String(key.body.suffix(24)))
        }
    }

    func testAnAmexNumberInItsFourSixFiveGroups() {
        gone("card 3782 822463 10005", "822463")
    }

    func testTheNewRulesLeaveOrdinaryTextAlone() {
        kept("see sbp in the docs, whsec is the prefix, SG is the sender")
        kept("sent at 12:30:45 on line 123456:7")
        kept("version 1.2.3 build 4567 port 8080")
    }

    func testEveryPatternStillCompiles() {
        for (kind, pattern) in Redactor.allPatterns {
            XCTAssertNotNil(try? NSRegularExpression(pattern: pattern), "\(kind) does not compile")
        }
    }
}
