# Audit handoff — **CLOSED**

**All 44 findings are fixed.** 18 commits on `fix/audit-round-1`, base `051c5e6`.

```bash
swift build
swift test          # 702 tests, 1 skipped, 0 failures
```

This document is kept as the record of *what was found and how each was closed*,
including the findings that turned out to be wrong. Read the last two sections
first if you are new: **"Wrong, and what I got wrong"** and **"Still open"**.

Confidence tags used below:

- **[V]** reproduced against the real code, with output
- **[U]** code reading only; the failure was not reproduced
- **[R]** refuted — it is not a bug

---

## What closed what

| Finding | Commit |
|---|---|
| 1–11 (Tier 1 + Tier 2) — lock, watermarks, may_touch union, presence persistence, implicit-claim label, snapshot renames, `-z`, radar typing, rebase honesty, handoff round trip | `ce48bf9` |
| #1's regression test was two sequential reads — replaced with a real one (120 messages × 6 threads) | `73d9fb2` |
| 22, 23, 24, 25, 26, 30 (Tier 5 crashes) + `--ttl` | `b037c14` |
| 37 — `touchedPaths` was always nil, so Review's "outside the project" never fired | `49cc97e` |
| 15 + #16's worst symptom — `budgetMinutes` is now a deadline | `d245679` |
| 17, 18, 21, 31, 43 — dispatch and config | `5f4b196` |
| 13, 38, 39, 44 — installers | `745189c` |
| 27, 32, 28, 29 — MCP protocol and socket | `cfba93a` |
| 12 — the `Shell.run` failed-spawn thread leak | `e33d5d3` |
| 20, 34, 35, 19, 42 — specificity, absolute globs, parsing, state machine | `7889a6b` |
| 36, 40, 41, 33 — presence identity, trimmed paths, radar state, fake hook mode | `7d45a15` |
| 13 (TERM_PROGRAM) + 14 (osascript timeout) | `530d37a` |

Plus the six gate bypasses, the briefing work, the requests authorisation fix,
the shell quoting and `clearHistory` — commits `485f09c`, `96e600d`, `5aa9073`,
`a73cfb0`, `f53b337`, `73d9fb2`.

### Existing tests that asserted a bug as intended

Rewritten, with the reason kept in a comment so nobody re-adds the behaviour:

- `RequestsTests` was named `...WrongActorThrowButYouCanAct` and asserted that
  `"you"` could move anybody's request. Fixed in `5aa9073`.
- `InboxModel.deny` moved requests as `"you"` in **production** code. Fixed in
  `a73cfb0`.
- `WorktreeEnvTests.testRenderMatchesTheDocumentedShape` pinned the unquoted
  `env.sh`. Fixed in `a73cfb0`.
- `MCPServerTests.testUnknownMethodAndTool` asserted `-32601` for an unknown
  tool. Fixed in `cfba93a`.
- `HandoffTests.testAnInjectedOwnershipSectionGrantsNothing` asserted the old
  truncation. Fixed in `ce48bf9` — its two security assertions were kept
  untouched and pass.
- `CLIConfigTests` asserted `dispatchDailyBudgetMinutes -5` is refused. Still is;
  it also now asserts `0` is accepted. `5f4b196`.

---

## Tier 1 — enforcement / data loss

### 1. `record(delivery:)` and the briefing cursor take no lock → duplicate delivery **[V]**

`Bus/AgentBus.swift` `record(delivery:)` (~1650-1695) and
`Bus/BriefingCursor.swift` `BriefingCursorStore.save` (~91) do **not** take the
sidecar `flock` that `post` and `pruneMessages` do.

Measured: 6 concurrent `brief --as claude` processes over a 400-message log gave
**12 duplicate deliveries; serial gave 0**. The read-compute-write window is
wide (render 400 messages), so all six compute the same pending set before any
writes.

`BriefingCursor.swift:4-5` states the assumption explicitly — "that directory is
already written only by this session's own hook, so no lock is needed". The README
presents `brief --as <label>` as an ordinary CLI any number of shells can run.

**Fix:** wrap the cursor read-modify-write in `LockedFile.withExclusiveLock`.
Note `flock` is advisory and per-process — verify it actually serialises here.

### 2. `deliveredIDCap` truncation defeats the sequence watermark **[V]**

`AgentBus.record(delivery:)` (~1659) trims `deliveredIDs` to `Array(ids.suffix(300))`.
A project-scoped read advances only `lastDeliveredSequenceByProject["A"]`, leaving
global `lastDeliveredSequence` nil; a later global read has no watermark and falls
back to `deliveredIDs`.

Reproduced: 400 messages consumed in project A → a global read **re-delivered all
400** over 50 turns. `testProjectSwitchDoesNotLosePending` covers project→project only.

**Fix:** promote the per-project watermark on a global read, or stop trimming below
what a reader can still be behind on.

### 3. `may_touch` enforced against one request only **[V]**

`Projects/PrecommitGate.swift:122`, `CLI.swift:1221`, `CLI.swift:1849`,
`Bus/MCPServer.swift:63,94` all do:

```swift
activeRequest: Requests(paths: paths).inProgress(assignedTo: me, project: project).first
```

`Requests.all()` sorts `createdAt` ascending, so `.first` is the **oldest**.

