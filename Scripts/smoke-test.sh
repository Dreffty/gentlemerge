#!/bin/sh
# End-to-end test for the shell side of the bridge — the half Swift tests
# cannot reach: real processes, real ttys, real hooks talking to each other.
#
# Runs entirely inside a temporary GENTLEMERGE_HOME; touches nothing of yours.

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# `pwd -P` on purpose: the default TMPDIR lives under /var, which is a symlink
# to /private/var. The app stores a project path as the hook reported it while
# the CLI resolves it through git, so the two spellings scope to different
# projects and the peers vanish. That asymmetry is a real bug (filed on the
# task list); testing the bus through it only ever proves the symlink exists.
SANDBOX=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/gentlemerge-smoke.XXXXXX")" && pwd -P)
export GENTLEMERGE_HOME="$SANDBOX/home"
export GENTLEMERGE_CLAUDE_SETTINGS="$SANDBOX/settings.json"
export GENTLEMERGE_CODEX_CONFIG="$SANDBOX/config.toml"

BIN="${BIN:-${GENTLEMERGE_BIN:-$ROOT/.build/debug/gentlemerge}}"
[ -x "$BIN" ] || { echo "build first: swift build" >&2; exit 1; }

HOOK="$GENTLEMERGE_HOME/bin/gentlemerge-hook.sh"
SPOOL="$GENTLEMERGE_HOME/spool"
PASS=0
FAIL=0

cleanup() {
    # Only ever the instance this script started — never the one you are using.
    [ -n "${TEST_APP_PID:-}" ] && kill "$TEST_APP_PID" 2>/dev/null
    rm -rf "$SANDBOX"
}
trap cleanup EXIT

