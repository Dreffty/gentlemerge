import XCTest
@testable import GentleMergeCore

/// The bus is the one thing every agent reads. These are the ways it used to
/// lie: messages routed by provider instead of by name, lines lost to a race,
/// a second message in the same second swallowed, a log that grew forever, and
/// a "nothing has changed" that noticed the clock moving.
final class AgentBusTests: XCTestCase {
    private var root: URL!
    private var bus: AgentBus!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gentlemerge-bus-\(UUID().uuidString)")
        let paths = Paths(home: root)
        try paths.createDirectories()
        bus = AgentBus(paths: paths)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func working(_ id: String, task: String, in project: String = "/tmp/gameapp") -> AgentActivity {
        AgentActivity(
            id: id,
            provider: .claudeCode,
            projectPath: project,
            currentTask: task
        )
    }

    private let gameapp = "/tmp/gameapp"
    private let clipapp = "/tmp/clipapp"

    func testPruneRespectsLiveReaderCursors() throws {
        for k in 0..<5 {
            bus.post(AgentMessage(from: "w", text: "note \(k)"))
        }
        // No reader: the cap takes the oldest two.
        XCTAssertEqual(bus.pruneMessages(keepingAtMost: 3), 2)

        for k in 5..<10 {
            bus.post(AgentMessage(from: "w", text: "note \(k)"))
        }
        // A session that read recently pins everything newer than its floor,
        // even past the cap.
        let marker = AgentBus.DeliveryMarker(lastFingerprint: nil, lastMessageAt: .distantPast, deliveredIDs: [])
        try JSONCoding.encoder().encode(marker).write(to: bus.markerURL(for: "s1"))
        XCTAssertEqual(bus.pruneMessages(keepingAtMost: 3), 0)
        XCTAssertEqual(bus.messages().count, 8)
    }

    func testOldLinesWithoutAVersionDecodeAsOne() throws {
        let old: [String: JSONValue] = [
            "id": .string("x"), "at": .string("2026-01-01T00:00:00Z"),
            "from": .string("a"), "text": .string("hi"),
        ]
        let data = try JSONCoding.encoder().encode(old)
        let message = try JSONCoding.decoder().decode(AgentMessage.self, from: data)
        XCTAssertEqual(message.v, 1)
        XCTAssertEqual(message.text, "hi")
    }

    // MARK: - Withheld messages stay visible as stubs
    func testAWithheldMessageLeavesAStubAndALedgerLine() throws {
        let secret = "sk-TEST0000000000000000000000FAKE"
        bus.post(AgentMessage(from: "claude", text: secret))

        let stored = try XCTUnwrap(bus.messages().last)
        XCTAssertTrue(stored.text.contains("withheld"), stored.text)
        XCTAssertFalse(stored.text.contains("TEST0000"), "the stub names the kind, never the content")

        let ledger = try String(contentsOf: Paths(home: root).ledger, encoding: .utf8)
        XCTAssertTrue(ledger.contains("message.withheld"), ledger)
        XCTAssertTrue(ledger.contains("API key"), ledger)
        XCTAssertFalse(ledger.contains("TEST0000"), "the ledger names the kind, never the content")
    }

    // MARK: - Routing by label

    func testADirectedMessageReachesTheAgentItNames() throws {
        bus.post(AgentMessage(from: "claude", to: "codex", text: "el schema es tuyo"))

        let forCodex = try XCTUnwrap(bus.briefing(sessionID: "codex-1", me: "codex", project: nil))
        XCTAssertTrue(forCodex.contains("el schema es tuyo"))
    }

    func testADirectedMessageIsNotShownToSomebodyElse() {
        bus.post(AgentMessage(from: "claude", to: "codex", text: "el schema es tuyo"))

        XCTAssertNil(
            bus.briefing(sessionID: "hermes-1", me: "hermes", project: nil),
            "a note addressed to codex is none of hermes' business"
        )
    }

    func testAnAnonymousReadShowsDirectedMessagesAndSaysWhoTheyAreFor() throws {
        bus.post(AgentMessage(from: "claude", to: "codex", text: "el schema es tuyo"))

        // `brief` with no identity is how every tool without hooks reads the
        // bus. Hiding directed notes from it made them unreadable by anyone.
        let anonymous = try XCTUnwrap(bus.briefing(sessionID: nil, me: nil, project: nil))
        XCTAssertTrue(anonymous.contains("el schema es tuyo"))
        XCTAssertTrue(anonymous.contains("(for codex)"), "it says who it was meant for")
    }

    func testAnAnonymousReadMarksNothingAsDelivered() throws {
        bus.post(AgentMessage(from: "claude", to: "codex", text: "el schema es tuyo"))

        XCTAssertNotNil(bus.briefing(sessionID: nil, me: nil, project: nil))
        // Reading over somebody's shoulder does not take the message off their
        // pile.
        let forCodex = try XCTUnwrap(bus.briefing(sessionID: "codex-1", me: "codex", project: nil))
        XCTAssertTrue(forCodex.contains("el schema es tuyo"))
    }

    func testAnAgentIsStillNeverToldItsOwnMessage() {
        bus.post(AgentMessage(from: "codex", text: "voy a tocar el árbol"))

        XCTAssertNil(bus.briefing(sessionID: "codex-1", me: "codex", project: nil))
    }

    // MARK: - Concurrent writers

    func testAHundredWritersAtOnceLeaveAHundredReadableLines() throws {
        let bus = self.bus!
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            bus.post(AgentMessage(from: "writer-\(index)", text: "line \(index)"))
        }

        let contents = try String(contentsOf: bus.paths.messages, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 100, "no line was overwritten by another writer")