A delegate holding two in-progress requests is judged against the wrong contract in
both directions: commits the current task needs are rejected as outside the older
request's `mayTouch`, and the older request's paths are allowed while working the newer.

**Fix:** evaluate rule 3 against the **union** of the delegate's in-progress
`mayTouch`; name the violated request id in the message.

### 4. Presence marks persisted into `activities.json` freeze presence **[V]**

`Ingest/InboxModel.swift:601` and `:665` call `bus.save(list)` where `list` came from
`bus.activities()` — which returns a **synthetic union** of stored rows plus
`Presence.live(...)` (`AgentBus.swift:390`). `AgentBus.swift:359-362` states the app is
"the single writer of the activity file" and presence is merged **at read time**.

Consequences:
- **Stale:** next read's `known` contains the persisted `presence:…` id, so the fresh
  mark is filtered out. The peer list serves a frozen snapshot (`currentTask`, `pid`)
  until the row passes `isLive`'s 6h window. A refreshed `presence --task` is invisible
  to `who` and every briefing for up to 6 hours.
- **Phantom rows:** `sweepDeadSessions` buries them and fires `noteUnfinishedWork` +
  a `.sessionEnd` watch for a session that never existed.
- **Displacement:** `updateActivity:663` caps at 40 *after* merging, so presence marks
  evict real sessions.

**Fix:** never write back the merged list; persist only the app-owned rows.

### 5. Implicit path claims are attributed to the provider, not the label **[V]**

`InboxModel.swift:704-707`:

```swift
let label = envelope.payload.string("label").map(Identity.safe)?.nonEmpty
    ?? AgentBus.label(for: envelope.provider)
```

`Install/HookScript.swift:110-123` writes the envelope with **no `label` field**, so
`payload.string("label")` is nil in production — it is only non-nil in the simulator
(`Sim/SimAgent.swift:67`), which is why the demo looks right.

Two Claude worktrees labelled `hermes` and `codex` both claim as `"claude"`.
`PathClaims.claim` treats same-label as renewal (`PathClaims.swift:165-176`), so the
second overwrites the first's `expires`; neither sees the other as foreign and
`PrecommitGate` rule 1 never fires. **The whole implicit-claim feature is inert for
any client whose label differs from its provider name** — Hermes, Gemini CLI,
OpenCode, any custom `--label`.

Secondary: the `?? envelope.eventName.flatMap { ... }` clause is dead code (returns
`payload.string("tool_name")`, already nil).

**Fix:** thread the resolved identity into the envelope at the hook, or resolve it the
same way the gate does.

---

## Tier 2 — git operations

### 6. `GitSnapshot.restore` silently skips renames **[V]**

`Snapshot/GitSnapshot.swift:172-183`. The switch handles `M`/`T`/`D` (restore) and
`A` (report created); `status.first == "R"` falls to `default: continue`. `parseNameStatus`
(~227) correctly extracts the *new* path, so the data is there and dropped.

Snapshot → rename → `snapshot restore` leaves `old.txt` missing and reports
"restored 0 files" as success. No test covers renames.

**Fix:** handle `R`/`C` — restore the new path, remove the old.

### 7. Landing never releases its own claim on quoted paths **[V]**

`Projects/Landing.swift:186-190` (`filesChanged`) and `Projects/ConflictRadar.swift:155-164`
(`conflicts`) use `--name-only` **without `-z`**, so git C-quotes per `core.quotePath`.

A conflict on `spä ce.txt` is emitted as the literal line `"sp\303\244 ce.txt"`. Then:
- `Landing.authorsOf` (~169-183) runs `git log … -- "sp\303\244 ce.txt"` → no match →
  the report always says "unknown authors" and names a path that does not exist.
- `Landing.land:319` feeds those quoted paths into `PathClaims.releaseCovering` →
  `Glob.matches` fails → **the landing agent's own claim is never released**, so other
  agents stay blocked until the TTL.

`PrecommitCheck.parseStatus` and `GitSnapshot.parseNameStatus` already use `-z`. Same
fix pattern as commit `485f09c`.

### 8. `conflicts()` overloads "git could not answer" as "no shared history" **[V]**

`ConflictRadar.swift:160-163` returns `nil` for unrelated histories (verified exit 128)
**and** for every other failure — git missing, timeout, index lock, bad option.

- `Landing.swift:252-254` maps `nil` → `Failure.noMergeBase`, printing "…share no
  history — a rebase would fail too" for what may be a transient lock.
- `Landing.swift:406-410` maps the same `nil` → `.skipped("radar sees a conflict with
  main")` — **reports a conflict when the radar never answered.**
- `autoLand` calls `conflicts` with **no git-version gate**, unlike `sweep` (~309) and
  `land` (~247), so on git < 2.38 auto-land takes this branch every time.

**Fix:** return a typed result distinguishing no-merge-base from could-not-ask.

### 9. Conflict radar false negative when a rename makes the file sets disjoint **[V]**

`ConflictRadar.swift:379-386`, gate `overlaps(filesA, filesB)` at 383. It assumes
disjoint changed-file sets ⇒ no conflict, but `git merge-tree` **does rename detection**.

