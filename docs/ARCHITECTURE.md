# Architecture

GentleMerge is a vendor-neutral coordination layer for AI coding agents that
share one repository: a local bus (hooks or MCP in, briefings out), a git
pre-commit gate that costs no tokens, and a filesystem protocol any language
can speak. 100% local — Swift 6, Swift Package Manager, no dependencies.

One binary, two modes: `gentlemerge <command>` is the CLI, bare
`gentlemerge` is the macOS menu-bar app. All logic lives in `GentleMergeCore`,
which imports no UI frameworks, so the same code runs the app, the Linux CLI,
and the test suite.

## Repository map

```
Sources/
  GentleMerge/            # thin layer: CLI + macOS UI, all logic in Core
    main.swift           # argv>1 → CLI, else the SwiftUI app
    CLI.swift            # every subcommand (say, brief, task, claim, delegate,
                         #   request, watch, precommit, land, radar, review,
                         #   stats, env, snapshot, sim, demo, mcp, install…)
    MainWindow.swift     # sessions, messages, requests, tasks, commits
    MenuBarSummary.swift # popover counts
    Notifier.swift       # UserNotifications for questions/failures
    ReviewView.swift     # WHAT CHANGED / CHECKS / NEEDS YOUR EYES
    SnapshotsView.swift  # restore points
  GentleMergeCore/
    Actions/
      NudgeGate.swift    # pure decision: is it safe to push a one-line notice?
      TerminalBridge.swift # macOS tty delivery via AppleScript; Linux refuses
      SocketBridge.swift # per-session Unix-socket delivery (wire format
                         # unverified — falls back, never invents)
      DispatchGate.swift # pure decision: may a request start a headless agent?
      Dispatcher.swift   # spawns headless agents, logs to dispatch/<id>.log
    Bus/
      AgentBus.swift     # heart: activities, messages, briefing, delivery
      Artifacts.swift    # content-addressed file drops (say --attach)
      Liveness.swift     # isProcessAlive via kill(pid, 0)
      Presence.swift     # "I am working here", no app required
      Redactor.swift     # strips secrets before anything is shared or stored
      Requests.swift     # delegate contracts: state machine + may-touch
      RequestActions.swift # accept/done/fail/reject/ack transitions
      Watches.swift      # "tell me when X finishes"
      MCPServer.swift    # JSON-RPC over stdio for Hermes/Gemini/OpenCode/…
      BriefingCursor.swift # per-session delivery markers
      BriefingRenderer.swift # pure: what a briefing says
      Identity.swift     # verified labels (worktree config, hook env)
    Ingest/
      EventTranslator.swift # hook events → items, sessions, resolutions
      InboxModel.swift   # app view-model: drain, sweep, nudge, dispatch
      ToolInputFormatter.swift # tool calls → one-line titles
    Install/
      HookInstaller.swift # Claude/Codex hooks: idempotent, backed up, reversible
      HookScript.swift   # embedded gentlemerge-hook.sh source
      GitHookInstaller.swift # pre-commit gate in the repo common dir
    Model/
      InboxItem.swift / JSONValue.swift / SpoolEnvelope.swift / PathScope.swift
    Projects/
      ProjectRegistry.swift # projects.json + handoff I/O + git log
      ProjectHandoff.swift # HANDOFF.md read/write
      ProjectMap.swift    # generated repo map sealed by HEAD
      RepoIdentity.swift  # every worktree of a repo is one project
      TaskClaims.swift    # who is on which task (hours, about what)
      PathClaims.swift    # who edits which paths (minutes, about where)
      PrecommitGate.swift # pure: staged files vs claims/ownership/requests
      Ownership.swift     # HANDOFF.md zones
      CommitOverlap.swift # who already committed to your files (precommit)
      ConflictRadar.swift # each branch vs main, then overlapping pairs via merge-tree, warns affected sides
      Landing.swift       # rebase + checks + fast-forward + broadcast
      UnfinishedWork.swift / WorktreeAdoption.swift / WorktreeLabel.swift
    GentleMergePorts/
      WorktreeEnv.swift   # one 100-port range per label; plumbing, not Core
    Sim/
      Demo.swift / SimAgent.swift # three simulated agents, zero tokens
    Snapshot/
      GitSnapshot.swift  # restore points via private git refs
    Store/
      AppConfig.swift / JSONCoding.swift (AtomicFile, LockedFile) /
      Ledger.swift / Paths.swift / SpoolStore.swift / Stats.swift
    Support/
      CommandArguments.swift / Glob.swift / PortableSHA256.swift / Shell.swift
    Verify/
      Review.swift / ProjectChecks.swift / SessionRegistry.swift /
      InboxModel+Review.swift
Tests/GentleMergeCoreTests/  # ~40 files, roughly one per module
Scripts/  # bundle.sh (app packaging), smoke-test.sh (headless end-to-end),
          # test-build-contract.py (CI plumbing)
docs/  # AGENT_PROTOCOL.md (the ~200-token agent contract),
       # FILE_FORMATS.md (the filesystem protocol), ARCHITECTURE.md (this file)
```

## How it flows

1. **Report.** A hook (Claude Code, Codex) or the MCP server records an
   event: a spool envelope, a presence mark, a path claim, a message.
2. **Record.** The app drains the spool every few seconds (or `brief --as`
   reads directly for hook-less agents). Everything lands as JSON under
   `~/.gentlemerge` and tasks in `<repo>/.gentlemerge/HANDOFF.md`.
3. **Enforce.** The pre-commit hook rejects commits that invade another
   agent's live claim, ownership zone, or pending request contract.
4. **Brief.** Each turn injects only what changed since the last one —
   silent when there is nothing new. Every injection is counted in the
   ledger as `briefing.injected`, which is what `stats` adds up.

## Decisions that keep it robust

- **One writer per hot file**; per-session markers instead of locks. Where two
  processes must write (path claims, requests, watches, radar state), `flock`
  through a sidecar lock.
- **Every reader is forgiving**: unknown kinds, states and keys decode to safe
  defaults, never crash. Old and new binaries share the same home.
- **Nothing ever blocks an agent**: hooks time out, writes are atomic
  (temp file + rename, `O_APPEND` under lock), the pre-commit hook has a
  human escape hatch (`GENTLEMERGE_SKIP=1`).
- **Dangerous actions are pure decisions first**: `NudgeGate.decide`,
  `DispatchGate.decide`, `PrecommitGate.evaluate` are side-effect-free and
  matrix-tested; the app only executes what they allow, and ledgers why.
- **What can't be verified is declared, not hidden**: `Review` never says
  "all good", socket delivery is marked needs-verification until a live
  session confirms it, and every such gap has a named test or a docs note.
- **Secrets never reach disk or another agent**: `Redactor.scrub` runs on
  write and on delivery; text that is mostly secrets is refused outright.

## Known limits

- Native Windows is out of scope (`flock`, Unix sockets, POSIX permissions);
  WSL2 works.
- Socket delivery is implemented but unverified against a live paid session,
  so it always falls back today — by design, until the wire format is
  confirmed from the vendor's docs.
- The radar sees commits, not edits: each branch against main first (O(n)),
  then pairs only when their changed file sets overlap. Claims cover edits
  still in flight; work that is uncommitted on another machine is visible to
  nobody. Sources are local `agent/*` branches plus the branches live
  sessions stand on, whatever they are called; remotes are invisible.
  Abandoned branches (90 days untouched) sit out the pair phase.
