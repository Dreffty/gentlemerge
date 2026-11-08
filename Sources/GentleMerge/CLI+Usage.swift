import GentleMergeCore
import GentleMergePorts
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension CLI {
    static let usageText = """
        gentlemerge — coordination for AI coding agents that share one repository.

        USAGE
          gentlemerge                       this help
          gentlemerge app                   open the menu bar app (macOS;
                                              `make run` installs it)
          gentlemerge install [options]     install the hook bridge
          gentlemerge uninstall             remove our hooks (yours stay)
          gentlemerge status                what is installed and running
          gentlemerge config get|set k [v]  knobs without the app: allowDispatch,
                                              dispatchMode,
                                              dispatchDailyBudgetMinutes,
                                              claimsPolicy, retentionDays,
                                              autoLand
          gentlemerge doctor [--project dir]  one screen an agent can read: home,
                                              spool, presence, app, git hooks,
                                              git version, clock skew
          gentlemerge compact               deep clean: finished requests,
                                              lapsed watches, stale presence,
                                              old dispatch logs and messages
          gentlemerge list                  pending items, as text
          gentlemerge history [-n 20]       what happened, and when
          gentlemerge test-event            fire a synthetic event
          gentlemerge print-hook            print the hook script

        THE BUS — what the other agents are doing, and what they left you
          gentlemerge who [--all]           who is working on what, right now,
                                            and which sessions died in the last
                                            six hours without saying so
          gentlemerge who --project [dir]   only the agents in one project
          gentlemerge brief [dir]           the briefing a hook would inject,
                                            as plain text — for the tools that
                                            have no hooks (Hermes, a script, you).
                                            A read: nothing is consumed, and
                                            notes for other agents are shown
          gentlemerge brief --as hermes     ...as that agent: what is addressed
                                            to it arrives, and arrives once.
                                            Identifying yourself is consuming
          gentlemerge stats [--session id]  what the coordination costs: hook
                                            injections counted off the ledger.
                                            Tokens are chars/4, always an
                                            estimate. --value counts what it
                                            saved: blocked commits, announced
                                            conflicts, cleared claims
          gentlemerge show <handle>         one note in full, by the #abcd the
                                            briefing prints in front of it. So
                                            "look at 3f8a" is a thing you can both
                                            say, and neither of you has to go
                                            reading the raw log by hand
          gentlemerge say "..." [--to claude|codex|hermes] [--project dir]
                                            leave a note for the others, scoped
                                            to the project you are standing in
          gentlemerge say "..." --global    ...for every project, when it really
                                            is everybody's business
          gentlemerge say "..." --urgent    read first, and kept for 72h; --fyi
                                            is the opposite (4h), and the default
                                            update lasts a day. --kind handoff
                                            for the long form
          gentlemerge say "..." --attach f  leave a file with the note: the others
                                            get the path and the first lines, and
                                            open it themselves. Repeatable, 2 MB
                                            each; text is stored scrubbed.
          gentlemerge say "..." --nudge     ask the app to type one fixed line
                                            of notice into their terminal — only
                                            if they are idle, at most one every
                                            ten minutes, and only with nudges
                                            turned on (they are off by default).
                                            Your text is never typed anywhere
          gentlemerge say "..." --replaces <handle>
                                            correct a note instead of adding a
                                            second one next to it. The original is
                                            folded out of every later read, so the
                                            reader is never left guessing which of
                                            the two numbers was the true one.
                                            Anyone can correct anyone: being wrong
                                            is not a private matter on a shared bus
          gentlemerge say "..." --to-branch <name>
                                            for whoever is standing on that branch.
                                            `--to` routes by model, which answers
                                            "who are you"; a collision is about what
                                            you are standing on. Now that every
                                            worktree of a repo shares one bus, this
                                            is how you reach just one of them
          gentlemerge say --done            take back your notes in this project:
                                            the others stop being told about a
                                            blocker you already lifted

        AVÍSAME CUANDO — ask once instead of polling the briefing
          gentlemerge watch session-end <id|label> [--note "..."]
                                            tell me when that session is over,
                                            whether it says goodbye or dies
          gentlemerge watch idle <label>    ...when it finishes its turn and the
                                            next move is somebody else's
          gentlemerge watch task <n|text>   ...when that task gets ticked off,
                                            by whoever ticks it off
          gentlemerge watch list            what is still being watched
          gentlemerge watch rm <id>         call one off
                                            A watch fires once, as a note to you
                                            on the bus you already read, and
                                            lapses on its own after 48h. It is
                                            scoped to the project you are
                                            standing in unless you say --global,
                                            and it never makes anybody wait

        AGENTS WITHOUT HOOKS, AND SUBAGENTS
          Hermes is one-shot: it has no hooks and no session, and inventing them
          would mean inventing a daemon. The wrapper that launches it does the
          two things a hook would have done, either side of the run:

            BRIEF=$(gentlemerge brief --as hermes --project "$PWD")
            hermes -z "$BRIEF

            <what you want done>"
            gentlemerge say --from hermes "what it did"
            gentlemerge say --from hermes --done

          GENTLEMERGE_NAME=claude#exec1     what this process calls itself, for
                                            `say`, `task claim` and `brief --as`.
                                            A session launching executors gives
                                            each one a name; `--to claude` still
                                            reaches all of them, `--to
                                            claude#exec1` reaches exactly one

        AFTER THE AGENT (phase 2)
          gentlemerge review [dir] [--since <commit>] [--slow]
                                            what changed, what its checks say,
                                            and what no command can answer
          gentlemerge radar [--project dir] [--force]
                                            merge every agent/* branch pair in
                                            memory and warn both sides on the
                                            bus about the ones that would
                                            conflict — once per conflict, at
                                            most one sweep per project per 3 min
          gentlemerge land [--branch agent/x] [--into main] [--dry-run] [--skip-checks] [--fast]
                                            bring a branch home: rebase onto
                                            main, run the project's checks,
                                            fast-forward main, tell the bus.
                                            The worktree must be clean; a
                                            conflict prints the files and who
                                            touched them. --dry-run checks and
                                            shows the plan without touching
                                            anything. --fast lands only what
                                            fast-forwards: no rebase, no checks

        PROJECTS — shared state between sessions and models
          gentlemerge projects [--all]      every project, with open task counts.
                                            Scratch folders, and plain folders
                                            nobody has worked in for a week, only
                                            with --all
          gentlemerge handoff [dir]         print what the next session should know
          gentlemerge precommit [dir]       BEFORE EVERY COMMIT. Which of the files
                                            you have changed somebody already
                                            committed to since your session
                                            started, and whether your branch is
                                            behind its upstream. Never blocks and
                                            never fails — it only tells you what
                                            to read before you write over it
                                            --since <rev>  anchor somewhere else
                                            --as <label>   whose session to use
          gentlemerge ownership [--project dir]
                                            zones in force and where from;
                                            pin|add|rm edits the pinned set
          gentlemerge task list [--project dir]
          gentlemerge task add "what is left" [--by claude]
          gentlemerge task add "smoke test" --step "one" --step "two" --step "three"
                                            file the points before you start, so
                                            a session that dies mid-way still
                                            leaves the score behind
          gentlemerge task step done|undone "<task>" "<step>"
          gentlemerge task step add "<task>" "one more point"
                                            task and step take either the number
                                            from `task list` or part of the text
          gentlemerge task done|undone|rm <number>
          gentlemerge task claim|release <number|text> [--as label]
                                            say you are on it before you start.
                                            Somebody else already on it? You are
                                            told who and since when — never
                                            stopped. Lapses after 2h, or when the
                                            session that took it ends
          gentlemerge project init [dir]    create the handoff and point CLAUDE.md at it
          gentlemerge git-hooks install|uninstall [--project dir]
                                            the commit gate on its own (project init
                                            --git-hooks does this and more). Needs
                                            the verb: bare `git-hooks` prints this
          gentlemerge project adopt-worktrees [dir]
                                            one-shot, for a repository worked in
                                            through git worktrees before they were
                                            understood to be the same project: brings
                                            the tasks their handoffs collected into
                                            the repository's own, and folds them out
                                            of the project list. Deletes nothing, and
                                            adopts nothing twice
          gentlemerge env [--write]         this worktree's ports: one range of a
                                            hundred per label, so two agents'
                                            dev servers never collide. --write
                                            saves .gentlemerge/env.sh to source
                                            before running them

        GUARDRAILS (phase 3)
          gentlemerge snapshot [list|create <label>|restore <id>] [--project dir]

        SIMULATION (zero tokens)
          gentlemerge sim --script file.json --worktree dir
          gentlemerge demo [--keep] [--home-real]
                                            isolated temporary home by default;
                                            --keep preserves the demo files;
                                            --home-real opts into your real inbox

        INSTALL OPTIONS
          --minimal             only Notification and Stop hooks
          --codex               also bridge Codex's notify program
          --dry-run             show what would change, write nothing

        OPTIONS IN GENERAL
          An option a command does not know stops it: exit 2, nothing done. After
          a bare `--` everything is text, even what starts with a dash:
          gentlemerge say -- "--no-verify hides this"
        """
}