Verified: branch A renames `old.txt`→`new.txt` and edits it; `main` edits `old.txt`.
`git merge-tree --write-tree --no-messages --name-only A main` exits **1** listing
`new.txt` (a real rename/modify conflict), while `git diff --name-only base...A` =
`{new.txt}` and `...main` = `{old.txt}` — disjoint. `overlaps` is false, the pair never
reaches merge-tree, **no warning is ever emitted**.

Bounded to the agent-vs-agent phase; `Landing.land`/`autoLand` call `conflicts`
directly, so landing stays safe. This is precisely the silent false negative that
defeats the feature's stated purpose.

### 10. Rebase rewrites the branch silently; `--abort` result discarded **[V]**

`Landing.swift:290-294`. `git rebase into` rewrites the agent's branch (new SHAs,
emptied commits dropped by git's default `--empty=drop`). If checks then fail (:302)
or `fastForward` throws (:310), main is untouched — but **the branch has moved and
nothing in the thrown message or `Report` says so.** Presence marks, the radar's
base-keyed signatures and any external reference to the old tip are stale.

Separately, `_ = git(["rebase", "--abort"])` at :292 discards its result while the
message at :63 asserts "aborted, branch untouched". If the abort fails the worktree is
left mid-rebase with a `.git/rebase-merge` directory.

### 11. `HANDOFF.md` round trip loses multi-line task text **[V]**

`Projects/ProjectHandoff.swift:342` and `:362-364` (render) vs `:433-460` (`extractTasks`).
`escape` preserves interior newlines, so `"fix X\nand Y"` renders as two lines; on
reparse the second is not a checkbox, goes to `remainder`, which `tasksHeading` (:391)
discards — and the next `save` **permanently deletes it**.

Worse for steps: `" - [ ] part one\npart two"` makes `part two` a flush-left checkbox,
so it is **promoted into a separate task** (:442-457). `addTask` (`:316`) only trims the
ends, so interior newlines reach the file. The task `id` is derived from the text, so
identity changes too.

Also **[V], low**: `ProjectHandoff.swift:656-669` strips *any* trailing ` · by …`, so a
task genuinely named `"rewrite the docs · by hand"` parses back as text `"rewrite the
docs"` with `addedBy == "hand"`.

### 12. `Shell.run` leaks two threads and two pipes when the spawn fails **[V] low**

`Support/Shell.swift:86-96`. Both reader `Thread`s start at :68-81; if `process.run()`
throws the function returns at :89-95 **without `readers.wait()`**, and they stay blocked
in `readDataToEndOfFile`. They are real `Thread`s deliberately off the dispatch pool
(:64-67), so each failed spawn permanently leaks 2 threads + 2 FDs.

**Fix:** close the pipe read ends before returning. *(Note: I did **not** bound
`readers.wait()` — see the REFUTED section for why.)*

---

## Tier 3 — shell injection

### 13. `HookInstaller.quoted()` only handles spaces; Codex TOML unescaped **[V]**

`Install/HookInstaller.swift:402-404` (used at :76, :88, :103, :116, :224):

```swift
path.contains(" ") ? "\"\(path)\"" : path
```

A path with `"`, `` ` ``, `$` or `\` is emitted **unquoted** into the hook `command`
string in `~/.claude/settings.json` and the Codex notify script. `notify = ["\(scriptPath)"]`
(:235) additionally needs `"`/`\` escaping for a TOML basic string; a path with either
produces an unparseable `config.toml`.

Same family, still unfixed elsewhere:
- **`Support/Doctor.swift:121-127`** uses `homeDirectoryForCurrentUser/.gentlemerge/bin/gentlemerge`
  instead of `paths.bin`, contradicting `GitHookInstaller.gateDefault` (:36-41). With
  `GENTLEMERGE_HOME` set (or Linux `XDG_STATE_HOME`), doctor reports "commits pass
  unchecked" for a healthy install. `DoctorTests` only sets `GENTLEMERGE_BIN`.
- **`Install/GitHookInstaller.swift:139-144`** — the "inside the repo" check for
  `core.hooksPath` uses `standardizedFileURL`, which resolves `.`/`..` but **not
  symlinks**. Verified: with `repo/.githooks -> ~/.config/git/hooks` the
  `hooksPathOutsideRepo` throw is skipped and the gate is installed into a directory
  **shared by every repo on the machine** — exactly what that error exists to prevent.
- **`Verify/ProjectChecks.swift:123`** — `xcodebuild -scheme '\(scheme)'` where `scheme`
  is a filename read from `<container>/xcshareddata/xcshemes` (:185-209), single-quoted
  with no escaping. Reached from `Landing.land:297`. Attacker-controlled repo content.
- **`Actions/TerminalBridge.swift:97`** — `TERM_PROGRAM` flows from the hook payload
  through `activities.json` into `tell application "\(name)"` unescaped;
  `applicationName(for:)` (:152-158) only strips `.app`.

### 14. `osascript` runs unbounded on the MainActor **[U]**

`Actions/TerminalBridge.swift:107-134`, called from `InboxModel.swift:1039` and `:1073`.
`run(_:)` does `process.run()` → `readDataToEndOfFile()` on stdout → on stderr →
`waitUntilExit()`, with **no timeout and no terminationHandler**.
`deliverNudges` runs on `@MainActor` from the 3-second `Timer` in `InboxModel.start()`
(:138), and `drainNow` is `@MainActor` too.

