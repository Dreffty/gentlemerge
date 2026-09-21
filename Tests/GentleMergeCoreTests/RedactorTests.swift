import XCTest
@testable import GentleMergeCore

// synthetic fixtures, never real: every secret-looking string below is shaped
// to trip the filter (right prefix, right length) but carries no real
// credential — TEST…FAKE, example.invalid, sequential digits, Stripe's
// documented test card. Nothing here must ever look like it could work.
final class RedactorTests: XCTestCase {
    private func scrub(_ text: String) -> Redactor.Result { Redactor.scrub(text) }

    // MARK: - What must never reach another agent

    func testSecretsAreTakenOut() {
        let cases: [(String, Redactor.Kind)] = [
            ("escríbele a agent@example.invalid sobre el bug", .email),
            ("usa la key sk-TEST0000000000000000FAKE", .apiKey),
            ("el token de github es ghp_TEST00000000000000000000FAKE", .apiKey),
            ("credenciales AKIAFAKEFAKEFAKEFAKE en el script", .apiKey),
            ("prueba con AIzaTEST00000000000000000000FAKE", .apiKey),
            ("la de nvidia es nvapi-TEST000000000000FAKE", .apiKey),
            ("manda eyJhbGciOiJGRUtFIn0.eyJzdWIiOiJGQUtFIn0.FAKESIG123456", .jwt),
            ("clona https://agent:FAKEPASSWORD123@github.com/org/repo", .credentialsInURL),
            ("password: fakepassword123", .assignedSecret),
            ("API_KEY=FAKEKEY1234567890", .assignedSecret),
            ("mi teléfono es 1234567890 por si acaso", .longNumber),
            ("la tarjeta 4242 4242 4242 4242 caducó", .card),
        ]

        for (text, expected) in cases {
            let result = scrub(text)
            XCTAssertTrue(result.kinds.contains(expected), "no detectó \(expected) en: \(text)")
            XCTAssertFalse(
                result.text.contains("fakepassword123") && expected == .assignedSecret,
                "the value survived: \(result.text)"
            )
        }
    }

    func testTheSecretItselfIsGoneFromTheOutput() {
        let result = scrub("la clave es sk-TEST0000000000000000FAKE y ya está")
        XCTAssertFalse(result.text.contains("TEST0000000000000000FAKE"))
        XCTAssertTrue(result.text.contains("[redacted key]"))
    }

