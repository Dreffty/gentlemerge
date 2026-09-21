# Testing GentleMerge by hand

Everything below is safe: the automated suites use throwaway directories, and the
only step that touches your real configuration is step 2 — backed up, and undone
with one command.

Give yourself the shortcut first (it is already in `~/.local/bin`):

```bash
gentlemerge --version
```

---

## 0 · The automated suites

```bash
swift test && make app && sh Scripts/smoke-test.sh
```

Require zero test failures and `100 passed, 0 failed` from the smoke with the
macOS bundle available. Without the bundle, GUI-backed checks are skipped and
the count is lower. Always rebuild first; an old app plus a new CLI is not a
verification of this checkout. Runtime varies with builds and the machine.

Linux evidence (real run, not CI-cache): ubuntu 22.04 (`swift:6.0-jammy`,
Swift 6.0.3) with git ≥ 2.38 from the git-core PPA — the image's stock git
2.34 is too old for `merge-tree` and the radar/landing tests fail with it.
With the repo mounted and `GENTLEMERGE_BIN` pointing at the container build:
`swift test` 480 passed, 0 failed; `Scripts/smoke-test.sh` 112 passed,
0 failed (fewer than macOS: GUI/app checks skip off-mac). This run is what
caught `SOCK_STREAM` being `__socket_type` under Glibc — the Core did not
compile on Linux before it.

The new multi-agent smoke uses two temporary Git worktrees and verifies:

1. `project init --label` isolates identities; A's path claim is visible from B.
   B's staged conflicting commit exits 1, then succeeds after A releases it.
2. A delegates to B; B accepts, writes a result and marks it done; A's brief
   contains its path and A acknowledges it.
3. Two successive `UserPromptSubmit` payloads select delta mode; after the first
   consumes the news, the second returns no output.
4. A real MCP process answers `initialize` and `tools/list` via stdin/stdout.
5. `session-context` records every injection; `stats` counts the session's two
   deltas and the global line always says estimate.
6. The conflict radar warns both sides about the same-line edit exactly once;
   B lands onto main (main moves, the bus says `landed`); a dry run from A
   refuses with the file and who touched it, moving nothing.
7. `env` prints the worktree's stable port range; `env --write` saves
   `.gentlemerge/env.sh`, kept out of git by `init`.
8. The hook carries `CLAUDE_CODE_MESSAGING_SOCKET` into the envelope when set.

The GUI bridge checks each session's actual task, not the number of `who` lines
(which may also include CLI presence marks). Harness hooks receive the live test
app PID because a transient shell is not a long-lived agent. Production wrappers
may pass `GENTLEMERGE_PID` when they know the actual agent PID. Repository aliases
and subdirectories are canonicalized before activities join the shared bus.

All stores, agent configs and Git hooks in this smoke are temporary. It starts no
real AI agent and does not spend provider credits. Live MCP-client setup,
headless dispatch CLI management, and manual approval-button interaction are not
covered; see the limitations in README.

---

## 1 · The window (1 minute)

```bash
make run
```

The window opens and the tray icon appears. The window is the workspace; the menu
bar is a glance and a way back in.

With no agents running it says so. Leave it open for the next step.

---

## 2 · Two agents seeing each other (5 minutes) — the actual product

```bash
make install-hooks
```

```bash
gentlemerge status
```

`SessionStart` and `UserPromptSubmit` must say **"shares context with this
session"**. If they say "reports it", you are on the old hooks — reinstall.

Now, in **two different terminals**, start a session in the *same* project:

- Terminal A: `claude`, ask for something concrete ("mira por qué falla el test X").
- Terminal B: `codex` (or a second `claude`), ask for something else.

**Expect in the window:** both sessions under `WHO IS ON THIS`, each with the
prompt you typed as its current task, updating as they work.

**Expect in the agents:** ask the *second* one — *"¿sabes si hay otro agente
trabajando aquí?"*. It should answer with what the first is doing, without you
telling it anything. That is the briefing injected on its turn.

