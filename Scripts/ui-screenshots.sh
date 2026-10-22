#!/bin/sh
# Photographs the app's window and menu bar panel, light and dark, filled with
# made-up agents, so a UI change can show a before and an after.
#
#   make app && sh Scripts/ui-screenshots.sh /tmp/shots
#
# Runs inside a throwaway GENTLEMERGE_HOME; touches nothing of yours. Needs no
# Screen Recording permission: the app photographs its own windows
# (GENTLEMERGE_SNAPSHOT_DIR, see UISnapshot.swift) and then quits.

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:?usage: ui-screenshots.sh <output-dir>}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd -P)
APP="$ROOT/build/GentleMerge.app/Contents/MacOS/gentlemerge"
[ -x "$APP" ] || { echo "build first: make app" >&2; exit 1; }

# Not under $TMPDIR: it lives behind the /var -> /private/var symlink, and the
# app and the CLI spell the project path differently through it, so the notes
# land on a project the window is not showing (see smoke-test.sh).
mkdir -p "$HOME/Library/Caches"
SANDBOX=$(cd "$(mktemp -d "$HOME/Library/Caches/gentlemerge-shots.XXXXXX")" && pwd -P)
export GENTLEMERGE_HOME="$SANDBOX/home"
export GENTLEMERGE_CLAUDE_SETTINGS="$SANDBOX/settings.json"
export GENTLEMERGE_CODEX_CONFIG="$SANDBOX/config.toml"
cleanup() {
    [ -n "${PID:-}" ] && kill "$PID" 2>/dev/null || true
    rm -rf "$SANDBOX"
}
trap cleanup EXIT

"$APP" install >/dev/null
HOOK="$GENTLEMERGE_HOME/bin/gentlemerge-hook.sh"

REPO="$SANDBOX/valorforge"
mkdir -p "$REPO/src"
git -C "$REPO" init -q
git -C "$REPO" config user.email demo@example.com
git -C "$REPO" config user.name Demo
for subject in "feat: árbol de habilidades con 40 nodos" "fix: la racha ya no se reinicia a medianoche" \
    "feat: postales de mascotas" "chore: traducir constants a EN"; do
    echo "$subject" >> "$REPO/src/log.txt"
    git -C "$REPO" add -A
    git -C "$REPO" commit -qm "$subject"
done
printf '# valorforge\n' > "$REPO/CLAUDE.md"
"$APP" project init --project "$REPO" >/dev/null
"$APP" task add "Barrer recompensas rotas del árbol" --project "$REPO" --by claude >/dev/null
"$APP" task add "Revisar contraste del modo oscuro" --project "$REPO" --by codex >/dev/null
"$APP" task add "Grabar el vídeo de lanzamiento" --project "$REPO" --by you >/dev/null

# The app waits eight seconds before shooting; everything below lands well
# inside that. Waiting on activities.json instead would wait forever: the app
# writes it on the first event, and the events come after.
GENTLEMERGE_SNAPSHOT_DIR="$OUT" "$APP" > "$SANDBOX/app.log" 2>&1 &
PID=$!
sleep 3

# Hooks need a live pid to call a session alive; the app's own stands in.
hook() { (cd "$REPO" && printf '%s' "$3" | GENTLEMERGE_PID=$PID sh "$HOOK" --provider "$1" --mode "$2") >/dev/null; }
hook codex notify '{"session_id":"codex-1","type":"agent-turn-complete","last-assistant-message":"He migrado el schema de misiones y los tests pasan"}'
hook claude-code context '{"session_id":"claude-1","hook_event_name":"UserPromptSubmit","prompt":"arregla el generador de misiones diarias"}'
hook claude-code notify '{"session_id":"claude-2","hook_event_name":"Notification","message":"Claude needs your permission to use Bash"}'

say() { (cd "$REPO" && env -u CLAUDECODE -u CLAUDE_PROJECT_DIR "$APP" say "$@") >/dev/null; }
say "Voy a tocar src/missions — no lo editéis en la próxima hora" --from claude
say "Schema de misiones migrado; el campo reward ahora es obligatorio" --from codex --kind handoff
say "El build de CI en Linux está roto desde antes, no es nuestro" --from claude --urgent
say "Perfecto, gracias. Codex: cuando acabes, revisa el contraste del modo oscuro"

i=0
while kill -0 "$PID" 2>/dev/null && [ $i -lt 100 ]; do sleep 0.3; i=$((i + 1)); done
ls "$OUT"/*.png