ok()   { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (want '$3', got '$2')"; fi; }

spool_count() { ls "$SPOOL" 2>/dev/null | grep -c '\.json$' || true; }
json() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print($2)" "$1" 2>/dev/null; }

echo "sandbox: $SANDBOX"
"$BIN" install >/dev/null

echo "installer"
check "hook script is executable" "$([ -x "$HOOK" ] && echo yes || echo no)" "yes"
check "settings.json is valid JSON" \
    "$(python3 -c 'import json,sys; json.load(open(sys.argv[1])); print("yes")' "$GENTLEMERGE_CLAUDE_SETTINGS" 2>/dev/null)" "yes"
check "nothing of ours gates a tool call" \
    "$(grep -c 'PreToolUse' "$GENTLEMERGE_CLAUDE_SETTINGS")" "0"
check "the binary is reachable from the hook" \
    "$([ -x "$GENTLEMERGE_HOME/bin/gentlemerge" ] && echo yes || echo no)" "yes"

echo "reporting"
printf '{"session_id":"s1","hook_event_name":"Stop","cwd":"/tmp/demo"}' |
    sh "$HOOK" --provider claude-code --mode notify >/dev/null
check "one envelope queued" "$(spool_count)" "1"
ENVELOPE=$(ls "$SPOOL"/*.json 2>/dev/null | head -1 || true)
check "envelope is valid JSON" "$(json "$ENVELOPE" '"yes"')" "yes"
check "payload survives verbatim" "$(json "$ENVELOPE" 'd["payload"]["hook_event_name"]')" "Stop"
rm -f "$SPOOL"/*.json

printf 'this is not json at all' | sh "$HOOK" --provider claude-code --mode notify >/dev/null
ENVELOPE=$(ls "$SPOOL"/*.json 2>/dev/null | head -1 || true)
check "garbage in, envelope still parseable" "$(json "$ENVELOPE" 'd["payload"]')" "{}"
rm -f "$SPOOL"/*.json

CLAUDE_CODE_MESSAGING_SOCKET=/tmp/fake-inbox.sock sh "$HOOK" --provider claude-code --mode notify >/dev/null <<'PAYLOAD'
{"session_id":"s-socket","hook_event_name":"Stop"}
PAYLOAD
ENVELOPE=$(ls "$SPOOL"/*.json 2>/dev/null | head -1 || true)
check "the session socket travels in the envelope" "$(json "$ENVELOPE" 'd["socket"]')" "/tmp/fake-inbox.sock"
rm -f "$SPOOL"/*.json

echo "terminal identity"
# `script` gives the hook a real controlling terminal, like a live agent has.
# util-linux and BSD script take their command in different positions.
TTY_COMMAND="printf '{\"session_id\":\"s4\",\"hook_event_name\":\"Stop\"}' | TERM_PROGRAM=iTerm.app sh '$HOOK' --provider claude-code --mode notify"
if [ "$(uname -s)" = Darwin ]; then
    script -q /dev/null sh -c "$TTY_COMMAND" </dev/null >/dev/null 2>&1 || true
else
    script -q -c "$TTY_COMMAND" /dev/null </dev/null >/dev/null 2>&1 || true
fi
ENVELOPE=$(ls "$SPOOL"/*.json 2>/dev/null | head -1 || true)
CAPTURED_TTY=$(json "$ENVELOPE" 'd["tty"]' || true)
if [ -z "$CAPTURED_TTY" ] && [ ! -t 1 ]; then
    # `script` cannot hand out a pty when this suite's own output is a pipe.
    printf '  skip  terminal identity (run this suite from a terminal to cover it)\n'
else
    check "captures the tty to jump back to" "$(printf '%s' "$CAPTURED_TTY" | grep -Ec '^/dev/(tty|pts/)')" "1"
    check "captures the terminal app" "$(json "$ENVELOPE" 'd["term_program"]')" "iTerm.app"
fi
rm -f "$SPOOL"/*.json

echo "project handoff"
REPO="$SANDBOX/repo"
mkdir -p "$REPO/Sources"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name Test
printf 'let version = 1\n' > "$REPO/Sources/App.swift"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "first"

HANDOFF="$REPO/.gentlemerge/HANDOFF.md"
printf '# demo-project\n\nProject notes.\n' > "$REPO/CLAUDE.md"
"$BIN" project init --project "$REPO" > /dev/null
check "handoff file created" "$([ -f "$HANDOFF" ] && echo yes || echo no)" "yes"
check "CLAUDE.md points at it" "$(grep -c 'gentlemerge:handoff' "$REPO/CLAUDE.md")" "1"
check "their CLAUDE.md content is still first" "$(head -1 "$REPO/CLAUDE.md")" "# demo-project"

"$BIN" task add "Barrer recompensas rotas" --project "$REPO" --by claude > /dev/null
check "task is in the file" "$(grep -c 'Barrer recompensas rotas' "$HANDOFF")" "1"
check "the last commit is in the file" "$(grep -c 'first' "$HANDOFF")" "1"

# An agent edits the file by hand, the way an agent actually would.
cat >> "$HANDOFF" <<'MD'

## Decisiones

No migramos a SwiftData.
- [ ] Traducir constants a EN
MD
"$BIN" task add "Otra cosa" --project "$REPO" --by you > /dev/null
check "a task written in the wrong section is kept" "$(grep -c 'Traducir constants a EN' "$HANDOFF")" "1"
check "an unknown section is kept" "$(grep -c 'No migramos a SwiftData' "$HANDOFF")" "1"
check "and ours is there too" "$(grep -c 'Otra cosa' "$HANDOFF")" "1"

"$BIN" task done 0 --project "$REPO" > /dev/null
check "ticking a task off persists" "$(grep -c '\- \[x\] Barrer recompensas rotas' "$HANDOFF")" "1"

checksum() { python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$1"; }

echo "two agents reaching for the same task"
BEFORE_CLAIM=$(checksum "$HANDOFF")
"$BIN" task claim "Traducir constants" --project "$REPO" --as claude > /dev/null
check "the handoff file is byte-identical after a claim" "$(checksum "$HANDOFF")" "$BEFORE_CLAIM"
check "an older binary sees no new metadata on the task line" \
    "$(grep -c '^\- \[ \] Traducir constants a EN$' "$HANDOFF")" "1"
check "the list says who is on it" \
    "$("$BIN" task list --project "$REPO" | grep -c 'claimed by claude')" "1"
if "$BIN" task claim "Traducir constants" --project "$REPO" --as codex > "$SANDBOX/claim.out" 2>&1; then
    fail "a task somebody else is already on should not report success"
else
    ok "the second agent is told, not served"
fi
check "and told who has it, and for how long" "$(grep -c 'claimed by claude' "$SANDBOX/claim.out")" "1"
check "the claim went on the bus, scoped to the project" \
    "$("$BIN" say --done --project "$REPO" --from claude | grep -c 'claimed: Traducir constants a EN')" "1"
"$BIN" task release "Traducir constants" --project "$REPO" --as claude > /dev/null
check "and released, it is free again" \
    "$("$BIN" task list --project "$REPO" | grep -c 'claimed by')" "0"

echo "avísame cuando"
BEFORE_WATCH=$(checksum "$HANDOFF")
GENTLEMERGE_NAME=claude "$BIN" watch task "Traducir constants" --project "$REPO" \
    --note "luego lo reviso" > "$SANDBOX/watch.out"
check "a watch says how to call it off" "$(grep -c 'watch rm' "$SANDBOX/watch.out")" "1"
check "asking to be told changes nothing in the committed file" "$(checksum "$HANDOFF")" "$BEFORE_WATCH"
check "the rule is standing, and remembers why you asked" \
    "$("$BIN" watch list | grep -c 'luego lo reviso')" "1"
check "and it is filed against the task's id, not its text" \
    "$("$BIN" watch list | grep -c 'task-done Traducir')" "0"
# A watch on something already finished could only fire the day somebody
# reopens it, which is never what was meant.
check "watching a finished task is refused, kindly" \
    "$("$BIN" watch task "Barrer recompensas" --project "$REPO" | grep -c 'Already done')" "1"
if "$BIN" watch task "no existe eso" --project "$REPO" > "$SANDBOX/watch-bad.out" 2>&1; then
    fail "a watch on a task that does not exist should not report success"
else
    ok "a watch on a task that does not exist is refused"
fi
WATCH_ID=$("$BIN" watch list | sed -n '2p' | awk '{print $1}')
"$BIN" watch rm "$WATCH_ID" > /dev/null
check "called off, nothing is standing" "$("$BIN" watch list | grep -c 'task-done')" "0"
check "and calling it off is an append, not a rewrite" \
    "$(grep -c 'task-done' "$GENTLEMERGE_HOME/watches.jsonl")" "2"
check "a note that is only a secret is not watched either" \
    "$("$BIN" watch idle codex --project "$REPO" --note "sk-TEST0000000000000000000000FAKE" 2>&1 |
        grep -c 'Not watched')" "1"
"$BIN" watch list | tail -n +2 | awk '{print $1}' | while read -r id; do
    [ -n "$id" ] && "$BIN" watch rm "$id" > /dev/null
done

echo "what a new session is told"
CONTEXT=$(cd "$REPO" && printf '{"session_id":"s7","hook_event_name":"SessionStart","source":"startup"}' |
    sh "$HOOK" --provider claude-code --mode context)
check "session start returns context JSON" \
    "$(printf '%s' "$CONTEXT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["hookEventName"])' 2>/dev/null)" \
    "SessionStart"
INJECTED=$(printf '%s' "$CONTEXT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])' 2>/dev/null)
check "it carries the open task" "$(printf '%s' "$INJECTED" | grep -c 'Traducir constants a EN')" "1"
check "it does not carry finished work" "$(printf '%s' "$INJECTED" | grep -c 'Barrer recompensas rotas')" "0"
check "it carries the last commit" "$(printf '%s' "$INJECTED" | grep -c 'first')" "1"
rm -f "$SPOOL"/*.json

echo "two agents seeing each other"
if [ "$(uname -s)" != Darwin ]; then
    printf "  skip  macOS GUI ingestion (headless protocol checks still run below)\n"
elif [ ! -x "$ROOT/build/GentleMerge.app/Contents/MacOS/gentlemerge" ]; then
    fail "app not built — run 'make app' first (this section did not run)"
else
    APP="$ROOT/build/GentleMerge.app/Contents/MacOS/gentlemerge"
    GENTLEMERGE_HOME="$GENTLEMERGE_HOME" GENTLEMERGE_CLAUDE_SETTINGS="$GENTLEMERGE_CLAUDE_SETTINGS" \
        "$APP" > "$SANDBOX/app.log" 2>&1 &
    TEST_APP_PID=$!
    # Fixed sleeps flake on a busy machine; wait for the thing itself instead.
    wait_for() {
        i=0
        while [ $i -lt 100 ]; do
            grep -q "$1" "$GENTLEMERGE_HOME/activities.json" 2>/dev/null && return 0
            sleep 0.2
            i=$((i + 1))
        done
        return 1
    }

    # Codex says what it is doing. This shell is a transient subshell — the
    # pid the hook would grab is its parent, dead before the app looks. Real
    # agents are long-lived, so hand the hook the app's own pid to stand in.
    (cd "$REPO" && printf '{"session_id":"codex-1","type":"agent-turn-complete","last-assistant-message":"he migrado el schema de misiones"}' |
        GENTLEMERGE_PID=$TEST_APP_PID sh "$HOOK" --provider codex --mode notify) >/dev/null
    wait_for "codex-1" || fail "the app never picked up the codex session"

    # Claude starts a turn in the same project and is told about it.
    OUT=$(cd "$REPO" && printf '{"session_id":"claude-1","hook_event_name":"UserPromptSubmit","prompt":"arregla el generador"}' |
        GENTLEMERGE_PID=$TEST_APP_PID sh "$HOOK" --provider claude-code --mode context)
    BRIEF=$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])' 2>/dev/null)

    check "claude is told codex is running" "$(printf '%s' "$BRIEF" | grep -c 'Codex.*migrado el schema')" "1"
    check "and what codex just did" "$(printf '%s' "$BRIEF" | grep -c 'migrado el schema')" "1"
    check "but not about itself" "$(printf '%s' "$BRIEF" | grep -c 'arregla el generador')" "0"

    wait_for 'arregla el generador' || fail "the app never picked up Claude's prompt"
    WHO=$("$BIN" who --project "$REPO")
    check "who shows Codex's actual activity" "$(printf '%s' "$WHO" | grep -c 'migrado el schema')" "1"
    check "who shows Claude's actual activity" "$(printf '%s' "$WHO" | grep -c 'arregla el generador')" "1"

    # Nothing changed since: saying it again on every turn would be noise.
    AGAIN=$(cd "$REPO" && printf '{"session_id":"claude-1","hook_event_name":"UserPromptSubmit","prompt":"sigue"}' |
        GENTLEMERGE_PID=$TEST_APP_PID sh "$HOOK" --provider claude-code --mode context)
    check "an unchanged picture is not repeated" "$AGAIN" ""

    # A message always gets through. Scoped to the repository the agents are
    # in: since notes became project-scoped by default, one said from anywhere
    # else is addressed to another project.
    "$BIN" say "no toquéis el árbol de recompensas" --from you --project "$REPO" >/dev/null
    WITH_MESSAGE=$(cd "$REPO" && printf '{"session_id":"claude-1","hook_event_name":"UserPromptSubmit","prompt":"ok"}' |
        GENTLEMERGE_PID=$TEST_APP_PID sh "$HOOK" --provider claude-code --mode context)
    check "a new message reaches the agent" \
        "$(printf '%s' "$WITH_MESSAGE" | grep -c 'no toquéis el árbol')" "1"


    kill "$TEST_APP_PID" 2>/dev/null || true
    wait "$TEST_APP_PID" 2>/dev/null || true
    TEST_APP_PID=""
fi

# Hermes has no hooks and no session: `brief --as` is the whole of its inbox,
# and the run above is exactly what it cannot do. This is the same flow its
# wrapper runs, one process at a time, with no app needed.
echo "an agent with no hooks receives, and receives once"
"$BIN" say "traduce constants a EN" --to hermes --from claude --project "$REPO" >/dev/null

# Looking without a name must not take the note off Hermes' pile.
ANON=$(cd "$REPO" && "$BIN" brief)
check "a nameless read sees a note addressed to somebody else" \
    "$(printf '%s' "$ANON" | grep -c 'traduce constants a EN')" "1"
check "and says who it is for" "$(printf '%s' "$ANON" | grep -c '(for hermes)')" "1"

FIRST=$(cd "$REPO" && "$BIN" brief --as hermes)
check "hermes is handed what was addressed to it" \
    "$(printf '%s' "$FIRST" | grep -c 'traduce constants a EN')" "1"
check "and is not told it is for somebody else" \
    "$(printf '%s' "$FIRST" | grep -c '(for hermes)')" "0"

AGAIN=$(cd "$REPO" && "$BIN" brief --as hermes)
check "identifying yourself is consuming: the second run is quiet" \
    "$(printf '%s' "$AGAIN" | grep -c 'traduce constants a EN')" "0"
check "the marker is a pseudo-session, not a session" \
    "$([ -f "$GENTLEMERGE_HOME/delivered/reader-hermes.json" ] && echo yes || echo no)" "yes"

# The other half of the wrapper: say what you did, then take it back.
"$BIN" say "traducidos 40 textos" --from hermes --project "$REPO" >/dev/null
"$BIN" say --from hermes --done --project "$REPO" > "$SANDBOX/hermes-done.out"
check "hermes can take its own note back" \
    "$(grep -c 'traducidos 40 textos' "$SANDBOX/hermes-done.out")" "1"
check "and nobody is told about it any more" \
    "$(cd "$REPO" && "$BIN" brief | grep -c 'traducidos 40 textos')" "0"

echo "a session's executors have names of their own"
"$BIN" say "el schema es mío" --to claude --from codex --project "$REPO" >/dev/null
EXEC=$(cd "$REPO" && GENTLEMERGE_NAME=claude#exec1 "$BIN" brief --as claude#exec1)
check "addressing the session reaches the executor it launched" \
    "$(printf '%s' "$EXEC" | grep -c 'el schema es mío')" "1"

"$BIN" say "esa rama es tuya" --to claude#exec1 --from codex --project "$REPO" >/dev/null
check "naming one executor does not reach its sibling" \
    "$(cd "$REPO" && "$BIN" brief --as claude#exec2 | grep -c 'esa rama es tuya')" "0"
check "and does reach the one it names" \
    "$(cd "$REPO" && "$BIN" brief --as claude#exec1 | grep -c 'esa rama es tuya')" "1"

# The name is who runs the command, so it is who the note is from.
GENTLEMERGE_NAME=claude#exec1 "$BIN" say "fase 5 lista" --project "$REPO" >/dev/null
check "an executor signs with the name it was given" \
    "$(cd "$REPO" && "$BIN" brief --as codex | grep -c 'claude#exec1')" "1"

echo "nothing sensitive crosses the bus"
SKEY="ghp_TEST00000000000000000000FAKE"
"$BIN" say "despliega con $SKEY y avisa a agent@example.invalid" > "$SANDBOX/say.out" 2>&1
check "the sender is told what was taken out" "$(grep -c 'taken out' "$SANDBOX/say.out")" "1"
check "the key never reaches disk" "$(grep -c "$SKEY" "$GENTLEMERGE_HOME/messages.jsonl")" "0"
check "neither does the email" "$(grep -c 'agent@example.invalid' "$GENTLEMERGE_HOME/messages.jsonl")" "0"
check "the rest of the sentence survives" "$(grep -c 'despliega con' "$GENTLEMERGE_HOME/messages.jsonl")" "1"

if "$BIN" say "sk-TEST0000000000000000000000FAKE" > "$SANDBOX/say2.out" 2>&1; then
    fail "a message that is only a secret should not report success"
else
    ok "a message that is only a secret is withheld"
fi

"$BIN" task add "rotar la clave AKIAFAKEFAKEFAKEFAKE" --project "$REPO" > /dev/null 2>&1 || true
check "a secret never lands in the committed handoff" "$(grep -c 'AKIAFAKEFAKEFAKEFAKE' "$HANDOFF")" "0"
check "but the task itself is kept" "$(grep -c 'rotar la clave' "$HANDOFF")" "1"
check "ordinary numbers are left alone" \
    "$("$BIN" say "el puerto 8080 y la línea 42" | grep -c 'el puerto 8080 y la línea 42')" "1"

# The one channel that carries a file rather than a sentence. Everything here
# is about what lands on disk and what the other agent is handed — neither of
# which a unit test can see through a real process.
echo "leaving a file, not a paragraph"
RKEY="sk-TEST0000000000000000000000FAKE"
printf '# Informe\nDesplegado con ANTHROPIC_API_KEY=%s\nel puerto sigue siendo 8080\n' "$RKEY" \
    > "$SANDBOX/report.md"
"$BIN" say "el informe está listo" --to receptor --from codex --project "$REPO" \
    --attach "$SANDBOX/report.md" > "$SANDBOX/attach.out" 2>&1
check "the sender is told where it went" "$(grep -c '→ attachment:' "$SANDBOX/attach.out")" "1"
check "the stored copy has lost the key" \
    "$(grep -rc "$RKEY" "$GENTLEMERGE_HOME/artifacts" | grep -cv ':0$')" "0"
check "and is still the report" \
    "$(grep -rc 'el puerto sigue siendo 8080' "$GENTLEMERGE_HOME/artifacts" | grep -c ':1$')" "1"
check "the original the sender wrote is untouched" \
    "$(grep -c 'sk-TEST0000000000000000000000FAKE' "$SANDBOX/report.md")" "1"

RECEIVED=$(cd "$REPO" && "$BIN" brief --as receptor)
check "the receiver is handed a path" "$(printf '%s' "$RECEIVED" | grep -c 'artifacts/')" "1"
check "and the first lines of it" "$(printf '%s' "$RECEIVED" | grep -c '# Informe')" "1"
check "and the path it was handed exists" \
    "$([ -f "$(printf '%s' "$RECEIVED" | sed -n 's|.*→ attachment: \(.*\) (.*|\1|p' | sed "s|^~|$HOME|")" ] && echo yes || echo no)" \
    "yes"

# Same bytes under another name: one directory, not two.
cp "$SANDBOX/report.md" "$SANDBOX/informe.md"
"$BIN" say "el mismo, otra vez" --from codex --project "$REPO" --attach "$SANDBOX/informe.md" > /dev/null 2>&1
check "the same content twice is one directory" \
    "$(ls "$GENTLEMERGE_HOME/artifacts" | wc -l | tr -d ' ')" "1"

# Bytes nothing can read as text cross verbatim, and every line says so.
printf '\211PNG\r\n\032\n\377\376\001' > "$SANDBOX/shot.png"
"$BIN" say "así se ve" --from codex --project "$REPO" --attach "$SANDBOX/shot.png" > "$SANDBOX/binary.out" 2>&1
check "a binary says nobody scrubbed it" "$(grep -c 'binary — not scrubbed' "$SANDBOX/binary.out")" "1"
check "and is copied byte for byte" \
    "$(cmp -s "$SANDBOX/shot.png" "$(find "$GENTLEMERGE_HOME/artifacts" -name shot.png)" && echo same || echo different)" \
    "same"

dd if=/dev/zero of="$SANDBOX/huge.log" bs=1024 count=2100 2>/dev/null
if "$BIN" say "el log entero" --from codex --project "$REPO" --attach "$SANDBOX/huge.log" > "$SANDBOX/huge.out" 2>&1; then
    fail "a file over the cap should not report success"
else
    ok "a file over the cap is refused"
fi
check "and the note it was attached to was never posted" \
    "$(grep -c 'el log entero' "$GENTLEMERGE_HOME/messages.jsonl")" "0"

if "$BIN" say "la clave" --from codex --project "$REPO" \
    --attach "$SANDBOX/key.txt" > /dev/null 2>&1; then
    fail "attaching a file that does not exist should not report success"
else
    ok "attaching a file that is not there is refused"
fi

echo "restore points"
SNAP_ID=$("$BIN" snapshot create "before the agent" --project "$REPO" | awk '{print $1}' || true)
printf 'let version = 999\n' > "$REPO/Sources/App.swift"
printf '// invented by the agent\n' > "$REPO/Sources/New.swift"
"$BIN" snapshot restore "$SNAP_ID" --project "$REPO" > "$SANDBOX/restore.out" 2>&1
check "file content is back" "$(cat "$REPO/Sources/App.swift")" "let version = 1"
check "agent's new file survives" "$([ -f "$REPO/Sources/New.swift" ] && echo yes || echo no)" "yes"
check "restore is itself undoable" "$(grep -c 'Undo this restore' "$SANDBOX/restore.out")" "1"
check "staging area untouched" "$(git -C "$REPO" diff --cached --name-only | wc -l | tr -d ' ')" "0"

echo "review"
PROJ="$SANDBOX/project"
mkdir -p "$PROJ/src"
git -C "$PROJ" init -q 2>/dev/null || { mkdir -p "$PROJ"; git -C "$PROJ" init -q; }
git -C "$PROJ" config user.email test@example.com
git -C "$PROJ" config user.name Test
printf '{"scripts":{"test":"exit 3"}}\n' > "$PROJ/package.json"
printf 'export const a = 1\n' > "$PROJ/src/HomeView.tsx"
git -C "$PROJ" add -A
git -C "$PROJ" commit -qm first
BASE=$(git -C "$PROJ" rev-parse HEAD)
printf 'export const a = 2\nexport const b = 3\n' > "$PROJ/src/HomeView.tsx"
printf 'export const c = 4\n' > "$PROJ/src/new-module.ts"

if "$BIN" review "$PROJ" --since "$BASE" > "$SANDBOX/review.out" 2>&1; then
    REVIEW_STATUS=0
else
    REVIEW_STATUS=$?
fi
check "a failing check fails the review" "$REVIEW_STATUS" "1"
check "reports the changed file" "$(grep -c 'src/HomeView.tsx' "$SANDBOX/review.out")" "1"
check "sees the file created inside a new path" "$(grep -c 'src/new-module.ts' "$SANDBOX/review.out")" "1"
check "runs the project's own test script" "$(grep -c '✗ npm test' "$SANDBOX/review.out")" "1"
check "says what it cannot know" "$(grep -c 'NEEDS YOUR EYES' "$SANDBOX/review.out")" "1"
check "flags the view change" "$(grep -ci 'how it looks' "$SANDBOX/review.out")" "1"

# --- Phase 1, step 6: the four flows a new checkout has to survive on its own ---
# Real worktrees with real worktree-local labels (git config in the common
# dir), a claim filed in one and honored from the other, a request answered by
# the agent that received it, a delta that goes quiet, and the MCP server
# speaking JSON-RPC over its real stdio.

echo "worktrees claim and see each other"
GITROOT="$SANDBOX/wtree"
mkdir -p "$GITROOT/Sources"
git -C "$GITROOT" init -q
git -C "$GITROOT" config user.email test@example.com
git -C "$GITROOT" config user.name Test
git -C "$GITROOT" config extensions.worktreeConfig true
printf 'let seed = 1\n' > "$GITROOT/Sources/Seed.swift"
git -C "$GITROOT" add -A
git -C "$GITROOT" commit -qm seed
WT_A="$SANDBOX/wt-a"
WT_B="$SANDBOX/wt-b"
git -C "$GITROOT" worktree add -q -b agent/a "$WT_A"
git -C "$GITROOT" worktree add -q -b agent/b "$WT_B"
"$BIN" project init --label a --project "$WT_A" >/dev/null
"$BIN" project init --label b --project "$WT_B" >/dev/null
"$BIN" git-hooks install --project "$GITROOT" >/dev/null
export GENTLEMERGE_BIN="$BIN"
check "a worktree label is written where the bus reads it" \
    "$(git -C "$WT_A" config --get gentlemerge.label)" "a"

(cd "$WT_A" && "$BIN" claim --paths 'Sources/**' --intent "migrating seed" >/dev/null)
check "a claim made in one worktree is live in the other" \
    "$(cd "$WT_B" && "$BIN" claims | grep -c 'migrating seed')" "1"
CONFLICT=$(cd "$WT_B" && "$BIN" claim --paths 'Sources/App.swift' --intent "mine now" 2>&1 || true)
check "the second agent's claim is refused" "$(printf '%s' "$CONFLICT" | grep -c 'a\b')" "1"
printf 'let seed = 2\n' > "$WT_B/Sources/Seed.swift"
git -C "$WT_B" add -A
if git -C "$WT_B" commit -qm "b edits what a holds"; then
    fail "the pre-commit hook lets worktree B commit a file agent A claimed"
else
    ok "the pre-commit hook stops the commit from the other worktree"
fi
(cd "$WT_A" && "$BIN" release --paths 'Sources/**' >/dev/null)
printf 'let seed = 3\n' > "$WT_B/Sources/Seed.swift"
git -C "$WT_B" add -A
if git -C "$WT_B" commit -qm "b edits what a released"; then
    ok "after the release the commit goes through"
else
    fail "the pre-commit hook still blocks after the claim was released"
fi
(cd "$WT_A" && "$BIN" claim --paths 'Sources/Auto.swift' --intent "auto release" >/dev/null)
printf 'let auto = 1\n' > "$WT_A/Sources/Auto.swift"
git -C "$WT_A" add -A
git -C "$WT_A" commit -qm "a lands its own claim"
check "post-commit releases what just landed" \
    "$(cd "$WT_B" && "$BIN" claims | grep -c 'auto release')" "0"

echo "a delegated request round-trips"
DEL=$(cd "$WT_A" && "$BIN" delegate --to b --title "smoke delegate" --spec "write the number" --may-touch 'Sources/**')
RID=$(printf '%s' "$DEL" | grep -o 'req-[a-z0-9-]*' | head -1)
[ -n "$RID" ] && ok "delegate returns a request id" || fail "delegate returned no request id: $DEL"
(cd "$WT_B" && "$BIN" request accept "$RID" >/dev/null)
printf 'let writtenByB = 42\n' > "$WT_B/Sources/Result.swift"
git -C "$WT_B" add Sources/Result.swift
git -C "$WT_B" commit -qm "complete delegated smoke result"
(cd "$WT_B" && "$BIN" request done "$RID" --result "Sources/Result.swift $(git -C "$WT_B" rev-parse --short HEAD)" >/dev/null)
check "the requester's brief carries the result" \
    "$([ "$(cd "$WT_A" && "$BIN" brief --as a | grep -c 'Result.swift')" -ge 1 ] && echo yes || echo no)" "yes"

echo "the delta says nothing when nothing happened"
PAYLOAD="$SANDBOX/prompt.json"
printf '{"session_id":"smoke-a2","hook_event_name":"UserPromptSubmit"}' > "$PAYLOAD"
DELTA1=$(cd "$WT_A" && "$BIN" session-context --provider claude-code --payload "$PAYLOAD" --project "$WT_A")
[ -n "$DELTA1" ] && ok "the first delta after a result has news" || fail "first delta was empty"
(cd "$WT_A" && "$BIN" session-context --provider claude-code --payload "$PAYLOAD" --project "$WT_A") > "$SANDBOX/delta-second.out"
[ ! -s "$SANDBOX/delta-second.out" ] && ok "the second delta is exactly nothing" || fail "second delta emitted bytes"

echo "coordination cost"
check "stats counts the session's two deltas, one of them empty" \
    "$("$BIN" stats --session smoke-a2 | grep -c '2 briefings (1 non-empty)')" "1"
check "the global line always says estimate" \
    "$("$BIN" stats | grep -c 'coordination cost:.*(estimate: chars/4)')" "1"
check "stats --value reports what was saved" \
    "$("$BIN" stats --value | grep -c 'coordination value')" "1"
check "compact reports what went away" \
    "$("$BIN" compact | grep -c 'requests finished')" "1"

echo "doctor"
DOCTOR=$(cd "$WT_A" && "$BIN" doctor --project "$WT_A")
check "doctor reports the hooks it just installed" "$(printf '%s' "$DOCTOR" | grep -c '^ok git-hooks:')" "1"
check "doctor reports a git new enough for merge-tree" "$(printf '%s' "$DOCTOR" | grep -c '^ok git:')" "1"
check "doctor reports nothing broken" "$(printf '%s' "$DOCTOR" | grep -c '^fail ')" "0"
(cd "$WT_A" && "$BIN" request ack "$RID" >/dev/null)

echo "the radar warns, and a branch lands"
printf 'let seed = 100\n' > "$WT_A/Sources/Seed.swift"
git -C "$WT_A" add -A
git -C "$WT_A" commit -qm "a moves seed"
printf 'let seed = 200\n' > "$WT_B/Sources/Seed.swift"
git -C "$WT_B" add -A
git -C "$WT_B" commit -qm "b moves seed"
INTO=main
git -C "$GITROOT" show-ref --verify -q refs/heads/main || INTO=master
RADAR1=$(cd "$WT_A" && "$BIN" radar --project "$WT_A" --force)
check "radar checks the pair" "$(printf '%s' "$RADAR1" | grep -c '1 pair(s) checked')" "1"
check "and announces the conflict once" "$(printf '%s' "$RADAR1" | grep -c '1 new conflict(s)')" "1"
check "a hears what it would hit" "$(cd "$WT_A" && "$BIN" brief --as a | grep -c 'will conflict with agent/b')" "1"
RADAR2=$(cd "$WT_A" && "$BIN" radar --project "$WT_A" --force)
check "the same conflict is not announced twice" "$(printf '%s' "$RADAR2" | grep -c '0 new conflict(s)')" "1"

if (cd "$WT_B" && "$BIN" land --into "$INTO" > "$SANDBOX/land.out" 2>&1); then
    ok "b lands onto $INTO"
else
    fail "land failed: $(cat "$SANDBOX/land.out")"
fi
check "main moved to b's rebased tip" \
    "$(git -C "$GITROOT" rev-parse "$INTO")" "$(git -C "$WT_B" rev-parse agent/b)"
check "the bus says what landed" "$(cd "$WT_A" && "$BIN" brief --as a | grep -c 'landed.*from b')" "1"

# A now conflicts with the new main: the dry run says so, names the file and
# who touched it, and moves nothing.
if (cd "$WT_A" && "$BIN" land --into "$INTO" --dry-run > "$SANDBOX/dry.out" 2>&1); then
    fail "a dry run into a conflict should not report success"
else
    ok "a dry run refuses a conflicting landing"
fi
check "and names the file" "$(grep -c 'Seed.swift' "$SANDBOX/dry.out")" "1"
check "and who touched it" "$(grep -c 'touched by Test' "$SANDBOX/dry.out")" "1"
check "and main did not move on a dry run" \
    "$(git -C "$GITROOT" rev-parse "$INTO")" "$(git -C "$WT_B" rev-parse agent/b)"

echo "a worktree's ports"
ENV_A=$(cd "$WT_A" && "$BIN" env)
check "the label travels" "$(printf '%s' "$ENV_A" | grep -c 'GENTLEMERGE_LABEL=a')" "1"
check "same label, stable ports" "$ENV_A" "$(cd "$WT_A" && "$BIN" env)"
(cd "$WT_A" && "$BIN" env --write > /dev/null)
check "env.sh lands in the worktree" "$([ -f "$WT_A/.gentlemerge/env.sh" ] && echo yes || echo no)" "yes"
check "the range spans a hundred ports" "$(grep -c 'AGENT_PORT_RANGE=[0-9][0-9]*-[0-9][0-9]*' "$WT_A/.gentlemerge/env.sh")" "1"
check "init kept the generated file out of git" "$(grep -c '^\.gentlemerge/env.sh$' "$GITROOT/.gitignore")" "1"

echo "the MCP server speaks JSON-RPC over stdio"
MCP_OUT=$(cd "$WT_A" && printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}\n{"jsonrpc":"2.0","id":2,"method":"tools/list"}\n' | \
    "$BIN" mcp 2>/dev/null)
check "initialize answers with the protocol version" \
    "$(printf '%s' "$MCP_OUT" | grep -c '2024-11-05')" "1"
check "tools/list answers with the tool catalogue" \
    "$(printf '%s' "$MCP_OUT" | python3 -c 'import json,sys
tools=0
for line in sys.stdin:
    line=line.strip()
    if not line: continue
    try: d=json.loads(line)
    except Exception: continue
    r=d.get("result") or {}
    if isinstance(r.get("tools"), list): tools=max(tools,len(r["tools"]))
print(min(tools, 99))')" "17"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
