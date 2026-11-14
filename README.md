# GentleMerge

**Vendor-neutral coordination layer for AI coding agents that share one repository.**

Claude Code, Codex, Hermes, Gemini CLI, OpenCode — anything that speaks MCP or git — working on the same project at the same time, without stepping on each other, without spending tokens watching each other.

100% local. No cloud, no accounts. Your code stays on your machine — note your agents' own providers may be remote; that traffic is between you and them.

```
$ gentlemerge demo
ownership: lib/store/** → claude · lib/data/** → hermes · assets/** → codex

[hermes]  claimed lib/data/**
[hermes]  edited lib/data/models.dart
[hermes]  commit ok
[claude]  claimed lib/store/**
[claude]  edited lib/store/product_page.dart
[claude]  commit ok
[claude]  delegated req-7f3a82 → codex (may touch: assets/**)
[codex]   accepted req-7f3a82
[codex]   edited assets/hero_ropa.png.txt
[codex]   commit ok
[codex]   done req-7f3a82 · assets/hero_ropa.png.txt
[claude]  edited lib/data/models.dart
[claude]  commit BLOCKED: ✖ lib/data/models.dart: owned by hermes per HANDOFF.md; claim it explicitly to override
[claude]  → hermes: need a nullable `sku` on Product, can you add it?
[hermes]  briefing:
    Other agents you have running right now (from GentleMerge):
    - Claude Code · repo on agent/claude (just now, working)
    - Codex · repo on agent/codex (just now, working)

    Messages left for you:
    - #3163 claude · repo (just now): need a nullable `sku` on Product, can you add it?

    Newly claimed by others:
    - claude: `lib/data/models.dart` [14m]

coordination cost: 3 briefings (3 non-empty) · ≈ 582 tokens total · ≈ 194 tokens/turn (estimate: chars/4)
```

*(The token counts and the id numbers move a little run to run — the briefing
cost is measured, and `chars/4` is an estimate.)*

## Why

Every vendor now ships a multi-agent story — for *their own* agents. Claude Code sessions message Claude Code sessions. Codex threads coordinate with Codex threads. Nothing coordinates a Claude, a Codex and an open-weights model on the same repo.

And every existing approach relies on the model *remembering* to check what others are doing — which either fails or burns half your budget on vigilance.

GentleMerge takes the opposite stance: **coordination is infrastructure, not intelligence.**

| Problem | How GentleMerge solves it | Tokens |
|---|---|---|
| Two agents edit the same file | **Path claims**, created automatically when an agent edits; a **git pre-commit hook** rejects commits that invade another agent's live claim or ownership zone | 0 |
| Agent doesn't know what others are doing | **Delta briefings** injected only when something changed, hard-capped at ~300 tokens; empty when nothing's new | ~100/turn |
| "This task is better done by another agent" | **Requests**: a contract with `may_touch` paths, time budget, state machine and automatic callback. Delegate and keep working | ~50 once |
| Branches will conflict at merge | **Conflict radar** (`git merge-tree`) warns both agents early; `gentlemerge land` rebases, runs checks, fast-forwards | 0 |
| Dev servers collide on ports | Per-worktree `env.sh` with its own 100-port range (labels absent from `config.json` get one derived from a stable hash — different labels, but not a guarantee across every possible name; add `agents` to `config.json` for the guarantee) | 0 |
| "Did the agent actually do it right?" | **Review** lists what changed, what checks ran, and what *nobody verified* — never says "all good" | 0 |

The per-turn figure is measured, not hoped for: a month of one person's real use came to 466 briefings and about 47,400 tokens, some 100 a turn. `gentlemerge stats` shows yours.

## How it works

Each agent works in its own **git worktree** with a label (`claude`, `codex`, `hermes`…). GentleMerge is one small binary that:

1. **Listens** — via hooks (Claude Code, Codex) or its **MCP server** (everything else).
2. **Records** — who is editing what, messages, requests, presence — as plain JSON/Markdown under `~/.gentlemerge` and `<repo>/.gentlemerge/HANDOFF.md`. *The protocol is the filesystem* ([docs/FILE_FORMATS.md](docs/FILE_FORMATS.md)): any language can read or write it.
3. **Enforces** — a `pre-commit` hook that costs no tokens and can't be forgotten.
4. **Briefs** — injects only what changed into each agent's next turn.

The optional macOS menu-bar app shows the board, approvals and reviews. Everything else — claims, briefings, the gate, requests, land — works without it: read commands drain the spool on demand, on macOS and headless Linux alike. What needs the app is live socket/tty nudges and the UI itself.

## Install

