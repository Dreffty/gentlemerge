# GentleMerge

**Vendor-neutral coordination layer for AI coding agents that share one repository.**

Claude Code, Codex, Hermes, Gemini CLI, OpenCode — anything that speaks MCP or git — working on the same project at the same time, without stepping on each other, without spending tokens watching each other.

100% local. No cloud, no accounts. Your code and your agents' messages never leave your machine.

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
    ## Messages for you
    - [claude → hermes] need a nullable `sku` on Product, can you add it?

coordination cost: 3 briefings (3 non-empty) · ≈ 693 tokens total · ≈ 231 tokens/turn (estimate: chars/4)
```

## Why

Every vendor now ships a multi-agent story — for *their own* agents. Claude Code sessions message Claude Code sessions. Codex threads coordinate with Codex threads. Nothing coordinates a Claude, a Codex and an open-weights model on the same repo.

And every existing approach relies on the model *remembering* to check what others are doing — which either fails or burns half your budget on vigilance.

GentleMerge takes the opposite stance: **coordination is infrastructure, not intelligence.**

| Problem | How GentleMerge solves it | Tokens |
|---|---|---|
| Two agents edit the same file | **Path claims**, created automatically when an agent edits; a **git pre-commit hook** rejects commits that invade another agent's live claim or ownership zone | 0 |
| Agent doesn't know what others are doing | **Delta briefings** injected only when something changed, hard-capped at ~300 tokens; empty when nothing's new | ~20–70/turn |
| "This task is better done by another agent" | **Requests**: a contract with `may_touch` paths, time budget, state machine and automatic callback. Delegate and keep working | ~50 once |
| Branches will conflict at merge | **Conflict radar** (`git merge-tree`) warns both agents early; `gentlemerge land` rebases, runs checks, fast-forwards | 0 |
| Dev servers collide on ports | Per-worktree `env.sh` with a unique port range | 0 |
| "Did the agent actually do it right?" | **Review** lists what changed, what checks ran, and what *nobody verified* — never says "all good" | 0 |

## How it works

Each agent works in its own **git worktree** with a label (`claude`, `codex`, `hermes`…). GentleMerge is one small binary that:

1. **Listens** — via hooks (Claude Code, Codex) or its **MCP server** (everything else).
2. **Records** — who is editing what, messages, requests, presence — as plain JSON/Markdown under `~/.gentlemerge` and `<repo>/.gentlemerge/HANDOFF.md`. *The protocol is the filesystem* ([docs/FILE_FORMATS.md](docs/FILE_FORMATS.md)): any language can read or write it.
3. **Enforces** — a `pre-commit` hook that costs no tokens and can't be forgotten.
4. **Briefs** — injects only what changed into each agent's next turn.

The optional macOS menu-bar app shows the board, approvals and reviews. Everything works without it.

## Install

**macOS / Linux / WSL2**
```sh
git clone https://github.com/Dreffty/gentlemerge && cd gentlemerge
make install            # → ~/.local/bin/gentlemerge (Linux) · /usr/local/bin (macOS)
gentlemerge install     # hooks for Claude Code / Codex if present (idempotent, backed up, reversible)
```

**Set up a repo for several agents**
```sh
cd your-repo
gentlemerge init --git-hooks            # HANDOFF.md + pre-commit & pre-merge-commit in the hooks dir git actually uses (core.hooksPath wins; covers all worktrees)
git worktree add ../wt-claude -b agent/claude && (cd ../wt-claude && gentlemerge init --label claude)
git worktree add ../wt-hermes -b agent/hermes && (cd ../wt-hermes && gentlemerge init --label hermes)
```
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
gentlemerge demo        # three simulated agents, one temp repo, the whole protocol in ~20 seconds
```

## Status

| Component | macOS | Linux | Windows |
|---|---|---|---|
| CLI, MCP server, claims, pre-commit, requests, land, demo | ✅ | ✅ | WSL2 ✅ · native: help wanted |
| Claude Code hooks + socket delivery | ✅ *needs community verification* | ✅ *needs verification* | WSL2 |
| Codex hooks | ✅ *needs verification* | ✅ *needs verification* | WSL2 |
| Menu-bar app, review UI, notifications | ✅ | — | — |

*Needs verification* = implemented against the vendor's documentation and tested with simulated events, not yet confirmed on a live paid session. If you have access, run `TESTING.md` §Live and open an issue with the result.

Native Windows blockers: `flock`, Unix domain sockets, POSIX permissions. PRs welcome.

## Safety

Only if you opt in, GentleMerge can deliver a fixed one-line notice to another agent's session, or start a headless agent to handle a delegated request. Dispatch has three modes (`config set dispatchMode off|delegated|strict`, also in the app under HEADLESS WORK): off by default, delegated lets agents trigger within tiers and a daily minute-budget, strict only runs human-created requests. Every decision is gated by pure and exhaustively tested decision functions, and every decision is logged. Secrets are scrubbed before anything reaches disk or another agent. See [SECURITY.md](SECURITY.md).

Guarantees come in three rungs, depending on the client — declared, not implied:
- **Enforced** (git gate): `pre-commit`/`pre-merge-commit` block. No client option can skip it except the human escape hatch, and every skip is published to the bus.
- **Advised** (hooks): PreToolUse warns before the edit lands. A client without hooks never hears it.
- **Convention** (MCP): `claim_check` answers honestly, but nothing stops the edit. MCP clients coordinate by discipline plus the enforced gate at commit time.

## Design notes

- One writer per hot file; per-session markers instead of locks. Where two processes must write (claims, requests), `flock`.
- Every reader is forgiving: unknown kinds/states from a newer binary are ignored, never crash.
- Nothing ever blocks an agent: hooks time out, writes are atomic, the pre-commit hook has a human escape hatch (`GENTLEMERGE_SKIP=1`).
- What can't be verified is declared, not hidden.

Architecture: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## License
MIT