If `tell application "Terminal" to activate` hits a modal sheet, the MainActor wedges:
the app stops draining the spool, stops writing state, stops the delivery timer, with no
watchdog. `TerminalBridge` already returns `.failed("macOS blocked automation…")` for
`-1743`, so the failure mode is known to be reachable — the hang is the unhandled sibling.

**I could not construct the hang**, so verify before spending time. The structural
hazard (unbounded synchronous subprocess on the MainActor) is real regardless.

---

## Tier 4 — briefing, requests and app

### 15. `budgetMinutes` is never enforced as a deadline **[V]**

Grepped every use of `budgetMinutes`/`createdAt` outside `Requests.swift`: `AgentBus.swift:552`
(claim TTL), `Dispatcher.swift:66` (`Shell.run` timeout), `DispatchGate.swift:38,43`,
`Requests.swift:118` (`busSummary`). **No comparison of `now` against
`createdAt + budgetMinutes` anywhere.** `transition` (:189) does not check it;
`pending`/`inProgress`/`mine` do not filter on it.

A request created three days ago with `budget_minutes: 30` still appears in every
briefing and can still be accepted and completed at any later date.

### 16. A pending request is re-injected into every briefing forever **[V]**

`AgentBus.swift:949-957` builds `requestBlocks` from `Requests.pending` (:172), which
filters on `state == .queued || .assigned` with **no age, no expiry and no cursor dedup** —
unlike the "Your requests" block above it, which uses `cursor.seenRequestStates`. Nothing
ever moves a request out of `.assigned` on a timer.

If the delegate never starts (crashed, or the capability route picked a label that never
ran), every later `brief` from every agent in the project pays for the block, forever,
growing with the number of stale requests.

**Partially mitigated** by `96e600d` (a non-empty request block no longer kills the
silence fast-path entirely), but the repeated injection is unfixed.

### 17. Daily-budget gate overrides explicit human approval **[V]**

`Actions/DispatchGate.swift:37-41` checks `dispatchDailyBudgetMinutes` **before** `approved`:

```swift
if config.dispatchDailyBudgetMinutes > 0,
   spentTodayMinutes + request.budgetMinutes > config.dispatchDailyBudgetMinutes {
    return .needsApproval(target, reason: "daily budget … exhausted")
}
if approved { return .dispatch(target) }
```

`InboxModel.approve` (:783-793) writes the id and reports "Approved … the next drain will
check the dispatch gate", but the gate still returns `.needsApproval`, and
`approvalNotifiedIDs` (:850) suppresses re-notification — so the UI shows an approval
the user already granted, with no further feedback.

**Fix:** an explicit approval should win, or the budget check must run before the
approval is recorded.

### 18. `Dispatcher`'s post-run transition bypasses the callback contract **[V]**

`Actions/Dispatcher.swift:70-75` transitions straight via `store.transition`. Every other
state change goes through `RequestActions.perform` (`RequestActions.swift:20-41`), which
releases the delegate's `may_touch` claims, ticks the backing task, and posts a
`request-result` to `request.from`. This path does none of the three.

A headless delegate that times out gets `.failed` with: no result line for the delegator,
and the delegate's `may_touch` claims still live until TTL, blocking other agents on
those paths for up to `budgetMinutes`. Also `.assigned → .rejected` reports "process
exited without reporting" with no bus message — so the README's "automatic callback"
never fires for the most common dispatch failure.

### 19. A request decoded as `.queued` can never be accepted **[V] low**

`Requests.swift:107-108` (`state = RequestState(rawValue:) ?? .queued`) and the allowed map
(:194-201): `.queued: [.assigned, .rejected]`, but `accept` goes directly to `.inProgress`,
which is not reachable from `.queued`.

A request file with an unrecognised `state`, or missing the key, is permanently
un-acceptable — it shows in every briefing via `pending` and can only ever be rejected.
Note `.queued → .assigned` is permitted but **no code path performs it**;
`AgentBus.delegate:542` writes `.assigned` directly, so `.queued` is write-only today.

### 20. `Ownership.owner(of:)` mis-ranks specificity **[V]**

`Projects/Ownership.swift:135` ranks by `literalPrefix(...).count`, which truncates at the
first wildcard — so everything after it is ignored and any pattern starting with
`*`/`?`/`**` gets rank 0.

Confirmed mis-ranks:
- `**/models.dart` vs `lib/**` on `lib/models.dart` → resolves to `lib/**`'s owner.
- `lib/**/generated/**` vs `lib/api/**` on `lib/api/generated/x` → resolves to the latter.
- `lib/store/**` vs `lib/*` tie at rank 3, so the winner is **array order** — `[A,B]`
  gives A, `[B,A]` gives B.

### 21. `InboxModel` re-decodes the whole ledger per assigned request, per tick **[V] low**

`InboxModel.swift:832`: `Dispatcher.spentTodayMinutes(paths:now:)` is evaluated **inside**
the loop, and it (`Dispatcher.swift:10-28`) reads and JSON-decodes every line of
`ledger.jsonl`. With N assigned requests and an L-line ledger that is **N × L decodes
every 3 seconds**. Hoist it above the `for`.