**macOS / Linux / WSL2**
```sh
git clone https://github.com/Dreffty/gentlemerge && cd gentlemerge
make install            # → ~/.local/bin/gentlemerge · elsewhere with PREFIX=<dir>
gentlemerge install     # hooks for Claude Code (idempotent, backed up, reversible); add --codex to bridge Codex's notify too
```
`~/.local/bin` needs no sudo and is the default on both platforms; `make install`
says so if it is not on your `PATH`, or if an older copy earlier in `PATH` is
still the one that runs.

**The menu-bar app (macOS, optional)**
```sh
make run                # builds it, installs ~/Applications/GentleMerge.app (elsewhere with APP_DIR=<dir>) and opens it
```
macOS remembers a permission against the app's signature. The build looks for an
"Apple Development" certificate by itself (a free Apple ID gets you one), so what
you grant stays granted from one build to the next; without one it signs ad-hoc,
says so, and every rebuild asks again. `CODESIGN_IDENTITY=<name>` picks another.

**Set up a repo for several agents**
```sh
cd your-repo
gentlemerge project init --git-hooks            # HANDOFF.md + the commit gate in the hooks dir git actually uses (core.hooksPath wins; covers all worktrees)
git worktree add ../wt-claude -b agent/claude && (cd ../wt-claude && gentlemerge project init --label claude)
git worktree add ../wt-hermes -b agent/hermes && (cd ../wt-hermes && gentlemerge project init --label hermes)
```
`init` also keeps `.gentlemerge/HANDOFF.md` out of git, in `.gitignore`: it is rewritten after every commit, because it lists the last ones, and every worktree reads the main checkout's copy. If yours is already tracked, `gentlemerge doctor` gives you the line to untrack it.

Every worktree gets its own label: that is what `say --to <label>` routes by and
what the gate judges "mine" from. Labels are ASCII (letters, digits and `#` `-` `_` `.`, 24 chars)
— anything else is stripped, and the same stripping is applied when git hands the
label back, so `--label "🚀rocket"` and `--label rocket` are one agent rather
than two.

**Several agents in one checkout instead?** Then no worktree label can tell them
apart, and the gate would treat an agent's own claims as somebody else's — it
would refuse to let it commit the files its own edits just claimed. Give each
agent its label through its environment instead: `GENTLEMERGE_LABEL=claude` in
Claude Code's settings (`"env"`), `codex` in Codex's, and so on. The gate takes
that, or a worktree label, and never a guess.

Give each worktree its own dev-server ports (a hundred per label) with
`gentlemerge env --write` inside it, then `source .gentlemerge/env.sh` before starting a
server — `project init` does not write the file for you.
Declare zones in `.gentlemerge/HANDOFF.md`:
```markdown
## Ownership
- lib/store/** → claude
- lib/data/**  → hermes
- assets/**    → codex
```
Paste [`docs/AGENT_PROTOCOL.md`](docs/AGENT_PROTOCOL.md) (~200 tokens) into each agent's `CLAUDE.md` / `AGENTS.md` / system prompt.

**Connect an agent via MCP** (Hermes, Gemini CLI, OpenCode, Codex, Claude Code…)
```json
{ "mcpServers": { "gentlemerge": { "command": "gentlemerge", "args": ["mcp", "--label", "hermes"] } } }
```
Tools: `brief`, `status`, `claim`, `claim_check`, `release`, `say`, `delegate`, `request_show`, `request_update`, `task_add`, `task_done`, `precommit`, `presence`, `watch_add`, `watch_list`, `watch_rm`, `tool_help` (short blurbs in the catalogue, full docs on demand).

## Try it without any AI
```sh
gentlemerge demo        # three simulated agents, one temp repo, the whole protocol in a few seconds
```

## Status

| Component | macOS | Linux | Windows |
|---|---|---|---|
| CLI, MCP server, claims, pre-commit, requests, land, demo | ✅ **verified on CI** | ✅ **verified on CI** | WSL2 ✅ · native: help wanted |
| Claude Code hooks + socket delivery | ✅ *needs community verification* | ⚠️ *simulated events only* | WSL2 |
| Codex hooks | ✅ *needs verification* | ⚠️ *simulated events only* | WSL2 |
| Menu-bar app, review UI, notifications | ✅ | — | — |

**What "verified on CI" means, and what it does not.** Both platforms run the
same pipeline on every push: `swift build -c release`, the full test suite, the
build contract and the headless smoke test. macOS also assembles the app bundle,
so its smoke test covers the GUI ingestion checks; Linux has no app, and those
checks are skipped there — a skipped step is not a passing one. So:

