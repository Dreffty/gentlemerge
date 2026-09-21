# File formats

The protocol is the filesystem. Any language can be a client by reading and writing these files.

Everything below lives in one home directory: `~/.gentlemerge` on macOS,
`$XDG_STATE_HOME/gentlemerge` on Linux when set, or wherever `GENTLEMERGE_HOME`
points. Dates are ISO-8601 strings. JSON objects tolerate missing keys and
ignore unknown ones — a reader from an older binary never crashes on a file a
newer one wrote; it just sees less.

## Home files

| Path | Who writes | Shape |
|---|---|---|
| `spool/*.json` | Hook scripts (`gentlemerge-hook.sh`, Codex notify) | One `SpoolEnvelope` per file: `schema` (int, 1), `id`, `provider` (`claude-code`\|`codex`\|`unknown`), `received_at`, `cwd`, `tty`, `pid` (int or numeric string), `term_program`, `term_session_id`, `socket`, `payload` (object, the agent's raw event). Empty strings read as absent. Files are renamed into place, never written in place. |
| `processed/` | App | Envelopes already ingested, kept briefly for crash debugging, then pruned. Same shape as `spool/`. |
| `answers/` | — | Reserved. Created on setup; nothing writes here yet. |
| `bin/` | Installer (`gentlemerge install`) | `gentlemerge-hook.sh`, `gentlemerge-codex-notify.sh`, and a symlink back to the binary. Referenced, never executed, from agent configs. |
| `backups/` | Installer | `settings.json.<stamp>.bak` and friends, taken before touching someone else's config. |
| `ledger.jsonl` | App and CLI, append-only | One `LedgerEntry` per line: `id`, `at`, `kind` (`received`\|`handled`\|`expired`\|`resolved`\|`note`), `itemID`, `sessionID`, `provider`, `project`, `title`, `summary`, `reason`, `waitedSeconds`, plus `mode`/`chars` on `briefing.injected` lines only. Every line carries `v` (schema version, 1 today); lines without it decode as 1. Greppable history; never rewritten. |
| `ledger.archive.jsonl` | App prune | Ledger lines older than 90 days, moved here by `Ledger.archive`. Same shape; `Stats` reads both, so totals survive the move. |
| `state.json` | App | Array of `InboxItem` (the human inbox: questions, failures, idle notices). Rewritten on every change via temp file + rename. |
| `config.json` | You, by hand | `AppConfig`. Every key optional with a safe default: `notifyOnQuestion` (true), `notifyOnIdle` (false), `playSound` (true), `shareTaskText` (true), `historyLimit` (40), `reviewOnSessionEnd` (false), `allowNudges` (false), `claimsPolicy` (`warn`), `allowDispatch` (false), `dispatchAutoApproveMinutes` (15), `dispatchAutoApproveTiers` (`["cheap"]`), `dispatchQuietPeriod` (300), `agents` (array of `AgentTarget`: `label`, `capabilities`, `command`, `worktree`, `costTier`, `portBase`), `autoLand` (false), `basePort` (3000). |
| `policy.json` | — | Reserved. Nothing reads or writes it yet. |
| `sessions.json` | App | Array of `SessionRecord`: `id`, `provider`, `projectPath`, `startedAt`, `lastSeenAt`, `baselineCommit` (the revision the session opened on, for `precommit`), `endedAt`, `pid`, `tty`, `terminalProgram`. |
| `projects.json` | App and CLI | Array of `ProjectSummary`: `path` (canonical repository root — every worktree of a repo shares one), `name`, `lastSeenAt`, `lastProvider`. Capped at 60, newest first. |
| `activities.json` | App only | Array of `AgentActivity`: `id` (session), `provider`, `projectPath`, `startedAt`, `updatedAt`, `currentTask`, `lastEvent`, `state` (`working`\|`waiting`\|`idle`\|`ended`), `pid`, `tty`, `terminalProgram`, `socketPath`. |
| `messages.jsonl` | Any process, via `bus.post`, append-only | One `AgentMessage` per line: `id`, `at`, `from`, `to` (absent = everyone), `projectPath` (absent = every project), `text` (scrubbed on write), `kind` (`fyi`\|`update`\|`urgent`\|`handoff`\|`request`\|`request-result`\|`resolve`; unknown reads as `update`), `refID` (on `resolve` tombstones), `nudge`, `attachments`, `replacesID`, `toBranch`, `verified`, `requestID`. Expiry and tombstone-folding are properties of the read, never rewrites. |
| `claims.json` | CLI and app, under a sidecar lock | Array of `TaskClaim`: `projectPath`, `taskID`, `claimedBy`, `sessionID`, `claimedAt`. Hours-long, about *what*. |
| `claims-paths.json` | Hooks, CLI and app, under a sidecar lock | Array of `PathClaim`: `id`, `label`, `projectPath`, `pattern` (glob), `intent`, `since`, `expires`, `implicit`, `requestID`. Minutes-long, about *where*. Expired claims are pruned on every write. |
| `watches.jsonl` | CLI appends, app compacts | One `WatchRule` per line: `id`, `createdAt`, `owner`, `projectPath`, `kind` (`session-end`\|`session-idle`\|`task-done`), `target`, `note`, `firedAt` (set = spent). Cancelling appends a tombstone line; only the app rewrites the file. |
| `artifacts/<sha256>/` | CLI (`say --attach`) | Content-addressed file drops: the bytes plus a small manifest (`name`, `storedPath`, `bytes`, `sha256`, `summary` for text). One directory per distinct content. |
| `delivered/` | Hooks and CLI | One JSON marker per session (`<session>.json`) or pseudo-session (`reader-<label>.json`): `lastMessageAt`, `deliveredIDs` (capped). Only ever written by the session (or reader) it belongs to. |
| `presence/` | Agents (CLI `presence`, and every working-agent command) | One JSON mark per label (`<label>.json`): `label`, `projectPath`, `branch`, `updatedAt`, `pid`, `task`, `capabilities`. Believed for 30 minutes. Only the agent it names writes it. |
| `requests/<id>.json` | CLI and app, under per-file locks | One `AgentRequest` per file: `id` (`req-…`), `from`, `fromVerified`, `to`, `resolvedTo`, `projectPath`, `title`, `spec`, `inputs`, `expectedOutput`, `mayTouch`, `budgetMinutes`, `createdAt`, `updatedAt`, `state` (`queued`\|`assigned`\|`in_progress`\|`done`\|`failed`\|`rejected`\|`acked`), `result`, `taskID`, `watchID`. |
| `dispatch/` | Dispatcher (app) | `<id>.prompt.md` (what the headless agent was asked) and `<id>.log` (everything it printed). |
| `dispatch-approvals.json` | App and CLI, under a sidecar lock | Array of approved request ids. |
| `reviews/` | App | One `Review` per finished session review (`<uuid>.json`): `projectPath`, `work` (diff stats), `checks` (name, command, status, tail of output), `openQuestions`. Newest kept. |
| `radar.json` | App drain and `gentlemerge radar`, under a sidecar lock | `lastRun` (project → date, the 3-minute throttle), `announced` (conflict signature → date, 30-day memory), `lastAutoNote` (project+branch → date, the failed-landing note throttle). |
| `gentlemerge.log` | App | `ERROR`/`INFO` lines. Diagnostics, never content. |
| `app.pid` | App | The menu-bar process id while it runs; absent means hooks answer for themselves. |

## The repository: `.gentlemerge/HANDOFF.md`

One per repository (all worktrees share it), Markdown, committed. Sections:

- `## Project map` — generated from the files on disk, sealed with the commit
  it was generated at. Regenerated, never hand-edited.
- `## Recent commits` — regenerated from git log with the files each commit
  touched. What `precommit` compares against.
- `## Ownership` — hand-written zones, one per line: `- lib/store/** → claude`.
  A glob, an arrow, a label. First match wins.
- `## Tasks` — the shared list: `- [ ] text` open, `- [x] text` done. Anything
  written as `- [ ] …` anywhere in the file is tidied into this list.
- `## ...` — any other section is yours. Unknown sections are preserved
  byte for byte; only the sections above are ever rewritten.

`<repo>/.gentlemerge/env.sh` (generated by `gentlemerge env --write`, never
committed) holds one worktree's `GENTLEMERGE_LABEL`, `PORT` range and
`DATABASE_URL_SUFFIX`.

## Forgiving-decode rules

1. Missing keys decode to documented defaults (or absent for optionals).
2. Unknown enum cases read as the safe default: unknown message kinds as
   `update`, unknown providers as `unknown`.
3. Unknown JSON keys are ignored.
4. A corrupt line in a `.jsonl` file costs that line, never the file.
5. Empty strings read as absent for envelope and activity string fields.
6. `pid` accepts a number or a numeric string (shells stringify everything).