        let decoder = JSONCoding.decoder()
        let decoded = lines.compactMap { line -> AgentMessage? in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(AgentMessage.self, from: data)
        }
        XCTAssertEqual(decoded.count, 100, "no line was spliced into another")
        XCTAssertEqual(Set(decoded.map(\.from)).count, 100)
    }

    // MARK: - Two messages in the same second

    func testTwoMessagesInTheSameSecondAreBothDeliveredExactlyOnce() throws {
        // Timestamps are stored to the second, so these two are indistinguishable
        // by time alone — the old marker kept only the timestamp and lost one.
        let at = Date()
        bus.post(AgentMessage(at: at, from: "claude", text: "primero"))
        bus.post(AgentMessage(at: at, from: "claude", text: "segundo"))

        let first = try XCTUnwrap(bus.briefing(sessionID: "codex-1", me: "codex", project: nil))
        XCTAssertTrue(first.contains("primero"))
        XCTAssertTrue(first.contains("segundo"))

        XCTAssertTrue(
            bus.undelivered(to: "codex-1", me: "codex", project: nil).isEmpty,
            "and neither of them comes round again"
        )
        XCTAssertNil(bus.briefing(sessionID: "codex-1", me: "codex", project: nil))
    }

    func testAMarkerFromAnOlderBinaryStillSuppressesWhatItDelivered() throws {
        let at = Date()
        bus.post(AgentMessage(at: at, from: "claude", text: "ya entregado"))

        // No deliveredIDs: written by a binary that only knew about timestamps.
        let marker = AgentBus.DeliveryMarker(lastFingerprint: nil, lastMessageAt: at, deliveredIDs: nil)
        try AtomicFile.write(
            try JSONCoding.encoder().encode(marker),
            to: bus.markerURL(for: "codex-1")
        )

        XCTAssertTrue(
            bus.undelivered(to: "codex-1", me: "codex", project: nil).isEmpty,
            "an old marker keeps its strict floor rather than replaying the message"
        )
    }

    // MARK: - Pruning

    func testPruningDropsWhatIsPastTheCutoffAndKeepsTheRest() throws {
        let now = Date()
        for day in 1...4 {
            bus.post(AgentMessage(at: now.addingTimeInterval(-Double(day) * 24 * 3600), from: "claude", text: "day \(day)"))
        }
        for day in 8...10 {
            bus.post(AgentMessage(at: now.addingTimeInterval(-Double(day) * 24 * 3600), from: "claude", text: "old \(day)"))
        }

        let removed = bus.pruneMessages(olderThan: 7 * 24 * 3600, keepingAtMost: 500, now: now)
        XCTAssertEqual(removed, 3)

        let left = bus.messages()
        XCTAssertEqual(left.count, 4)
        XCTAssertTrue(left.allSatisfy { $0.text.hasPrefix("day") })
    }

    func testPruningKeepsTheMostRecentWhenThereAreTooMany() throws {
        let now = Date()
        for index in 0..<20 {
            bus.post(AgentMessage(at: now.addingTimeInterval(Double(index)), from: "claude", text: "m\(index)"))
        }

        XCTAssertEqual(bus.pruneMessages(keepingAtMost: 5, now: now.addingTimeInterval(20)), 15)

        let left = bus.messages().map(\.text)
        XCTAssertEqual(left, ["m15", "m16", "m17", "m18", "m19"])
    }

    func testPruningThrowsAwayLinesNobodyCanRead() throws {
        bus.post(AgentMessage(from: "claude", text: "buena"))
        // What the old unlocked append left behind: two writes on top of each
        // other. Nothing will ever decode it, so it only takes up room.
        try AtomicFile.append("{\"id\":\"x\",\"fr{\"id\":\"y\"}", to: bus.paths.messages)
        bus.post(AgentMessage(from: "codex", text: "otra"))

        XCTAssertEqual(bus.pruneMessages(), 1)
        XCTAssertEqual(bus.messages().map(\.text), ["buena", "otra"])
    }

    func testPruningAnUntouchedLogRewritesNothing() throws {
        bus.post(AgentMessage(from: "claude", text: "reciente"))
        let before = try Data(contentsOf: bus.paths.messages)

        XCTAssertEqual(bus.pruneMessages(), 0)
        XCTAssertEqual(try Data(contentsOf: bus.paths.messages), before)
    }

    // MARK: - A peer that only got older is not news

    func testTheFingerprintIgnoresTimePassing() throws {
        let activity = working("claude-1", task: "traduce constants a EN")
        bus.save([activity])

        let now = Date()
        let first = try XCTUnwrap(bus.briefing(sessionID: "codex-1", me: "codex", project: nil, now: now))
        XCTAssertTrue(first.contains("traduce constants"))

        // An hour later the rendered line reads "1h ago" instead of "just now".
        // That is not a change worth spending another turn's context on.
        XCTAssertNil(
            bus.briefing(sessionID: "codex-1", me: "codex", project: nil, now: now.addingTimeInterval(3600))
        )
        XCTAssertEqual(activity.fingerprintLine, "claude-1|working|traduce constants a EN")
    }

    func testAPeerThatStartedSomethingElseIsNews() throws {
        bus.save([working("claude-1", task: "traduce constants a EN")])
        let now = Date()
        XCTAssertNotNil(bus.briefing(sessionID: "codex-1", me: "codex", project: nil, now: now))

        bus.save([working("claude-1", task: "arregla el árbol")])
        XCTAssertNotNil(
            bus.briefing(sessionID: "codex-1", me: "codex", project: nil, now: now),
            "what it is doing changed, so say so"
        )
    }

    // MARK: - One project at a time

    func testASessionIsNotToldAboutAgentsInAnotherProject() throws {
        // The thing that actually happened: a session in clipapp was briefed
        // about the iOS simulator of Gameapp, every turn.
        bus.save([
            working("claude-1", task: "arregla el simulador de iOS", in: gameapp),
            working("codex-1", task: "corta el clip final", in: clipapp),
        ])

        let inClipapp = try XCTUnwrap(bus.briefing(sessionID: "me", me: "claude", project: clipapp))
        XCTAssertTrue(inClipapp.contains("corta el clip final"))
        XCTAssertFalse(inClipapp.contains("simulador de iOS"), "another project's work is not news here")
    }

    func testAScopedMessageStaysInItsProject() throws {
        bus.post(AgentMessage(from: "claude", projectPath: gameapp, text: "he tocado el árbol"))

        XCTAssertNil(
            bus.briefing(sessionID: "codex-1", me: "codex", project: clipapp),
            "a note about Gameapp is nothing to a session in clipapp"
        )
        let inGameapp = try XCTUnwrap(bus.briefing(sessionID: "codex-2", me: "codex", project: gameapp))
        XCTAssertTrue(inGameapp.contains("he tocado el árbol"))
    }

    func testAGlobalMessageStillReachesEveryProject() throws {
        // No projectPath is what `say --global` writes, and what every message
        // written before scoping existed already looks like: those must keep
        // arriving everywhere, with no migration.
        bus.post(AgentMessage(from: "claude", text: "voy a mergear main"))

        let inGameapp = try XCTUnwrap(bus.briefing(sessionID: "codex-1", me: "codex", project: gameapp))
        XCTAssertTrue(inGameapp.contains("voy a mergear main"))
        let inClipapp = try XCTUnwrap(bus.briefing(sessionID: "codex-2", me: "codex", project: clipapp))
        XCTAssertTrue(inClipapp.contains("voy a mergear main"))
    }

    func testTheAgentsElsewhereCostOneLineAndNoDetail() throws {
        bus.save([
            working("claude-1", task: "arregla el simulador de iOS", in: gameapp),
            working("claude-2", task: "traduce constants a EN", in: gameapp),
            working("codex-1", task: "corta el clip final", in: clipapp),
        ])

        let inClipapp = try XCTUnwrap(bus.briefing(sessionID: "me", me: "claude", project: clipapp))
        XCTAssertTrue(inClipapp.contains("+ 2 agents in other projects"))
        XCTAssertTrue(inClipapp.contains("gentlemerge who --all"), "and how to see them")
        XCTAssertFalse(inClipapp.contains("traduce constants"))
    }

    func testTheLineIsThereOnlyWhileSomebodyIsWorkingElsewhere() throws {
        bus.save([working("codex-1", task: "corta el clip final", in: clipapp)])
        let alone = try XCTUnwrap(bus.briefing(sessionID: "me", me: "claude", project: clipapp))
        XCTAssertFalse(alone.contains("in other projects"))
        XCTAssertFalse(alone.contains("in another project"))

        bus.save([
            working("codex-1", task: "corta el clip final", in: clipapp),
            working("claude-1", task: "arregla el simulador de iOS", in: gameapp),
        ])
        let accompanied = try XCTUnwrap(bus.briefing(sessionID: "me", me: "claude", project: clipapp))
        XCTAssertTrue(accompanied.contains("+ 1 agent in another project"))
    }

    func testWhatAnAgentElsewhereIsDoingNeverBreaksTheSilence() throws {
        bus.save([
            working("codex-1", task: "corta el clip final", in: clipapp),
            working("claude-1", task: "arregla el simulador de iOS", in: gameapp),
        ])
        let now = Date()
        XCTAssertNotNil(bus.briefing(sessionID: "me", me: "claude", project: clipapp, now: now))

        // The agent in the other project moved on to something else. This session
        // is not being told what that is, so it is not a reason to spend another
        // turn's context — the whole point of counting them instead of listing
        // them.
        bus.save([
            working("codex-1", task: "corta el clip final", in: clipapp),
            working("claude-1", task: "traduce constants a EN", in: gameapp),
        ])
        XCTAssertNil(bus.briefing(sessionID: "me", me: "claude", project: clipapp, now: now))

        // One more of them, though, changes the line that is actually shown.
        bus.save([
            working("codex-1", task: "corta el clip final", in: clipapp),
            working("claude-1", task: "traduce constants a EN", in: gameapp),
            working("claude-2", task: "sube la versión", in: gameapp),
        ])
        let updated = try XCTUnwrap(bus.briefing(sessionID: "me", me: "claude", project: clipapp, now: now))
        XCTAssertTrue(updated.contains("+ 2 agents in other projects"))
    }

    func testASessionAloneInItsProjectStillHearsAboutTheOthersOnce() throws {
        // No peers here at all: the count is the only thing to say, and it is
        // still worth saying — once.
        bus.save([working("claude-1", task: "arregla el simulador de iOS", in: gameapp)])

        let now = Date()
        let first = try XCTUnwrap(bus.briefing(sessionID: "me", me: "claude", project: clipapp, now: now))
        XCTAssertTrue(first.contains("+ 1 agent in another project"))
        XCTAssertNil(bus.briefing(sessionID: "me", me: "claude", project: clipapp, now: now))
    }

    // MARK: - Sessions that died

    /// A pid nothing is behind any more. Real, not invented: a number picked
    /// out of the air could belong to somebody else's live process.
    private func pidOfAProcessThatIsGone() throws -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["0.05"]
        try process.run()
        let pid = Int(process.processIdentifier)
        process.waitUntilExit()
        return pid
    }

    func testAProbeWithNoPidKnowsNothing() {
        // The distinction the whole feature rests on: unknown is not dead. Every
        // activity written before this existed has no pid.
        XCTAssertNil(Liveness.isProcessAlive(nil))
        XCTAssertNil(Liveness.isProcessAlive(0))
        XCTAssertEqual(Liveness.isProcessAlive(Int(getpid())), true)
    }

    func testASessionWhoseProcessIsGoneIsNoLongerAPeer() throws {
        var dead = working("claude-1", task: "traduce constants a EN")
        dead.pid = try pidOfAProcessThatIsGone()
        bus.save([dead])

        XCTAssertTrue(
            bus.others(excluding: "me").isEmpty,
            "the reader checks for itself: the app may not even be running"
        )
        XCTAssertNil(bus.briefing(sessionID: "me", me: "codex", project: gameapp))
    }

    func testASessionWithNoPidIsLeftAloneAsAPeer() throws {
        bus.save([working("claude-1", task: "traduce constants a EN")])

        XCTAssertEqual(bus.others(excluding: "me").map(\.id), ["claude-1"])
    }

    func testTheOnesThatDiedAreListedApartAndSayWhatHappened() throws {
        var dead = working("claude-1", task: "traduce constants a EN")
        dead.pid = try pidOfAProcessThatIsGone()
        var alive = working("codex-1", task: "corta el clip final")
        alive.pid = Int(getpid())
        bus.save([dead, alive])

        let died = bus.died()
        XCTAssertEqual(died.map(\.id), ["claude-1"])
        // Reported as dead even though nobody has swept the file yet — this is
        // what `who` prints, and it runs in a shell, not in the app.
        XCTAssertTrue(try XCTUnwrap(died.first).diedUncleanly)
        XCTAssertTrue(try XCTUnwrap(died.first?.briefingLine()).contains("(died just now)"))
    }

    func testASessionThatEndedCleanlyIsNotMournedAsDead() throws {
        var ended = working("claude-1", task: "traduce constants a EN")
        ended.state = .ended
        ended.lastEvent = "finished a turn"
        bus.save([ended])

        XCTAssertTrue(bus.died().isEmpty, "closing a session is not news")
    }

    func testAnActivityFileFromBeforeAnyOfThisStillDecodes() throws {
        // A binary that predates the pid wrote this. It has to keep working, and
        // its sessions have to keep counting as peers.
        let now = ISO8601DateFormatter.gentleMerge.string(from: Date())
        let legacy = #"[{"id":"claude-1","provider":"claude-code","projectPath":"\#(gameapp)","#
            + #""startedAt":"2026-08-22T09:00:00Z","updatedAt":"\#(now)","#
            + #""state":"working","currentTask":"traduce constants a EN"}]"#
        try Data(legacy.utf8).write(to: bus.paths.activities)

        let loaded = try XCTUnwrap(bus.activities().first)
        XCTAssertNil(loaded.pid)
        XCTAssertEqual(bus.others(excluding: "me").map(\.id), ["claude-1"])
    }

    // MARK: - A message that stops being true

    func testAResolvedNoteIsNotBriefedToAnybodyElseAgain() throws {
        // The one that actually happened: "BLOQUEO: no puedo dar taps" was still
        // being read out four hours after it was lifted.
        bus.post(AgentMessage(from: "claude", projectPath: gameapp, text: "BLOQUEO: no puedo dar taps"))
        let early = try XCTUnwrap(bus.briefing(sessionID: "codex-1", me: "codex", project: gameapp))
        XCTAssertTrue(early.contains("BLOQUEO"))

        bus.resolveOwn(author: "claude", project: gameapp)

        XCTAssertNil(
            bus.briefing(sessionID: "codex-2", me: "codex", project: gameapp),
            "a session that never saw it is not told about it now"
        )
    }

    func testATombstoneIsNeverItselfBriefed() throws {
        bus.post(AgentMessage(from: "claude", projectPath: gameapp, text: "el árbol es mío"))
        bus.resolveOwn(author: "claude", project: gameapp)

        // Both the note and its tombstone are on the log; neither is news.
        XCTAssertEqual(bus.messages().count, 2)
        XCTAssertNil(bus.briefing(sessionID: "codex-1", me: "codex", project: gameapp))
    }

    func testResolvingRewritesNothingThatWasAlreadyDelivered() throws {
        bus.post(AgentMessage(from: "claude", projectPath: gameapp, text: "BLOQUEO: no puedo dar taps"))
        XCTAssertNotNil(bus.briefing(sessionID: "codex-1", me: "codex", project: gameapp))
        let marker = try Data(contentsOf: bus.markerURL(for: "codex-1"))

        bus.resolveOwn(author: "claude", project: gameapp)

        // Delivery is history: what a session was told it was told. Resolving
        // only changes what the next read is worth.
        XCTAssertEqual(try Data(contentsOf: bus.markerURL(for: "codex-1")), marker)
    }

    func testTakingBackANoteTouchesOnlyYourOwnAndOnlyThisProject() throws {
        bus.post(AgentMessage(from: "claude", projectPath: gameapp, text: "mío y de aquí"))
        bus.post(AgentMessage(from: "claude", projectPath: clipapp, text: "mío pero de otro proyecto"))
        bus.post(AgentMessage(from: "codex", projectPath: gameapp, text: "de otro agente"))
        bus.post(AgentMessage(from: "claude", text: "mío y global"))

        XCTAssertEqual(bus.resolveOwn(author: "claude", project: gameapp).map(\.text), ["mío y de aquí"])

        let left = bus.visibleMessages().map(\.text)
        XCTAssertFalse(left.contains("mío y de aquí"))
        // Finishing something here is no reason to fall silent everywhere else.
        XCTAssertEqual(left, ["mío pero de otro proyecto", "de otro agente", "mío y global"])
    }

    func testATombstoneReadsAsSomethingHarmlessToABinaryThatCannotFoldIt() throws {
        bus.post(
            AgentMessage(
                from: "claude",
                projectPath: gameapp,
                text: "BLOQUEO: el simulador no acepta taps y no puedo seguir con la fase 4",
                kind: .urgent
            )
        )
        bus.resolveOwn(author: "claude", project: gameapp)

        // `messages()` with no folding is what an older binary sees.
        let tombstone = try XCTUnwrap(bus.messages().last)
        XCTAssertEqual(tombstone.effectiveKind, .resolve)
        XCTAssertTrue(tombstone.text.hasPrefix("done: BLOQUEO: el simulador no acepta taps"))
    }

    func testTakingBackTheSameNoteTwiceBuriesItOnce() throws {
        bus.post(AgentMessage(from: "claude", projectPath: gameapp, text: "el árbol es mío"))
        XCTAssertEqual(bus.resolveOwn(author: "claude", project: gameapp).count, 1)

        // The second run finds its own tombstone and has nothing left to do —
        // an agent calling `--done` at the end of every turn must not pile them.
        XCTAssertEqual(bus.resolveOwn(author: "claude", project: gameapp).count, 0)
        XCTAssertEqual(bus.messages().count, 2)
    }

    // MARK: - How long a message is worth reading

    func testEachKindIsReadableUpToItsHourAndNotPastIt() throws {
        let now = Date()
        let lives: [(MessageKind, TimeInterval)] = [
            (.fyi, 4 * 3600),
            (.update, 24 * 3600),
            (.urgent, 72 * 3600),
            (.handoff, 72 * 3600),
        ]
        for (kind, life) in lives {
            bus.post(AgentMessage(at: now.addingTimeInterval(-life + 1), from: "claude", text: "\(kind.rawValue)-fresh", kind: kind))
            bus.post(AgentMessage(at: now.addingTimeInterval(-life - 1), from: "claude", text: "\(kind.rawValue)-stale", kind: kind))
        }

        let readable = bus.undelivered(to: nil, me: "codex", project: nil, now: now).map(\.text)
        for (kind, _) in lives {
            XCTAssertTrue(readable.contains("\(kind.rawValue)-fresh"), "a \(kind.rawValue) a second inside its life still counts")
            XCTAssertFalse(readable.contains("\(kind.rawValue)-stale"), "a \(kind.rawValue) a second past it does not")
        }
    }

    func testALineWithNoKindLivesADayLikeAnUpdate() throws {
        // Every message written before kinds existed looks like this. It must
        // behave as the middle case, not as forever and not as four hours.
        let now = Date()
        bus.post(AgentMessage(at: now.addingTimeInterval(-23 * 3600), from: "claude", text: "de ayer por la tarde"))
        bus.post(AgentMessage(at: now.addingTimeInterval(-25 * 3600), from: "claude", text: "de anteayer"))

        let readable = bus.undelivered(to: nil, me: "codex", project: nil, now: now).map(\.text)
        XCTAssertEqual(readable, ["de ayer por la tarde"])
    }

    func testAKindThisBinaryHasNeverHeardOfDoesNotCostUsTheLine() throws {
        // Written by a newer binary sharing the same log — the normal state of
        // things while you upgrade one of the two. Throwing here would make the
        // newer agent's notes invisible instead of merely unlabelled.
        let at = ISO8601DateFormatter.gentleMerge.string(from: Date())
        let line = #"{"id":"m1","at":"\#(at)","from":"codex","text":"desde el futuro","kind":"escalation"}"#
        try AtomicFile.append(line, to: bus.paths.messages)

        let message = try XCTUnwrap(bus.messages().first)
        XCTAssertEqual(message.text, "desde el futuro")
        XCTAssertNil(message.kind)
        XCTAssertEqual(message.effectiveKind, .update, "unknown reads as unlabelled, and unlabelled is an update")
    }

    // MARK: - Priority

    func testAnUrgentIsReadFirstAndSurvivesTheCap() throws {
        let now = Date()
        bus.post(
            AgentMessage(
                at: now.addingTimeInterval(-3600),
                from: "claude",
                text: "NO toques ese fichero, lo estoy migrando",
                kind: .urgent
            )
        )
        // Twenty newer notes: FIFO pages the oldest first so nothing is lost
        // to the tail — the cap takes the head, the rest stays pending.
        for index in 0..<20 {
            bus.post(AgentMessage(at: now.addingTimeInterval(Double(index)), from: "claude", text: "fyi \(index)", kind: .fyi))
        }

        let briefing = try XCTUnwrap(bus.briefing(sessionID: "codex-1", me: "codex", project: nil, now: now.addingTimeInterval(60)))
        XCTAssertTrue(briefing.contains("[URGENT] claude"))
        XCTAssertTrue(briefing.contains("NO toques ese fichero"))

        let lines = briefing.split(separator: "\n")
        let urgent = try XCTUnwrap(lines.firstIndex { $0.contains("[URGENT]") })
        let ordinary = try XCTUnwrap(lines.firstIndex { $0.contains("fyi ") })
        XCTAssertLessThan(urgent, ordinary, "read first, not last")

        // The chatter is still capped: the point is the blocker, not the log.
        // FIFO takes the oldest pending (fyi 0..7); the newest stays pending
        // for the next turn instead of pushing the head off the end.
        XCTAssertTrue(briefing.contains("fyi 0"))
        XCTAssertFalse(briefing.contains("fyi 19"))
    }

    func testAHandoffIsTaggedTooAndTheOrdinaryOnesAreNot() throws {
        let now = Date()
        bus.post(AgentMessage(at: now, from: "claude", text: "te dejo la fase 4 a medias", kind: .handoff))
        bus.post(AgentMessage(at: now, from: "claude", text: "he subido la versión", kind: .update))

        let briefing = try XCTUnwrap(bus.briefing(sessionID: "codex-1", me: "codex", project: nil, now: now))
        XCTAssertTrue(briefing.contains("[HANDOFF] claude"))

        // Matched on the line rather than on the whole block: every line now
        // opens with the note's handle, and the claim here was never about what
        // comes before the sender — it is that an update wears no tag.
        let update = try XCTUnwrap(
            briefing.split(separator: "\n").first { $0.contains("he subido la versión") }
        )
        XCTAssertTrue(update.contains("claude (just now): he subido la versión"))
        XCTAssertFalse(update.contains("[HANDOFF]"), "an update wears no tag")
        XCTAssertFalse(update.contains("[URGENT]"), "an update wears no tag")
    }

    func testAnUrgentDeliveredOnceDoesNotComeRoundAgain() throws {
        let now = Date()
        bus.post(AgentMessage(at: now.addingTimeInterval(-3600), from: "claude", text: "NO toques ese fichero", kind: .urgent))
        bus.post(AgentMessage(at: now, from: "claude", text: "y ya está", kind: .update))

        XCTAssertNotNil(bus.briefing(sessionID: "codex-1", me: "codex", project: nil, now: now))
        // The floor is the newest of what went out, not the last line printed:
        // priority is rendered first and is usually the oldest of the batch.
        XCTAssertTrue(bus.undelivered(to: "codex-1", me: "codex", project: nil, now: now).isEmpty)
    }

    // MARK: - Pruning knows what is still true

    func testPruningKeepsABlockerNobodyHasLifted() throws {
        let now = Date()
        bus.post(AgentMessage(at: now.addingTimeInterval(-10 * 3600), from: "claude", text: "NO toques el schema", kind: .urgent))
        bus.post(AgentMessage(at: now.addingTimeInterval(-10 * 3600), from: "claude", text: "charla de hace rato", kind: .update))

        // A cutoff well inside the urgent's own 72 hours.
        XCTAssertEqual(bus.pruneMessages(olderThan: 3600, keepingAtMost: 500, now: now), 1)
        XCTAssertEqual(bus.messages().map(\.text), ["NO toques el schema"])
    }

    func testPruningLetsGoOfABlockerOnceItHasBeenLifted() throws {
        let now = Date()
        bus.post(AgentMessage(at: now.addingTimeInterval(-10 * 3600), from: "claude", text: "NO toques el schema", kind: .urgent))
        bus.resolveOwn(author: "claude", project: nil)

        // The tombstone is minutes old and stays; what it buries is not standing
        // any more, so the cutoff applies to it like to anything else.
        XCTAssertEqual(bus.pruneMessages(olderThan: 3600, keepingAtMost: 500, now: now), 1)
        XCTAssertEqual(bus.messages().map(\.effectiveKind), [.resolve])
    }

    func testPruningKeepsATombstoneWhileWhatItBuriesIsStillThere() throws {
        let now = Date()
        bus.post(AgentMessage(at: now, from: "claude", text: "el árbol es mío", kind: .update))
        // A resolve older than what it resolves: nonsense by the clock, and
        // exactly what two machines with a few hours between them produce.
        // Pruning it while the original survives would raise the dead.
        let original = try XCTUnwrap(bus.messages().first)
        bus.post(
            AgentMessage(
                at: now.addingTimeInterval(-10 * 3600),
                from: "claude",
                text: "done: el árbol es mío",
                kind: .resolve,
                refID: original.id
            )
        )

        XCTAssertEqual(bus.pruneMessages(olderThan: 3600, keepingAtMost: 500, now: now), 0)
        XCTAssertTrue(bus.visibleMessages().isEmpty, "and the note stays buried")
    }

    func testPruningDropsATombstoneWhoseNoteIsLongGone() throws {
        let now = Date()
        bus.post(
            AgentMessage(
                at: now.addingTimeInterval(-10 * 3600),
                from: "claude",
                text: "done: algo que ya no existe",
                kind: .resolve,
                refID: "a-message-nobody-has-any-more"
            )
        )

        XCTAssertEqual(bus.pruneMessages(olderThan: 3600, keepingAtMost: 500, now: now), 1)
        XCTAssertTrue(bus.messages().isEmpty)
    }

    func testTheCapDoesNotBuryAStandingBlocker() throws {
        let now = Date()
        bus.post(AgentMessage(at: now.addingTimeInterval(-3600), from: "claude", text: "NO toques el schema", kind: .urgent))
        for index in 0..<10 {
            bus.post(AgentMessage(at: now.addingTimeInterval(Double(index)), from: "codex", text: "charla \(index)"))
        }

        XCTAssertEqual(bus.pruneMessages(keepingAtMost: 3, now: now), 7)
        let left = bus.messages().map(\.text)
        XCTAssertEqual(left.first, "NO toques el schema", "the budget is for chatter, not for what is still true")
        XCTAssertEqual(left.count, 4)
    }

    // MARK: - Hermes, and agents with a name of their own

    /// Hermes is one-shot and has no hooks: `brief --as hermes` is the whole of
    /// its inbox. If that read does not consume, it is handed the same note
    /// every single time it runs, which is the same as never being told.
    func testANoteToHermesIsDeliveredOnceToAReaderThatNamesItself() throws {
        bus.post(AgentMessage(from: "claude", to: "hermes", text: "traduce constants a EN"))

        let reader = AgentBus.readerSessionID(for: "hermes")
        let first = try XCTUnwrap(bus.briefing(sessionID: reader, me: "hermes", project: nil))
        XCTAssertTrue(first.contains("traduce constants a EN"))
        XCTAssertNil(bus.briefing(sessionID: reader, me: "hermes", project: nil), "identifying yourself is consuming")
    }

    func testLookingWithoutANameStillLeavesTheNoteOnHermesPile() throws {
        bus.post(AgentMessage(from: "claude", to: "hermes", text: "traduce constants a EN"))

        XCTAssertNotNil(bus.briefing(sessionID: nil, me: nil, project: nil))
        let hermes = try XCTUnwrap(
            bus.briefing(sessionID: AgentBus.readerSessionID(for: "hermes"), me: "hermes", project: nil)
        )
        XCTAssertTrue(hermes.contains("traduce constants a EN"))
    }

    /// The pseudo-session is a marker file like any other, so the one thing it
    /// must never do is answer to a real session's name.
    func testAReaderMarkerNeverStandsInForARealSessionOfTheSameName() throws {
        bus.post(AgentMessage(from: "claude", to: "hermes", text: "traduce constants a EN"))

        XCTAssertNotNil(bus.briefing(sessionID: AgentBus.readerSessionID(for: "hermes"), me: "hermes", project: nil))
        // A session id is whatever the agent's own tooling calls it, and it is
        // free to be the literal string "hermes".
        let realSession = try XCTUnwrap(bus.briefing(sessionID: "hermes", me: "hermes", project: nil))
        XCTAssertTrue(realSession.contains("traduce constants a EN"), "a read by a label did not eat a session's mail")
        XCTAssertEqual(AgentBus.readerSessionID(for: "hermes"), "reader-hermes")
    }

    func testAReaderNameCannotWanderOutOfTheDeliveredFolder() {
        // Whatever the wrapper typed, what comes out is one file name inside
        // `delivered/` — separators folded away, nothing to climb out with.
        let escaped = AgentBus.readerSessionID(for: "../../etc/passwd")
        XCTAssertEqual(escaped, "reader-..-..-etc-passwd")
        XCTAssertFalse(escaped.contains("/"))
        XCTAssertEqual(AgentBus.readerSessionID(for: "claude#exec1"), "reader-claude#exec1")
    }

    func testAddressingTheDirectorReachesTheExecutorsItLaunched() throws {
        bus.post(AgentMessage(from: "codex", to: "claude", text: "el schema es tuyo"))

        let executor = try XCTUnwrap(
            bus.briefing(sessionID: AgentBus.readerSessionID(for: "claude#exec1"), me: "claude#exec1", project: nil)
        )
        XCTAssertTrue(executor.contains("el schema es tuyo"))
        XCTAssertFalse(executor.contains("(for claude)"), "it is for claude, and the executor is claude")
    }

    func testNamingOneExecutorReachesThatOneAndNobodyElse() {
        bus.post(AgentMessage(from: "codex", to: "claude#exec1", text: "esa rama es tuya"))

        XCTAssertNotNil(bus.briefing(sessionID: "exec-1", me: "claude#exec1", project: nil))
        XCTAssertNil(bus.briefing(sessionID: "exec-2", me: "claude#exec2", project: nil), "a sibling is not the addressee")
        XCTAssertNil(bus.briefing(sessionID: "claude-1", me: "claude", project: nil), "nor is the session that spawned it")
    }

    /// The executors report back to the session that launched them, and that is
    /// the delivery it would be worst to swallow as "your own words".
    func testWhatAnExecutorSaysStillReachesTheSessionThatLaunchedIt() throws {
        bus.post(AgentMessage(from: "claude#exec1", to: "claude", text: "fase 5 mergeada"))

        let director = try XCTUnwrap(bus.briefing(sessionID: "claude-1", me: "claude", project: nil))
        XCTAssertTrue(director.contains("fase 5 mergeada"))
    }

    func testAnExecutorIsNotToldItsOwnWordsComingBack() {
        bus.post(AgentMessage(from: "claude#exec1", text: "voy a tocar el árbol"))

        XCTAssertNil(bus.briefing(sessionID: "exec-1", me: "claude#exec1", project: nil))
    }

    // MARK: - Who is running this command

    func testASubagentSignsWithTheNameItWasGiven() {
        // Executors inherit the parent's environment, CLAUDECODE included, so
        // the explicit name has to win or they all sign as plain "claude".
        XCTAssertEqual(
            AgentBus.label(in: ["CLAUDECODE": "1", "GENTLEMERGE_NAME": "claude#exec1"]),
            "claude#exec1"
        )
        XCTAssertEqual(AgentBus.label(in: ["GENTLEMERGE_NAME": "hermes"]), "hermes")
    }

    func testAnEmptyNameIsNoNameAtAll() {
        // `GENTLEMERGE_NAME=` in a wrapper that computed nothing should leave
        // the agent detected as usual, not sign its notes with the empty string.
        XCTAssertEqual(AgentBus.label(in: ["CLAUDECODE": "1", "GENTLEMERGE_NAME": "  "]), "claude")
        XCTAssertEqual(AgentBus.label(in: ["CODEX_HOME": "/x"]), "codex")
        XCTAssertEqual(AgentBus.label(in: [:]), "you")
    }

    // MARK: - FASE 2A: entrega sin pérdidas (FIFO por secuencia)

    /// 1-5. Mil mensajes normales paginan FIFO sin perder ni duplicar.
    /// Recoge handles/textos por briefing y verifica cobertura total y única.
    func testBulkFifoDeliversEveryMessageExactlyOnce() throws {
        var ids: [String] = []
        var texts: [String] = []
        for i in 0..<1000 {
            let text = String(format: "bulk-%04d-secuencia", i)
            let message = AgentMessage(from: "writer", text: text)
            ids.append(message.id)
            texts.append(text)
            bus.post(message)
        }
        let stored = bus.messagesForDelivery()
        XCTAssertEqual(stored.count, 1000)
        let seqs = stored.compactMap(\.sequence)
        XCTAssertEqual(seqs.count, 1000, "every new post must carry a sequence")
        XCTAssertEqual(Set(seqs).count, 1000, "sequences must be unique")

        // Handles are 16-bit (collisions possible over 1000 ids), so coverage
        // and uniqueness are verified over the unique texts; handles are
        // verified for presence per delivered line.
        var appearances: [String: Int] = [:]
        var briefings = 0
        while let output = bus.briefing(sessionID: "bulk-reader", me: "reader", project: nil) {
            briefings += 1
            XCTAssertLessThanOrEqual(briefings, 200, "1000 / 8 per turn must finish in ~125 briefings")
            for text in texts where output.contains(text) {
                appearances[text, default: 0] += 1
            }
            if briefings > 200 { break }
        }
        XCTAssertEqual(briefings, 125, "1000 messages at 8 per turn must take exactly 125 turns, got \(briefings)")
        XCTAssertEqual(appearances.count, 1000, "every message must appear finally")
        XCTAssertTrue(appearances.values.allSatisfy { $0 == 1 }, "no message may appear twice to the same session")

        // Spot-check handles: the first and last bulk notes must show their
        // handle alongside their text at least once across the run. Re-read
        // with a fresh session to capture them deterministically.
        let firstHandle = AgentMessage.handle(for: ids[0])
        let lastHandle = AgentMessage.handle(for: ids[999])
        var sawFirst = false
        var sawLast = false
        // Fresh reader replays the whole log (its own cursor starts at zero).
        while let output = bus.briefing(sessionID: "bulk-handles", me: "handles", project: nil) {
            if output.contains("bulk-0000-secuencia") && output.contains("#\(firstHandle)") { sawFirst = true }
            if output.contains("bulk-0999-secuencia") && output.contains("#\(lastHandle)") { sawLast = true }
        }
        XCTAssertTrue(sawFirst, "first bulk note must show its handle #\(firstHandle)")
        XCTAssertTrue(sawLast, "last bulk note must show its handle #\(lastHandle)")
    }

    /// 6. Un segundo lector independiente recibe también todo.
    func testSecondReaderGetsFullHistoryIndependently() throws {
        for i in 0..<20 {
            bus.post(AgentMessage(from: "writer", text: "shared-\(i)"))
        }
        func drain(session: String, me: String) -> Set<String> {
            var seen = Set<String>()
            while let output = bus.briefing(sessionID: session, me: me, project: nil) {
                for i in 0..<20 where output.contains("shared-\(i)") {
                    seen.insert("shared-\(i)")
                }
            }
            return seen
        }
        XCTAssertEqual(drain(session: "r-one", me: "one"), Set((0..<20).map { "shared-\($0)" }))
        XCTAssertEqual(drain(session: "r-two", me: "two"), Set((0..<20).map { "shared-\($0)" }), "a second session starts from zero, not from the first reader's cursor")
    }

    /// 7. Dos escritores concurrentes nunca duplican sequence.
    func testConcurrentWritersNeverDuplicateSequences() throws {
        let bus = self.bus!
        DispatchQueue.concurrentPerform(iterations: 50) { index in
            for k in 0..<20 {
                bus.post(AgentMessage(from: "writer-\(index)", text: "c-\(index)-\(k)"))
            }
        }
        let all = bus.messagesForDelivery()
        XCTAssertEqual(all.count, 1000)
        let seqs = all.compactMap(\.sequence)
        XCTAssertEqual(seqs.count, 1000)
        XCTAssertEqual(Set(seqs).count, 1000, "concurrent posts under one lock must never share a number")
    }

    /// 8. Mensajes antiguos sin `sequence` siguen legibles y entregables.
    func testMessagesWithoutSequenceStillDecodeAndDeliver() throws {
        let at = ISO8601DateFormatter.gentleMerge.string(from: Date())
        let line = #"{"id":"old-1","at":"\#(at)","from":"writer","text":"nota antigua"}"#
        try AtomicFile.append(line, to: bus.paths.messages)

        let stored = try XCTUnwrap(bus.messages().first { $0.id == "old-1" })
        XCTAssertNil(stored.sequence, "old lines keep sequence == nil")
        XCTAssertEqual(stored.text, "nota antigua")

        let briefing = try XCTUnwrap(bus.briefing(sessionID: "old-reader", me: "reader", project: nil))
        XCTAssertTrue(briefing.contains("nota antigua"), "old lines must still be delivered:\n\(briefing)")
    }

    /// 9. Un pendiente no desaparece cuando el primer briefing solo muestra 8.
    func testPendingSurvivesFirstCappedBriefing() throws {
        for i in 0..<9 {
            bus.post(AgentMessage(from: "writer", text: "page-\(i)"))
        }
        let first = try XCTUnwrap(bus.briefing(sessionID: "pager", me: "reader", project: nil))
        // FIFO: oldest 8 first.
        for i in 0..<8 { XCTAssertTrue(first.contains("page-\(i)"), "first turn must carry oldest page-\(i):\n\(first)") }
        XCTAssertFalse(first.contains("page-8"), "newest stays pending, it must not push the head off")

        XCTAssertFalse(bus.undelivered(to: "pager", me: "reader", project: nil).isEmpty, "page-8 must still be pending")
        let second = try XCTUnwrap(bus.briefing(sessionID: "pager", me: "reader", project: nil))
        XCTAssertTrue(second.contains("page-8"), "second turn must carry what the cap left:\n\(second)")
        XCTAssertTrue(bus.undelivered(to: "pager", me: "reader", project: nil).isEmpty)
    }

    /// 10. `pruneMessages` no elimina pendientes de una sesión viva.
    func testPruneKeepsPendingForLiveSession() throws {
        for i in 0..<10 {
            bus.post(AgentMessage(from: "writer", text: "prune-\(i)"))
        }
        // Deliver oldest 8, leave prune-8 and prune-9 pending.
        let first = try XCTUnwrap(bus.briefing(sessionID: "prune-reader", me: "reader", project: nil))
        XCTAssertTrue(first.contains("prune-0"))
        XCTAssertFalse(first.contains("prune-9"))

        // Cap of 3 would keep only the newest 3 without live-reader protection.
        // With same-second stamps the timestamp floor already pins everything;
        // the sequence watermark pins the pending even when stamps differ.
        _ = bus.pruneMessages(keepingAtMost: 3)
        let left = bus.messagesForDelivery().map(\.text)
        XCTAssertTrue(left.contains("prune-8"), "pending prune-8 must survive the cap")
        XCTAssertTrue(left.contains("prune-9"), "pending prune-9 must survive the cap")

        // And the pending is still deliverable afterwards.
        let second = try XCTUnwrap(bus.briefing(sessionID: "prune-reader", me: "reader", project: nil))
        XCTAssertTrue(second.contains("prune-8") || second.contains("prune-9"), "pending must still page after prune:\n\(second)")
    }

    // MARK: - Cursor por proyecto (riesgo watermark entre proyectos)

    /// Decisión explícita: el cursor es por (sesión, proyecto). Leer A nunca
    /// avanza B. Misma sesión cambia de proyecto sin perder pendientes.
    /// Interleaved para cazar el bug global: con watermark global, leer gameapp
    /// (seq impares) avanzaba a 9 y perdía clipapp 2..8.
    func testProjectSwitchDoesNotLosePending() throws {
        let gameapp = "/tmp/gameapp"
        let clipapp = "/tmp/clipapp"
        for i in 0..<5 {
            bus.post(AgentMessage(from: "writer", projectPath: gameapp, text: "game-\(i)"))
            bus.post(AgentMessage(from: "writer", projectPath: clipapp, text: "clip-\(i)"))
        }
        // Same session, same reader label, different projects.
        let first = try XCTUnwrap(bus.briefing(sessionID: "switch-1", me: "reader", project: gameapp))
        for i in 0..<5 { XCTAssertTrue(first.contains("game-\(i)"), "gameapp mail must all fit (5<8):\n\(first)") }
        XCTAssertFalse(first.contains("clip-"), "other project's mail never leaks into this scope")

        let second = try XCTUnwrap(bus.briefing(sessionID: "switch-1", me: "reader", project: clipapp))
        for i in 0..<5 { XCTAssertTrue(second.contains("clip-\(i)"), "clipapp pending must survive the gameapp read:\n\(second)") }

        XCTAssertNil(bus.briefing(sessionID: "switch-1", me: "reader", project: gameapp), "gameapp already consumed, silence now")
        XCTAssertNil(bus.briefing(sessionID: "switch-1", me: "reader", project: clipapp), "clipapp already consumed, silence now")
    }

    // MARK: - Contador reforzado (riesgo reutilización al reemplazar log)

    /// Log reemplazado con números mayores + contador viejo: el siguiente post
    /// salta por encima (tail), nunca reutiliza.
    func testCounterNeverReusesAfterLogReplacement() throws {
        bus.post(AgentMessage(from: "writer", text: "orig-0"))
        bus.post(AgentMessage(from: "writer", text: "orig-1"))
        // Simulate operator replacing messages.jsonl with higher-numbered lines,
        // counter file left stale at 2.
        let at = ISO8601DateFormatter.gentleMerge.string(from: Date())
        let injected = [
            #"{"id":"inj-50","at":"\#(at)","from":"writer","text":"injected-50","sequence":50}"#,
            #"{"id":"inj-51","at":"\#(at)","from":"writer","text":"injected-51","sequence":51}"#,
        ].joined(separator: "\n") + "\n"
        try Data(injected.utf8).write(to: bus.paths.messages)
        // Counter still says 2 (stale). Next must be >51, not 3.
        bus.post(AgentMessage(from: "writer", text: "after-replace"))
        let all = bus.messagesForDelivery()
        let after = try XCTUnwrap(all.first { $0.text == "after-replace" })
        XCTAssertGreaterThan(after.sequence ?? 0, 51, "must jump past replaced tail, got \(String(describing: after.sequence))")
        XCTAssertEqual(Set(all.compactMap(\.sequence)).count, all.compactMap(\.sequence).count, "no duplicate sequences")
    }

    /// Restore parcial (log+contador rebobinados, delivered/ conserva watermark):
    /// el siguiente post salta por encima del watermark (gap permitido) en vez
    /// de reutilizar y perderse como ya-entregado.
    func testCounterJumpsPastDeliveredWatermarkAfterPartialRestore() throws {
        for i in 0..<3 {
            bus.post(AgentMessage(from: "writer", text: "wm-\(i)"))
        }
        // Deliver all to advance watermark to 3 (global read, project nil).
        while bus.briefing(sessionID: "wm-reader", me: "reader", project: nil) != nil {}
        let markBefore = bus.deliveryMarker(for: "wm-reader")
        XCTAssertNotNil(markBefore?.lastDeliveredSequence ?? markBefore?.lastDeliveredSequenceByProject?[""])

        // Rewind log+counter to 1 (old backup), keep delivered/ (watermark 3).
        let first = try XCTUnwrap(bus.messagesForDelivery().first)
        let single = try JSONCoding.encoder().encode(first)
        let line = String(decoding: single, as: UTF8.self) + "\n"
        try Data(line.utf8).write(to: bus.paths.messages)
        try Data(#"{"last":1}"#.utf8).write(to: bus.paths.messageSequence)

        bus.post(AgentMessage(from: "writer", text: "wm-new"))
        let all = bus.messagesForDelivery()
        let fresh = try XCTUnwrap(all.first { $0.text == "wm-new" })
        XCTAssertGreaterThan(fresh.sequence ?? 0, 2, "must jump past delivered watermark 3, got \(String(describing: fresh.sequence))")

        // And the fresh mail is actually delivered (not filtered as dup).
        let out = try XCTUnwrap(bus.briefing(sessionID: "wm-reader", me: "reader", project: nil))
        XCTAssertTrue(out.contains("wm-new"), "fresh post past watermark must be delivered:\n\(out)")
    }
}
