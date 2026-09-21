# Contributing

GentleMerge is infrastructure that agents trust with their work. Changes are
held to three rules:
1. **Every security invariant ships with a test.** Nudge gating, dispatch
   authorization, secret scrubbing, claim enforcement — if it protects
   something, a test pins the behavior, including the refusal paths.
2. **Core imports no UI frameworks.** `GentleMergeCore` stays free of AppKit,
   SwiftUI, Combine and UserNotifications, so the same code runs the macOS
   menu-bar app, the Linux CLI, and the test suite. UI lives in `GentleMerge`.
3. **CI stays green on macOS and Linux.** `swift test` and `sh Scripts/smoke-test.sh`
   pass on both before a commit. Unix-only assumptions (`flock`, domain
   sockets, POSIX permissions) stay behind `#if` or in documented fallbacks.

Smaller norms: one writer per hot file; every reader forgiving (unknown
kinds and states decode, never crash); nothing ever blocks an agent — hooks
time out, writes are atomic, decisions go to the ledger.

Before changing direction, check the guarantee ladder in `README.md`:
enforced (tests refuse), advised (warnings), convention (docs only).