- **macOS is verified**: 1078 tests and the smoke test (127 checks) pass on every commit.
- **Linux is verified headless**: 1071 tests (the rest need macOS and are
  compiled out) and the smoke test's 120 headless checks. That is the CLI, the
  MCP server, the gate and the bus driven by real processes — not a live agent
  session, which nobody has confirmed on Linux yet.

Until 2026-11-13 Linux was only shown to *build*: the test module did not
compile there, so no test had ever run. The first full runs found three things
a build could not — the suite wrote into the developer's real home, a stale
`app.pid` was reported as a running app, and every command the binary ran left
two file descriptors open (which a long-lived MCP server would eventually have
run out of) — all fixed in the commits that turned the tests on.

This is the same declaration the project has always made for live vendor
sessions: what has not been exercised is stated, not rounded up.

*Needs verification* = implemented against the vendor's documentation and tested with simulated events, not yet confirmed on a live paid session. If you have access, run `TESTING.md` §Live and open an issue with the result.

Native Windows blockers: `flock`, Unix domain sockets, POSIX permissions. PRs welcome.

## Safety

Only if you opt in, GentleMerge can deliver a fixed one-line notice to another agent's session, or start a headless agent to handle a delegated request. Dispatch is off until you switch it on (`gentlemerge config set allowDispatch true`, or the toggle in the app under HEADLESS WORK); only the app ever starts an agent, never a one-shot command, and a request is started at most once. Once on it has three modes (`config set dispatchMode off|delegated|strict`): delegated, the default, lets agents trigger within tiers and a daily minute-budget; strict only runs human-created requests; off starts nothing. Every decision is gated by pure and exhaustively tested decision functions, and every decision is logged. Secrets are scrubbed before anything reaches another agent, the ledger or the bus (broadly: any number of seven or more digits goes too, a PR number or a timestamp included — write those shorter, or as a link) — raw hook payloads rest briefly in the local spool (owner-only files, pruned within days). See [SECURITY.md](SECURITY.md).

Guarantees come in three rungs, depending on the client — declared, not implied:
- **Enforced** (git gate): `pre-commit`/`pre-merge-commit` block a plain commit and a true merge. Git does not run them on every way into a branch, and no hook can stop what it does not run for, so the rest is **counted**: `post-commit`, `post-merge` and `post-rewrite` compare what came in with the live claims and post an urgent note to everyone in the project. Whatever passed the gate finds nothing there, so this stays silent unless something got round. A missing gate binary warns on every commit instead of passing silently. This coordinates cooperative agents; it is not a sandbox.

  | How it gets in | What happens |
  |---|---|
  | `git commit`, `commit -a`, a partial commit, `merge --no-ff`, `cherry-pick --continue` | Blocked |
  | `git commit --no-verify`, `merge --no-ff --no-verify` | Goes through. Urgent note, and a line in `stats --value` |
  | `git cherry-pick`, `git revert` | Goes through. Urgent note |
  | `git merge --ff-only`, a `git pull` that fast-forwards | Goes through. Urgent note |
  | `git rebase`, `git pull --rebase` | Goes through. Urgent note when it finishes |
  | `GENTLEMERGE_SKIP=1`, the human way out | Goes through. Published on the bus |
  | `git am`, `commit-tree`/`update-ref`, editing or removing the hooks | Nobody hears about it |

  Hooks installed before this table need `gentlemerge git-hooks install --project <repo>` once; `gentlemerge doctor` says so.
  Ownership zones are enforced from `HANDOFF.md`, with one deliberate blind spot: a commit that *rewrites the zones themselves* is not judged by them (that is the agent being its own judge), and only the pinned store rules apply in that case. Recording a task in `HANDOFF.md` — which the agent protocol tells every agent to do — does **not** switch the zones off; only changing them does.
- **Advised** (hooks): PreToolUse warns before the edit lands. A client without hooks never hears it. (Installs made before 2026-10-26 never got this hook — `install` reported it and then dropped it; run `gentlemerge install` again and `gentlemerge status` should list `PreToolUse`.)
- **Convention** (MCP): `claim_check` answers honestly, but nothing stops the edit. MCP clients coordinate by discipline plus the enforced gate at commit time.

## Design notes

- One writer per hot file; per-session markers instead of locks. Where two processes must write (claims, requests), `flock`.
- Every reader is forgiving: unknown kinds/states from a newer binary are ignored, never crash.
- Nothing ever blocks an agent: hooks time out, writes are atomic, the pre-commit hook has a human escape hatch (`GENTLEMERGE_SKIP=1`).
- What can't be verified is declared, not hidden.

Architecture: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## License
MIT
