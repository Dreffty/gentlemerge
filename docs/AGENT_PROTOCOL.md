# GentleMerge protocol (multi-agent repo)

You share this repo with other AI agents. Each agent works in its own git
worktree and branch.

- At session start, before entering a module you haven't touched this session,
  and after every commit: run `gentlemerge brief` (or the `brief`/`status` MCP
  tool). Otherwise do not look at other agents' work.
- Before editing files: `gentlemerge claim --paths <globs> --intent "<one line>"`.
  If it fails, someone else is there — message them
  (`gentlemerge say --to <label> "..."`) or work elsewhere. Release when done.
- Respect `## Ownership` in `.gentlemerge/HANDOFF.md`. Claim explicitly if you
  must cross a zone.
- Commits are checked by a pre-commit hook. If it blocks you, read the one-line
  reason and coordinate; never bypass it.
- If a task is better done by another agent (e.g. image generation, bulk
  refactor), use `gentlemerge delegate --to capability:<name> ...` and
  **continue your own work**. The result arrives in a later briefing.
- If a request arrives for you, `gentlemerge request accept <id>`, stay inside
  its `may touch` paths, and finish with `request done <id> --result "<paths +
  sha>"` or `request fail`.
- Never paste secrets into messages or tasks.
