#!/usr/bin/env bash
# Repro for audit findings #2, #3 and #4 (2026-10-06), run against a fresh
# build in a temp GENTLEMERGE_HOME.
#
#   #2 two MCP processes sharing one label must each receive pending mail
#      (the second used to get "(nothing new)" because both sessions used the
#      session id "mcp-<identity>").
#   #3 task_done with an id nobody issued must error, not answer "done".
#   #4 the pre-commit gate must block a foreign live claim even when this
#      worktree has no label (it used to print "claims not enforced" and exit 0).
set -uo pipefail

HOME_DIR="$(mktemp -d /tmp/gm-bug234.XXXXXX)"
PROJ="$(mktemp -d /tmp/gm-bug234-proj.XXXXXX)"
export GENTLEMERGE_HOME="$HOME_DIR"
BIN="$(cd "$(dirname "$0")/.." && swift build --show-bin-path)/gentlemerge"
export GENTLEMERGE_BIN="$BIN"
FAILS=0

fail() { echo "FAIL: $1"; FAILS=$((FAILS + 1)); }
ok() { echo "ok: $1"; }

echo "== home: $HOME_DIR  proj: $PROJ"
cd "$PROJ"
git init -q
git config user.email repro@testgit
git config user.name repro
echo hello > a.txt
git add a.txt
git commit -qm baseline

# ---- Bug 2: two MCP processes, same label ----
echo "== BUG 2: two MCP processes with label 'receiver'"
"$BIN" say --to receiver "bug2-ping-for-receiver" >/dev/null

REQUESTS_A="$(
  printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"brief","arguments":{"project":"'"$PROJ"'"}}}'
)"
printf '%s' "$REQUESTS_A" | "$BIN" mcp --label receiver --project "$PROJ" > "$HOME_DIR/procA.jsonl"
printf '%s' "$REQUESTS_A" | "$BIN" mcp --label receiver --project "$PROJ" > "$HOME_DIR/procB.jsonl"

python3 - "$HOME_DIR/procA.jsonl" "$HOME_DIR/procB.jsonl" <<'PY' || FAILS=$((FAILS + 1))
import json, sys
def brief(path):
    for line in open(path):
        line = line.strip()
        if not line: continue
        r = json.loads(line)
        try: rid = int(r.get("id"))
        except (TypeError, ValueError): continue
        if rid == 2:
            return r["result"]["content"][0]["text"]
    return ""
a, b = brief(sys.argv[1]), brief(sys.argv[2])
print("== procA shows ping:", "bug2-ping-for-receiver" in a, "| procB shows ping:", "bug2-ping-for-receiver" in b)
if "bug2-ping-for-receiver" in a and "bug2-ping-for-receiver" in b:
    print("ok: bug2 both sessions received the message")
else:
    print("FAIL: bug2 a session with the same label lost the message")
    sys.exit(1)
PY

# ---- Bug 3: task_done must reject unknown ids ----
echo "== BUG 3: task_done with id 'no-existe' vs a real id"
TASK_TEXT="bug3 repro task"
TASK_ID="$(python3 - "$TASK_TEXT" <<'PY'
import sys
t = sys.argv[1].lower().strip()
h = 0xcbf29ce484222325
for b in t.encode(): h = ((h ^ b) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
print(format(h, "x"))
PY
)"
REQUESTS_3="$(
  printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"task_add","arguments":{"text":"'"$TASK_TEXT"'","project":"'"$PROJ"'"}}}' \
    '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"task_done","arguments":{"id":"no-existe","project":"'"$PROJ"'"}}}' \
    '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"task_done","arguments":{"id":"'"$TASK_ID"'","project":"'"$PROJ"'"}}}'
)"
printf '%s' "$REQUESTS_3" | "$BIN" mcp --label receiver --project "$PROJ" > "$HOME_DIR/task.jsonl"

python3 - "$HOME_DIR/task.jsonl" <<'PY' || FAILS=$((FAILS + 1))
import json, sys, re
by_id = {}
for line in open(sys.argv[1]):
    line = line.strip()
    if not line: continue
    r = json.loads(line)
    if "id" in r:
        try: by_id[int(r["id"])] = r
        except (TypeError, ValueError): pass
def text_of(i):
    res = by_id.get(i, {}).get("result", {})
    content = res.get("content", [{}])
    return content[0].get("text", ""), bool(res.get("isError"))
bogus, bogus_err = text_of(3)
real, real_err = text_of(4)
print("== task_done(no-existe):", repr(bogus[:90]), "isError:", bogus_err)
print("== task_done(real):", repr(real[:60]), "isError:", real_err)
good = (not bogus.strip().startswith("done")) and ("no task" in bogus.lower()) and real.strip() == "done"
if good:
    print("ok: bug3 unknown id errors, real id answers done")
else:
    print("FAIL: bug3 task_done still confirms nonexistent tasks")
    sys.exit(1)
PY

# ---- Bug 4: unlabeled checkout still blocks on a foreign live claim ----
echo "== BUG 4: commit from an unlabeled checkout with a foreign claim on a.txt"
"$BIN" project init --git-hooks >/dev/null || fail "project init --git-hooks failed"
CLAIM_OUT="$("$BIN" claim --paths "a.txt" --from claude 2>&1)"; rc=$?
echo "== claim: $CLAIM_OUT (rc=$rc)"
[ $rc -eq 0 ] || fail "could not create the foreign claim: $CLAIM_OUT"

echo change >> a.txt
git add a.txt

rc=0; GATE_OUT="$("$BIN" precommit --enforce --staged 2>&1)"; rc=$?
echo "== gate output:"; echo "$GATE_OUT"
if [ $rc -ne 0 ] && printf '%s' "$GATE_OUT" | grep -q "live claims still block"; then
  ok "bug4 gate blocks an unlabeled checkout on a live foreign claim (rc=$rc)"
else
  fail "bug4 gate did not block (rc=$rc)"
fi

rc=0; git commit -qm "should be blocked" 2>/dev/null; rc=$?
if [ $rc -ne 0 ]; then
  ok "bug4 git commit refused (rc=$rc)"
else
  fail "bug4 git commit went through despite the foreign claim"
fi

# Control: once the claim is released, the same commit must succeed.
"$BIN" release --paths "a.txt" --from claude >/dev/null 2>&1
rc=0; git commit -qm "now allowed" 2>/dev/null; rc=$?
if [ $rc -eq 0 ]; then
  ok "control: commit succeeds after the claim is released"
else
  fail "control: commit still blocked after release (rc=$rc)"
fi

echo
if [ "$FAILS" -eq 0 ]; then
  echo "ALL REPROS PASS (bugs 2, 3, 4 fixed)"
else
  echo "$FAILS REPRO(S) FAILED"
fi
echo "== kept for inspection: $HOME_DIR $PROJ"
exit "$FAILS"
