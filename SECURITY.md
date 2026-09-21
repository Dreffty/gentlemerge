# Security

## Threat model

GentleMerge sits between several AI agents that have tool access on your machine. Risks it takes seriously:

1. **Prompt injection through the bus.** Anything an agent writes (`say`, `delegate`, task text) lands in another agent's prompt, so the bus is treated as untrusted input. Labels are sanitised to `[A-Za-z0-9#-_.]{1,24}`; bodies are scrubbed for secrets twice (on write and on delivery); peer text enters briefings quoted as data — no `#`-starting line survives to spoof a section, 500 chars per line — and is escaped on the way into `HANDOFF.md`, so a smuggled `## Ownership` renders as literal text and can never parse as a zone grant. Request specs are shown as data, and the receiving agent's own permission system still applies to whatever it does.
2. **Notices to a foreign session (nudge).** Off by default (`allowNudges: false`). When on, the text is a fixed sentence plus a sanitised label — never message content. Over the tty it only fires when the target is idle at its prompt (never while a permission dialog is open), the process is verifiably alive, and at most once per 10 minutes. On Claude Code ≥ 2.1.224 delivery uses the session's own Unix socket instead of the tty.
3. **Starting processes (dispatch).** Off by default (`allowDispatch: false`). Only requests whose sender identity is verified (worktree config or hook environment — never free-text `--from`) can trigger a dispatch. Expensive requests require human approval. Every start/stop is logged with argv[0] and exit code; child output goes to `~/.gentlemerge/dispatch/<id>.log`.
4. **Impersonation.** A worktree labelled `claude` cannot speak as `hermes`. A human at a terminal can speak as anyone, but the message is marked unverified and can never trigger dispatch.
5. **Secrets on disk.** `Redactor` strips private keys, JWTs, API keys, credentials-in-URLs, assigned secrets, emails, card numbers, IBANs and long digit runs before anything is persisted. Text that is mostly secrets is refused entirely.
6. **The pre-commit hook.** Exits non-zero with a one-line reason; never modifies your tree. Humans bypass with `GENTLEMERGE_SKIP=1`.

## What GentleMerge does not do
- No network. No telemetry. No accounts.
- It does not read other agents' conversation history or files — only the events they emit and the messages they choose to send.

## Reporting
Open a private security advisory on GitHub. Include the relevant lines of `~/.gentlemerge/ledger.jsonl`; they contain no message content.