---

## Tier 5 — small, mechanical, safe

| # | Location | Defect |
|---|---|---|
| 22 | `Bus/Identity.swift:37-41` | `CharacterSet.alphanumerics` is the **Unicode** category (L*/M*), not ASCII. Verified: `safe("c\u{2162}aude")` keeps U+2162 (ROMAN NUMERAL FIFTY). The docstring asserts `[A-Za-z0-9#-_.]`. Homoglyph labels render identically to `claude` but fail every `to == "claude"` route and every claim comparison. |
| 23 | `Store/Ledger.swift:129` via `CLI.swift:487` | `history -n` applies no bound: `-5` → `suffix(-10)` and `9223372036854775807` → `limit * 2` overflow. Both **SIGTRAP, exit 133**. |
| 24 | `Install/HookScript.swift:33-34` | `--provider) PROVIDER="${2:-unknown}"; shift 2 ;;` — with one argument left `shift 2` fails and, no `set -e`, `$#` never decreases. Verified: **infinite loop**, holding the agent's hook slot. Only the two value-taking arms are affected. |
| 25 | `Support/CommandArguments.swift:72-73` | `positional` does `index += 2` unconditionally even when `value(after:)` returned nil, silently eating the *following* flag. `value(after:)` at :45-49 handles it correctly. Reachable: `gentlemerge radar --project` → `single == false` at `CLI.swift:1161` → sweeps **every** project, no error. |
| 26 | `CLI.swift:1969-1970` | `--ttl` accepts a negative: `value(after:)` only rejects `--`-prefixed values (`CommandArguments.swift:48`), so `-5` passes; `-5 * 60 = -300`. Records a claim **born expired**, prints "0m left". |
| 27 | `Bus/MCPServer.swift:22-23, 37-40` | Unparseable input returns `nil` instead of `-32700` (mandatory per JSON-RPC §5 — the client waits forever). A valid non-object (batch array) hits the same path because `JSONValue.subscript` requires `.object`. Unknown **tool** name returns `-32601`, which is for unknown *methods*; MCP specifies `-32602`. |
| 28 | `Actions/SocketBridge.swift:48` | `write(fd, …)` in a single call, no partial-write loop and no `SIGPIPE` guard, while every other raw-write site loops and retries `EINTR` (`AgentBus.swift:725-736`, `JSONCoding.swift:126-137`). A short write is reported as success; `SIGPIPE` on Darwin terminates the process — from the MainActor, inside the app. **Currently unreachable**: `wireLine` (:29) always throws `unknownWireFormat`. Report only because the IMPLEMENTER contract (:18-20) is waiting for someone to fill it in. |
| 29 | `Actions/NudgeGate.swift:89-95` | Takes the socket branch on `Liveness.isProcessAlive(pid) == true` alone, without requiring `activity.state != .ended` unlike the tty path's `.idle` whitelist (:110). Combined with acknowledged pid reuse (`Liveness.swift:15-21`), a nudge can go to whatever inherited a recycled pid. |
| 30 | `CLI.swift:304-305`, `Support/Doctor.swift:95-97` | `kill(pid, 0)` without the `pid > 0` guard `Liveness.isProcessAlive` deliberately has (`Liveness.swift:28`). A corrupt `app.pid` of `-1` makes both print "app: running (pid -1)"; `0` signals the caller's whole process group. |
| 31 | `Store/AppConfig.swift:172-178` via `CLI.swift:413-414` | `save` is non-throwing and funnels failure into `Log.error`; `config` then calls `show(key)` and returns 0. A read-only home makes `gentlemerge config set claimsPolicy deny` print `deny`, **exit 0, persist nothing**. |
| 32 | `Bus/MCPServer.swift:105-106` | `task_add` answers `"added"` even when `ProjectRegistry.addTask` (:311-315) refused the text as a secret and returned the handoff unchanged. The agent believes the task is on the board. Same class the code explicitly fixed for `task_done` at :108-115. |
| 33 | `CLI.swift:2536, 2553-2554` | `test-event --blocking` passes `--mode blocking`, which `HookScript.swift:127-155` does not implement (it branches on `advise`/`context`), and still prints "Parked a permission request in the inbox." The vestigial arm also passes `--timeout 60`, silently discarded by the arg loop. |
| 34 | `Policy/Glob.swift:47` | `normalize` strips `./` and trailing `/` but never rejects or relativises an absolute or `..`-bearing pattern. `matches("/abs/lib/store/**", "lib/store/x.dart")` is **false** (confirmed), while staged paths are always repo-relative. `claim --paths` performs no validation, so such a claim silently protects nothing. |
| 35 | `Store/Stats.swift:170-176` | `count(before:)` uses `summary.range(of: word)`, which finds the **first occurrence anywhere**. `"claim-fix -> main @ abc: 3 file(s), 1 claim(s) released"` → `count(before: "claim")` = **0**. Also `"mypath/agent: 2 path(s) landed"` → `count(before: "path")` = 0. Affects `coordination value` reporting only, silently. |
| 36 | `Bus/Presence.swift:231-241` | Identity uses only the last path component, so `/Users/alice/code/app` and `/Users/bob/code/app` collide on one file for the same label+branch. Reproduced: two marks recorded, **one on disk**. `ProjectRegistry.canonicalPath` maps every worktree to one repo root, so that component is the only discriminator left. |
| 37 | `Ingest/EventTranslator.swift:150, 177-178` | `base(...)`'s `paths:` parameter defaults to `[]` and **none of the six call sites pass it**; `PathExtractor.paths(toolName:input:)` (`Policy/PathScope.swift:21`) has **zero callers** in `Sources/` or `Tests/`. So `InboxItem.touchedPaths` is always nil and `scope` always `.unknown`, and the "outside the project" detection in `Verify/InboxModel+Review.swift:140,144` — the third bullet of the README's Review row — **never fires**. |
| 38 | `Install/GitHookInstaller.swift:202-209` | The idempotency check is on `marker`, a compile-time constant, but the script **body** varies per install (the resolved gate path). Reinstalling after changing `GENTLEMERGE_HOME` reports "already installed" while the hook still points at the old home; :173 does re-link the new binary, so every commit prints "gate binary not found … this commit is NOT checked" and passes unchecked. |
| 39 | `Install/GitHookInstaller.swift:214` | The foreign-hook branch does not remove its target, so a stale `*.gentlemerge-prev` makes `moveItem` throw out of `install()` → exit 1 with nothing installed and a misleading message. |
| 40 | `Projects/ProjectRegistry.swift:257` | `parseLog` trims each line, corrupting ` leadingspace.txt` and `trailingspace.txt `. Confirmed against real `git log --name-only`. The overlap report then compares a trimmed path from `CommitRecord.files` against an untrimmed one from `parseStatus`, so they never match. |
| 41 | `Projects/ConflictRadar.swift:245-257` | `announced` is TTL-pruned and `lastRun` capped at 200, but `lastAutoNote` and `pairOffset` are never pruned — the growth concern the comments state applies to them too. |
| 42 | `Projects/ProjectMap.swift:249, 272` | `sorted { ($0.value, $1.key) > ($1.value, $0.key) }` sorts the **name** descending, so equal counts list backwards (`Tests (30) · Sources (30)`). |
| 43 | `Store/AppConfig.swift:64-66` vs `CLI.swift:391` | `<= 0` is documented as "uncapped" but the CLI requires `minutes > 0`, so `0` — the only way to express uncapped — is rejected. |
| 44 | `Support/Doctor.swift` | See #13 above. |