Then, from inside that project (`--global` if it is every project's business):

```bash
gentlemerge say "no toquéis el árbol de recompensas"
```

Ask either agent again on its next message: it should know. A session working
in another project should not — check with a third one somewhere else. Messages are
delivered once — asking a third time should not repeat it.

### An agent that dies mid-turn

The failure this is really about: a session that falls over does not run its
`SessionEnd` hook, so without the sweep it stays "working" in everybody else's
briefing for six hours. With both terminals still going, kill one outright:

```bash
pgrep -fl claude          # find the one you started in terminal A
kill -9 <pid>
```

Within one drain (three seconds, app running):

```bash
gentlemerge who
```

**Expect:** that session under `Recently died:` as `(died just now)`, and gone
from the live list. Ask the surviving agent on its next turn whether anybody
else is working here — it must not name the dead one. If the dead session had a
task with unticked points, the window has a row for it, and the *next* session
in that project is told about the same points in its briefing.

`who` reports the death even with the app closed: the check is a `kill(pid, 0)`,
and every reader does it for itself.

### An agent with no hooks (Hermes)

Hermes never sees a hook — its wrapper is the hook. From inside the project,
pretending to be the other agent for a moment:

```bash
gentlemerge say "traduce los textos de constants/ al inglés" --to hermes
gentlemerge brief --as hermes         # arrives
gentlemerge brief --as hermes         # silence: it was delivered
gentlemerge say --from hermes "traducidos 40 textos"
gentlemerge say --from hermes --done
```

**Expect:** the note in the first read and nothing of it in the second. Plain
`gentlemerge brief`, with no `--as`, must *not* consume it — run it before the
first `--as` and the note is still waiting afterwards.

### A session that launches executors

```bash
gentlemerge say "el schema es mío" --to claude
GENTLEMERGE_NAME=claude#exec1 gentlemerge brief --as claude#exec1
```

**Expect:** the executor is handed a note addressed to `claude`, and is not told
it is "for" somebody else. A note `--to claude#exec1` reaches that one only —
`--as claude#exec2` stays silent.

### Undo

```bash
make uninstall-hooks
```

---

## 3 · The handoff between sessions (3 minutes)

```bash
gentlemerge handoff --project ~/ruta/al/repo
```

Read-only: prints what the next session would be told, with the last three
commits from `git log`. Then set it up for real:

```bash
gentlemerge project init --project ~/ruta/al/repo
```

```bash
gentlemerge task add "Lo que quede pendiente" --project ~/ruta/al/repo
```

Now edit `.gentlemerge/HANDOFF.md` **like an agent would**: tick a box, add
`- [ ] otra cosa` at the very bottom (inside the wrong section, on purpose), add a
`## Decisiones` section of your own.

```bash
gentlemerge task list --project ~/ruta/al/repo
```

**Expect:** your misplaced task is in the list, the ticked one is done, and your
`## Decisiones` section is still in the file. That property is why the file is
worth trusting.

**The real test:** close that Claude session, open a new one in the same project,
and ask *"¿por dónde íbamos?"*. It should know the commits and the open tasks.

### Two agents reaching for the same task

```bash
gentlemerge task claim 0 --project ~/ruta/al/repo --as claude
gentlemerge task claim 0 --project ~/ruta/al/repo --as codex ; echo "exit $?"
gentlemerge task list --project ~/ruta/al/repo
```

**Expect:** the second one prints `claimed by claude just now — talk to them or
wait` and exits 1, the list annotates the task `· claimed by claude (just now)`,
and — the part that matters — **`HANDOFF.md` has not changed at all**. Check it:
`md5 -q .gentlemerge/HANDOFF.md` before and after. Claims live in
`~/.gentlemerge/claims.json`; a suffix on the task line would change the id the
task's text hashes to and split it in two for any older binary.

Then `gentlemerge task release 0 --project … --as claude` and claim it as codex:
it should go through. Ticking the task off releases it too.

**Also worth trying by hand:** claim something, `kill -9` the session that did it,
and look at the list from another terminal — the claim should be gone, with
nobody having cleaned anything up.

### Avísame cuando (the watch)

The delivery half needs the app running, because the app is what notices. With it
up and two sessions going in the same project:

```bash
gentlemerge watch idle codex --note "then I merge"
gentlemerge watch task 0 --project ~/ruta/al/repo
gentlemerge watch list
```

Now let the Codex session finish a turn, and from a *different* identity tick the
task off (`GENTLEMERGE_NAME=codex gentlemerge task done 0 --project …`).

**Expect:** on your next turn, a note from `inbox` in your briefing —
`watch: codex finished a turn — then I merge` and `watch: task done — <the task>`
— and `gentlemerge watch list` empty afterwards. Each rule fires once: ask for
another turn and nothing repeats. A rule that never matches costs nothing and is
gone after 48h.

**The one worth doing by hand:** `gentlemerge watch session-end codex`, then
`kill -9` that session. A session that dies never sends a `SessionEnd`, and this
is precisely the case you were waiting on — the sweep that buries it must fire
your watch within one drain.

### Leaving a file behind (the attachment)

```bash
printf '# Informe\nDesplegado con ANTHROPIC_API_KEY=sk-ant-api03-XXXXXXXXXXXXXXXXXXXX\nel puerto es 8080\n' > /tmp/report.md
gentlemerge say "te dejo el informe" --to codex --attach /tmp/report.md
```

**Expect:** one `→ attachment: ~/.gentlemerge/artifacts/<hash>/report.md (…)`
line, and the note delivered normally. Then open the stored copy: the key is
`[redacted key]` and the rest of the report is intact, while `/tmp/report.md` —
the file you wrote — still has the key in it. On the Codex session's next turn
the briefing carries the path and the first lines, and nothing else: the file
itself is for that agent to open if it decides the summary is worth following.

Worth trying the refusals, since they are the whole point of the limits: a file
over 2 MB, and a file whose entire content is a key. Both exit non-zero, say
why, and post no message at all.

An image or any other binary attaches too, copied byte for byte, and every line
that mentions it says `(binary — not scrubbed)` — the one thing that crosses
between agents unread.

---

## 4 · Review and restore points (3 minutes)

```bash
gentlemerge review ~/ruta/a/un/proyecto
```

Three sections: `WHAT CHANGED`, `CHECKS`, `NEEDS YOUR EYES`. Exits non-zero if a
check fails. The part worth judging is the last one: it should say something true
and uncomfortable. If a review ever reads as "all good", that is a bug.

```bash
gentlemerge snapshot create "antes de romper cosas" --project ~/repo
gentlemerge snapshot restore <id> --project ~/repo
```

**Expect:** edited files back to their contents, files the agent created still
there and listed as left in place, an undo command at the end, and `git status`
showing your staging area untouched.

---

## 5 · The nudge (5 minutes) — the only part no suite can run

Typing into another terminal needs a real terminal and macOS Automation
permission, so this one is by hand on purpose. Everything about *whether* to type
is a pure function (`NudgeGate`) and is covered by `swift test`; what is left to
try is the push itself.

```bash
gentlemerge status | grep nudges
```

Says `off` until you turn it on: **menu bar icon › ⋯ › "Let agents type a
one-line notice into an idle terminal"**. Leave it off for the first half.

**With it off** — in a `claude` session, ask for something, let it finish, and
leave it sitting at its prompt. From another terminal:

```bash
GENTLEMERGE_NAME=codex gentlemerge say "no toques el schema" --to claude --urgent --nudge
```

**Expect:** nothing typed anywhere, and one line in the ledger saying why:

```bash
grep '"nudge ' ~/.gentlemerge/ledger.jsonl | tail -1   # reason: "nudges are off"
```

**Now turn it on** and send the same note again (a different text — a note you
already sent is not news). The first time, macOS asks whether GentleMerge may
control iTerm2; say yes.

**Expect**, within one drain (3 s), typed into the *idle* session and submitted:

```
GentleMerge: new message from codex — it will be in your next briefing
```

That turn triggers `UserPromptSubmit`, the hook injects the briefing, and the
actual note arrives there. The ledger line now reads `reason: "typed"`.

The four that matter more than the happy path:

1. **Mid-turn.** Ask the session for something long, and nudge it while it works.
   Nothing is typed; the ledger says `recipient is working`.
2. **On a permission dialog.** Get the session to ask for permission to run a
   command, and nudge it while the dialog is up. **Nothing must be typed.** This
   is the dangerous case: text typed at that prompt is the *answer* to it, and
   GentleMerge approving a tool call by accident is the one outcome that would
   make this feature unshippable. The ledger says `recipient is waiting on you`.
3. **Twice in a row.** Send two nudges a minute apart. The second one is
   swallowed: `nudged 1m ago`. Ten minutes later one gets through again.
4. **A dead session.** `kill -9` the claude session, then nudge it. Nothing is
   typed — the ledger says `process is gone` or `terminal is gone`.

Then turn it back off if you do not want it: it is opt-in for a reason.

---

## §Live · With real Claude Code / Codex sessions

The suites above simulate hooks. This section confirms the real thing: two
live sessions, two worktrees, the demo script replayed by hand. It spends
provider credits — a few turns each — and touches your real agent configs
(backed up by `install`, reversible with `uninstall`).

```bash
gentlemerge install
cd your-repo
gentlemerge init --git-hooks
git worktree add ../wt-claude -b agent/claude && (cd ../wt-claude && gentlemerge init --label claude)
git worktree add ../wt-codex -b agent/codex && (cd ../wt-codex && gentlemerge init --label codex)
```

Open one Claude Code session in `../wt-claude` and one Codex session in
`../wt-codex` (restart both after `install` so the hooks load). Then replay
the demo, one line per session:

1. In claude: claim a zone and edit it (`claim --paths 'lib/store/**'`,
   edit, commit → `commit ok`).
2. In codex: claim another zone, edit, commit → `commit ok`.
3. In claude: `delegate --to codex --title … --may-touch 'assets/**'`;
   in codex: `request accept`, edit, commit, `request done`.
4. In claude: edit one of codex's files and commit → expect the BLOCKED
   line naming codex's claim; then `say --to codex …`.
5. In codex: read the next turn's briefing — the message must be there.

What to record: whether each beat behaved as the demo prints it, the exact
`gentlemerge --version` of both ends, and — for step 5 of the nudge section —
whether a socket delivery arrived (see below). Open an issue with the result;
a `needs verification` row in the README turns into a plain ✅ on your word.

Socket delivery (`needs verification` until a live session confirms it):
with `allowNudges` on, `say --to <other> --nudge …` from one session, then
check the other's transcript for the fixed notice line and the ledger for
`socket` vs `nudge.socket.fallback_tty`. If the notice arrived while the
session was idle without anything typed into its tty, the socket path works.

---

## §Sim · Without any AI

```bash
gentlemerge demo        # three simulated agents, one temp repo, ~20 seconds
gentlemerge demo --keep # keep the temp repo to inspect it afterwards
gentlemerge sim --script file.json --worktree dir   # your own script
```

`demo` replays the README story — claims, commits, a delegation round-trip,
a BLOCKED commit, a cross-agent message, hermes's briefing — and closes with
the live coordination-cost line. It runs in an isolated `GENTLEMERGE_HOME`,
touches nothing of yours, and spends zero tokens.

A sim script is JSON: `{"label": "…", "capabilities": […], "steps": […]}`,
one step per action: `claim` (`paths`, `text`), `edit` (`paths`, `text`),
`commit` (`text`, `expectBlocked`), `say` (`text`, `to`), `brief`,
`delegate` (`text`, `to`, `may-touch`), `request_accept`, `request_done`
(`text`), `release`, `sleep` (`seconds`). The CLI runs each step the way the
real commands do — including the actual pre-commit hook on `commit` — so a
script that passes here exercises the same gates the agents hit.

---

## What to report back

- Step 2 is the one that has never run with real agents. If the window shows the
  sessions but they do not *know* about each other, the reporting works and the
  injection does not: check `gentlemerge brief` from that project directory — if
  it prints the briefing, the problem is Claude Code not taking
  `additionalContext` from `UserPromptSubmit`.
- If the briefing shows up on every single turn, the deduplication is broken.
- Anything in a review that reads as reassurance rather than evidence.
- **Anything at all typed into a session that was not `idle`** (step 5). That is
  not a bug to file later: turn nudges off and say so.
