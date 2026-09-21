#!/bin/sh
# Thirty-second soak for the concurrent-file-access domain: N workers saying
# and claiming against one home at the same time, then the invariants —
# no message lost, no corrupt JSON line, no double claim.
#
# Usage: sh Scripts/stress-test.sh            # builds first if needed
#        WORKERS=8 SOAK_SECONDS=30 sh Scripts/stress-test.sh
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORKERS="${WORKERS:-6}"
DURATION="${SOAK_SECONDS:-30}"
BIN="${BIN:-${GENTLEMERGE_BIN:-$ROOT/.build/debug/gentlemerge}}"
[ -x "$BIN" ] || (cd "$ROOT" && swift build >/dev/null 2>&1)
[ -x "$BIN" ] || { echo "build first: swift build" >&2; exit 1; }

SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/gentlemerge-stress.XXXXXX")
export GENTLEMERGE_HOME="$SANDBOX/home"
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$SANDBOX"' EXIT

w=0
while [ "$w" -lt "$WORKERS" ]; do
    (
        export GENTLEMERGE_LABEL="soak-$w"
        k=0
        end=$(( $(date +%s) + DURATION ))
        while [ "$(date +%s)" -lt "$end" ]; do
            "$BIN" say "soak-$w-$k" --project "$SANDBOX" >/dev/null 2>&1
            "$BIN" claim --paths "soak-$w/**" --project "$SANDBOX" >/dev/null 2>&1
            k=$((k + 1))
        done
        echo "$k" > "$SANDBOX/done-$w"
    ) &
    w=$((w + 1))
done
wait

python3 - "$SANDBOX" "$WORKERS" <<'EOF'
import json, sys, glob
sandbox, workers = sys.argv[1], int(sys.argv[2])
sent = {}
for w in range(workers):
    with open(f"{sandbox}/done-{w}") as f:
        sent[w] = int(f.read().strip())
total = sum(sent.values())
lines = open(f"{sandbox}/home/messages.jsonl").read().splitlines()
texts = set()
for i, line in enumerate(lines):
    try:
        texts.add(json.loads(line)["text"])
    except Exception:
        print(f"FAIL corrupt JSON line {i}: {line[:120]}")
        sys.exit(1)
missing = [f"soak-{w}-{k}" for w in range(workers) for k in range(sent[w]) if f"soak-{w}-{k}" not in texts]
if missing:
    print(f"FAIL {len(missing)} lost messages, first: {missing[:3]} ({total} sent, {len(lines)} lines)")
    sys.exit(1)
claims = {}
for c in json.load(open(f"{sandbox}/home/claims-paths.json")):
    if isinstance(c, dict) and c.get("pattern", "").startswith("soak-"):
        claims.setdefault(c["pattern"], []).append(c["label"])
bad = {p: ls for p, ls in claims.items() if len(ls) != 1}
if bad:
    print(f"FAIL double/lost claims: {bad}")
    sys.exit(1)
print(f"ok: {total} says all present, {len(lines)} clean lines, {len(claims)} claims each held once")
EOF