### Also worth a look (cosmetic / latent, not bugs)

- `Policy/PathScope.swift:64` — dead ternary: `paths.isEmpty ? .unknown : .unknown`.
  Harmless today, reads as a lost `else .outside`.
- `Projects/RepoIdentity.swift:95` — `isLinkedWorktree` has no callers in `Sources`.
  The security-relevant half (`collapse` at :57-68) **is** exercised.
- `InboxModel.swift:449` — `noteUnfinishedWork` builds an `InboxItem` directly,
  bypassing `EventTranslator.base`, so raw task text from the hand-editable
  `HANDOFF.md` lands unscrubbed in `state.json` and `ledger.jsonl`. Both files are
  inside the `0700` home and the source is already readable by every agent, so no
  trust boundary is crossed — but it contradicts the "scrub here and all three are
  clean" invariant at `EventTranslator.swift:152-156`.
- `Bus/Redactor.swift` — the suppression heuristic compares `text.count` (pre-ANSI-strip)
  against a `redactedCharacters` total accumulated on the post-strip `working`, which
  over-estimates `survived` and under-suppresses. Fails **open**, so minor.
- `Landing.swift:373` — the `line.isEmpty` branch is dead because `Output.lines` drops
  empty subsequences. Harmless: every porcelain block opens with a `worktree ` line.
- `Bus/MCPServer.swift:326` — `serve()` uses `readLine()`, correct for newline-delimited
  MCP stdio; no Content-Length framing applies. No desync possible, since JSON forbids
  raw newlines in strings.

---

## REFUTED — do not chase these

### `Shell.run` hanging forever past its timeout **[R]**

Reported as "unbounded `readers.wait()` after the child is killed → indefinite hang in
`land`". **False on this platform.** With correct instrumentation (separate
semaphores for reader-done and process-exited) the reader always returns within 5s of
the kill, for a plain `sh -c "echo hi; sleep 30"`, for a backgrounded sibling, and for a
grandchild that inherits stdout.

My first probe used **one semaphore for both events**, so the reader's signal satisfied
the wait meant for termination — an artifact of the probe, not the code. Two XCTs I
wrote for this passed against the vulnerable code, which is how I caught it.

I implemented the bounded wait, then reverted it and deleted the tests. Do not
"restore" it: it looked like a fix for a bug that does not exist.

### `U` in the pre-commit `--diff-filter` **[R]**

`U` is inert — a real merge conflict gives `U` in the index and the filter does return
empty, but **git itself refuses to commit**: `fatal: Exiting because of an unresolved
conflict` (exit 128). Once resolved the entry becomes `M` and the commit *is* blocked
(verified with `--theirs`). `T` was the real gap and is fixed in `485f09c`.

### file→directory replacement escaping the gate **[R]**

Not a `T`. Git reports `D` + `A`, both listed, blocked (exit 1). Only **file→symlink**
escaped, and that is fixed.