    func testAPrivateKeyBlockGoesWhole() {
        let key = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        FAKEKEYCONTENTFAKEKEYCONTENTFAKEKEYCONTENT
        -----END OPENSSH PRIVATE KEY-----
        """
        let result = scrub("esto estaba en el fichero:\n\(key)")
        XCTAssertFalse(result.text.contains("FAKEKEYCONTENT"))
        XCTAssertTrue(result.kinds.contains(.privateKey))
    }

    func testAssignedSecretsKeepTheirNameSoTheSentenceStillReads() {
        let result = scrub("pon password: fakepassword123 en el .env")
        XCTAssertTrue(result.text.contains("password: [redacted]"), result.text)
        XCTAssertTrue(result.text.contains("en el .env"), "el resto de la frase se queda")
    }

    // MARK: - What must survive, or the filter gets turned off

    func testOrdinaryNumbersAreNotSecrets() {
        let harmless = [
            "arregla el bug de la línea 42",
            "el puerto 8080 está ocupado",
            "mira los 3 últimos commits",
            "actualiza a la versión 2.1.217",
            "el commit 5d0eac3 rompió el build",
            "tarda 1500 ms en arrancar",
            "revisa src/HomeView.tsx y el .env.example",
            "quedan 12 tareas abiertas de 2026",
        ]

        for text in harmless {
            let result = scrub(text)
            XCTAssertFalse(result.didRedact, "se cargó algo inocente: \(text) → \(result.text)")
            XCTAssertEqual(result.text, text)
        }
    }

    func testAnEmptyOrPlainMessageIsUntouched() {
        XCTAssertEqual(scrub("").text, "")
        XCTAssertFalse(scrub("he migrado el schema de misiones").didRedact)
    }

    // MARK: - When almost nothing is left

    /// Suppression is about length, not content: the placeholder is 15
    /// characters, so a lone secret only vanishes when the secret is longer
    /// than twice that. Same TEST…FAKE family, padded past 30 characters.
    func testAMessageThatIsOnlyASecretIsWithheld() {
        let result = scrub("sk-TEST0000000000000000000000FAKE")
        XCTAssertTrue(result.isSuppressed)
        XCTAssertFalse(result.summary.isEmpty)
    }

    func testAMessageWithRealContentSurvivesTheRedaction() {
        let result = scrub(
            "he desplegado el backend y he dejado la clave en 1Password, escríbeme a agent@example.invalid si falla"
        )
        XCTAssertFalse(result.isSuppressed)
        XCTAssertTrue(result.text.contains("he desplegado el backend"))
        XCTAssertTrue(result.text.contains("[redacted email]"))
    }

    func testTheSummaryNamesWhatWasFound() {
        let result = scrub("escribe a agent@example.invalid con la key sk-TEST0000000000000000FAKE")
        XCTAssertTrue(result.summary.contains("API key"), result.summary)
        XCTAssertTrue(result.summary.contains("email"), result.summary)
    }

    // MARK: - What another agent sees

    func testSharedReturnsAStubNeverSilence() {
        let stub = Redactor.shared("sk-TEST0000000000000000000000FAKE")
        XCTAssertNotNil(stub)
        XCTAssertTrue(stub!.contains("withheld"), stub ?? "")
        XCTAssertTrue(stub!.contains("API key"), stub ?? "")
        XCTAssertFalse(stub!.contains("TEST0000"), "the stub names the kind, never the content")
    }

    func testSharedStillReturnsNilForNothing() {
        XCTAssertNil(Redactor.shared(nil))
        XCTAssertNil(Redactor.shared(""))
    }

    // MARK: - Adversarial formats

    /// Real-world secret shapes, TEST-marked but structurally exact. If any of
    /// these ever passes through, the rule regressed — add, never weaken.
    func testRealWorldKeyFormatsAreCaught() {
        let cases: [(text: String, placeholder: String)] = [
            ("key AKIATEST000000000000 is in the env", "[redacted key]"),
            ("deploy with sk_live_TEST0000000000 tonight", "[redacted key]"),
            ("token ghp_TEST00000000000000000000 leaked", "[redacted key]"),
            ("Authorization: Bearer TEST0000000000000000", "[redacted]"),
            ("postgres://admin:s3cret123@db:5432/app", "[redacted credentials]"),
            ("iban ES91 2100 0418 4502 0005 1332 for the refund", "[redacted account]"),
            ("card 4111 1111 1111 1111 expired", "[redacted card]"),
            ("DB_PASSWORD: 'hunter2-hunter2'", "[redacted]"),
            ("export API_KEY=hunter2hunter2hunter2", "[redacted]"),
        ]
        for (text, placeholder) in cases {
            let result = scrub(text)
            XCTAssertTrue(result.didRedact, "missed: \(text)")
            XCTAssertTrue(result.text.contains(placeholder), "\(text) → \(result.text)")
        }
    }

    func testAJWTIsCaughtWhole() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.TESTPAYLOADTESTPAYLOADTEST.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJVadQssw5c"
        let result = scrub("send \(jwt) in the header")
        XCTAssertTrue(result.text.contains("[redacted token]"))
        XCTAssertFalse(result.text.contains("eyJhbGciOiJIUzI1NiJ9"))
    }

    /// What the filter deliberately does NOT catch, pinned so the gap stays a
    /// decision rather than drifting into a regression:
    /// - a 40-hex commit SHA must survive (git history is full of them);
    /// - a bare base64 blob is not fingerprinted (hashes and digests share
    ///   the alphabet; a rule for it would eat SHAs and checksums);
    /// - a secret split across lines is not reassembled.
    // MARK: - Terminal escapes are formatting, not content

    func testANSISequencesAreStrippedSilently() {
        let dirty = "\u{1B}[1;32mok\u{1B}[0m and \u{1B}]8;;https://x\u{07}link\u{1B}]8;;\u{07} done"
        let result = scrub(dirty)
        XCTAssertEqual(result.text, "ok and link done")
        XCTAssertFalse(result.didRedact, "stripping records no kind")
    }

    func testNonGoalsStayPinned() {        XCTAssertFalse(scrub("landed 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b").didRedact)
        XCTAssertFalse(scrub("checksum U2FsdGVkX19zYWx0ZWRLZXlBY2Nlc3NfdG9rZGVu").didRedact)
        XCTAssertFalse(scrub("ports 8080 3000, version 2.38.1, line 42").didRedact)
    }

    /// The compiled patterns are shared across threads (autoLand scrubs off
    /// the main thread while the drain scrubs on it). Hammer it concurrently;
    /// every answer must equal the serial one.
    func testConcurrentScrubsAgreeWithTheSerialAnswer() {
        let text = "despliega con sk-TEST0000000000000000FAKE y avisa a agent@example.invalid"
        let expected = scrub(text)
        let group = DispatchGroup()
        let box = ResultBox()
        for _ in 0..<32 {
            group.enter()
            DispatchQueue.global().async {
                let result = Redactor.scrub(text)
                if result != expected { box.note() }
                group.leave()
            }
        }
        group.wait()
        XCTAssertFalse(box.flagged)
    }
}

extension RedactorTests {
    /// A pattern that does not compile is skipped silently at runtime, which
    /// means the filter quietly stops filtering. This is the guard against that.
    func testEveryPatternCompiles() {
        for (kind, pattern) in Redactor.allPatterns {
            XCTAssertNoThrow(
                try NSRegularExpression(pattern: pattern),
                "la regla \(kind.rawValue) no compila: no filtraría nada"
            )
        }
    }
}

/// Locked flag for the concurrency test: XCTest assertions must run on the
/// test thread, so workers only record.
private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    func note() {
        lock.lock()
        storage = true
        lock.unlock()
    }

    var flagged: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