### The presence-derived gate identity in the usual multi-worktree layout **[R, scoped]**

Real, and fixed — but narrower than reported. `Presence.fileURL` embeds the **branch**,
and the old fallback required `live.count == 1`. A mark on a **different** branch gives
2 marks → fallback nil → **blocked**. So "five agents, five worktrees, five branches"
was never vulnerable. The bypass needed exactly one live mark on the committing
worktree's branch. Also note `CLI.swift:32` calls `noteThatWeAreHere(rest)` before
*every* command, which adopts the same identity, so the state was self-sustaining.

### `--diff-filter` missing `B` (broken pairing) **[R, no impact found]**

Swept; could not construct a case where it matters.

---

## Working notes

**Concurrency model.** The protocol is the filesystem; several writers per project
across separate processes. `flock` is **advisory and per-process** — it serialises
cooperating threads in one process, and cooperating *processes* only if they all take
it. Anything that does not, is racy by construction. The single-writer assumption is
stated in `BriefingCursor.swift:4-5` and is wrong for `brief --as <label>`.

**Testing.** 645 tests, 1 skipped. The gaps that let all of the above through are
characterisation, not effort: no test used a **non-ASCII path**, a **rename**, a
**symlink**, or a **concurrent reader**. `StagedFilesTests` and `AtomicFileTests` are
written to close exactly those holes and are the pattern to copy.

When adding a regression test here, **confirm it fails against the unfixed code**
before believing it. Reverting each fix and re-running caught three of my own tests
that could not have detected the bug they claimed to.

**Verified-good, do not re-investigate** (it saves a lot of duplicated effort):
`Glob.swift` semantics — `**/` compiles to `(?:.*/)?` so zero directories match;
`*`/`?` are `[^/]*`/`[^/]` and correctly refuse to cross `/`; anchors present.
`PathScope.normalized` path traversal — `standardizedFileURL.resolvingSymlinksInPath()`
collapses `..`, symlinks and `/repo` vs `/repo2` prefix collisions; a NUL byte is
percent-encoded, never passed through. Git argv usage — `Landing`, `ConflictRadar`,
`GitSnapshot`, `PrecommitCheck`, `WorktreeAdoption` all pass argv arrays, so a branch
named `foo; rm -rf /` is safe; the only string-building shells are the three `Shell.sh`
call sites in #13. `merge-tree` exit codes and output format, correct on git 2.50.
`pre-merge-commit` does not run for `--ff-only` and `post-merge`'s exit status does not
affect `git merge` — both assumed correctly by `Landing`. `Requests.transition` holds an
exclusive lock for the whole read-check-write, so `done` cannot fire twice, and terminal
states are genuinely terminal. `Requests.validID` rejects `/`, `.` and everything
outside `[A-Za-z0-9_-]`, so `url(_:)` cannot escape `paths.requests`. `Delegate` claims
`may_touch` under the target's label and releases them in its `catch`, so a failed
delegate leaves no orphan reservation. Redaction is applied consistently on every path
traced to disk or socket. No force unwraps anywhere in the gate/claim/glob path; every
array index is guarded by a preceding count check.
---

## Wrong, and what I got wrong

Kept because the cost of an audit that never says "I was wrong" is that nobody
trusts the parts that are right.

**A claimed bug that was not a bug: `Shell.run` hanging forever past its
timeout.** I reported it, then built a fix and a test for it, and the test
**passed against the vulnerable code**. My probe was at fault: it used one
semaphore for both the reader and process-exited events, so the reader's signal
satisfied the wait meant for termination. Rebuilt with separate semaphores, the
reader always returned within 5s of the kill, in all three shapes (plain `sh -c`,
a backgrounded sibling, a grandchild inheriting stdout). I reverted the fix and
deleted the tests. Do not "restore" it.

**A bug I declared fixed that I had not.** Same file, same function: I initially
called `Ledger.recent`'s crash the `suffix(limit * 2)` overflow. Clamping that was
not enough — `prefix(limit)` sat three lines below reading the *raw* value, and
that is the call that actually traps. My first test caught it by crashing the
whole test process with SIGTRAP.

**A fix that made things worse, twice.**
- *Closing pipe handles to unblock readers:* closing a `FileHandle` another
  thread is reading raises `NSFileHandleOperationException` on that thread. The
  suite caught it. A slow leak is better than a crash.
- *Assuming #12 was a permanent leak (writing it off, wrongly):* the reader
  closure captures its `Pipe` strongly, so a blocked thread keeps the Pipe alive,
  which keeps the write end open, which is what the reader is waiting for. The
  closure and its resource hold each other up. Measured: **120 threads over 60
  failed spawns**, still alive after 1.5s. The handoff had it right and I talked
  myself out of it. Fixed properly by not starting the readers until the spawn
  succeeds.

**Three of my original claims were overstated, and adversarial review caught
them** — the corrections are in the numbered sections above:

- "no glob can match a C-quoted path" is false: `**` and `**/*` do. Every
  realistic zone pattern fails, so the conclusion held but the phrasing did not.
- `U` in the pre-commit diff-filter is **inert** — git refuses to commit an
  unresolved index, so it never reached the gate. Only `T` was a real gap.
- The presence-derived gate identity needs exactly **one** live mark **on the same
  branch**; the usual five-worktrees-five-branches layout was never vulnerable.

**Two tests that could not have detected their own bug** — caught by reverting
each fix and re-running, which I did for every fix in this branch:

- The #1 delivery-lock test was two sequential reads. Passes with the lock deleted.
- My first `testTheScriptItselfStaysOneTellStatement` asserted a sanitised app
  name would not contain "to quit". It does — as inert text inside the string
  literal. The words surviving is correct; only the delimiter should go.

**One accidental repo incident, no damage.** A review subagent ran a script with
an unset variable, so its `cd` failed and `git init/add/commit` executed inside
the real repository: 30 throwaway commits on `main` and HEAD moved. Verified and
restored — `public-beta` = `051c5e6` = `origin/public-beta`, `main` = `1c70adc`,
all 9 stray commits unreachable, working tree clean. Worth knowing that happened.

---

## Still open

Deliberate, with the reasoning. None is a landmine; all are documented in code.

**1. The Redactor rewrites long digit runs in paths.** Found while fixing #37, not
in the handoff. `Redactor.scrub` treats a 20-digit run as a sensitive number —
pinned by a test for `"account 21452098"` — so a path under a UUID temp directory
comes back as `[redacted number]` and stops matching its project. A real path can
legitimately contain long numbers. Suppressing that is a wider call than this
audit, and the Redactor is deliberately fail-open, so it was left alone. Any test
asserting on a path under a UUID temp directory will see a redacted one.

**2. `osascript`'s timeout is judgement, not measurement.** I could not construct
the hang (#14 was `[U]` from the start). The bound is 10s, and the code says so.

**3. Glob case-sensitivity.** `Glob.regex` builds an unanchored-by-case
`NSRegularExpression`; macOS APFS is case-insensitive by default. Git normalises
the recorded case toward the on-disk spelling, so I could not produce a live
bypass on this machine. Medium, medium confidence. Untouched.

**4. Dead code, left as-is.** `RepoIdentity.isLinkedWorktree` has no callers in
`Sources` (the security-relevant half, `collapse`, is exercised);
`PathScope.PathExtractor.scope`'s dead ternary `paths.isEmpty ? .unknown :
.unknown`; `Landing.swift`'s `line.isEmpty` branch, unreachable because
`Output.lines` drops empty subsequences; `MCPServer`'s hardcoded `"mode":"notify"`
in `HookScript`, which nothing reads.

**5. `InboxModel.noteUnfinishedWork` bypasses `EventTranslator.base`,** so raw task
text from the hand-editable `HANDOFF.md` lands unscrubbed in `state.json` and
`ledger.jsonl`. Both files are inside the `0700` home and the source is already
readable by every agent, so no trust boundary is crossed — but it contradicts the
"scrub here and all three are clean" invariant at `EventTranslator.swift`.

**6. `Redactor.scrub`'s suppression heuristic** compares `text.count`
(pre-ANSI-strip) against a `redactedCharacters` total accumulated on the
post-strip `working`, which over-estimates `survived` and under-suppresses. Fails
**open**, so the direction is the safe one.

**7. `Glob.normalize` no longer strips absolute prefixes**, because nothing here
knows the repository root. `matches` handles absolute patterns by trying each
trailing window of their components instead — which fixes #34 but is not as
precise as resolving the real root would be. A caller that *can* know the root
(the gate does) should relativise there.

**8. `briefing`'s per-session delivery lock is advisory.** `flock` only serialises
cooperating callers, so `brief --as <label>` from a shell that does not take it
still races. Every writer in-process does; a future writer in another language
would have to know.

---

## Verified-good, do not re-investigate

`Glob.swift` semantics — `**/` compiles to `(?:.*/)?` so zero directories match;
`*`/`?` are `[^/]*`/`[^/]` and correctly refuse to cross `/`; anchors present.
`PathScope.normalized` path traversal — `standardizedFileURL.resolvingSymlinksInPath()`
collapses `..`, symlinks and `/repo` vs `/repo2` prefix collisions; a NUL byte is
percent-encoded, never passed through. Git argv usage — `Landing`,
`ConflictRadar`, `GitSnapshot`, `PrecommitCheck`, `WorktreeAdoption` all pass argv
arrays, so a branch named `foo; rm -rf /` is safe; the only string-building
shells are the `Shell.sh` call sites and the two installers, both now escaped.
`merge-tree` exit codes and output format, correct on git 2.50.
`pre-merge-commit` does not run for `--ff-only`, and `post-merge`'s exit status
does not affect `git merge` — both assumed correctly by `Landing`.
`Requests.transition` holds an exclusive lock for the whole read-check-write, so
`done` cannot fire twice, and terminal states are genuinely terminal.
`Requests.validID` rejects `/`, `.` and everything outside `[A-Za-z0-9_-]`, so
`url(_:)` cannot escape `paths.requests`. `Delegate` claims `may_touch` under the
target's label and releases them in its `catch`, so a failed delegate leaves no
orphan reservation. Redaction is applied consistently on every path traced to
disk or socket. No force unwraps anywhere in the gate/claim/glob path; every
array index is guarded by a preceding count check. `AtomicFile.write` now uses a
real `rename(2)`, so concurrent readers see whole files.
