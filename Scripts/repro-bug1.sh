#!/usr/bin/env bash
# Repro of audit finding #1 (2026-10-06): a long urgent message used to be cut
# by BriefingRenderer.cap while AgentBus marked it delivered because the
# #handle appeared in the truncated output, so the remainder never came back.
#
# PASS criteria after the fix: the status read shows the WHOLE urgent body
# (including its last physical line, "LINE20 …"); only then is it correct for
# the follow-up brief to say "(nothing new)".
set -euo pipefail

HOME_DIR="$(mktemp -d /tmp/gm-bug1.XXXXXX)"
PROJ="$(mktemp -d /tmp/gm-bug1-proj.XXXXXX)"
export GENTLEMERGE_HOME="$HOME_DIR"
BIN="$(cd "$(dirname "$0")/.." && swift build --show-bin-path)/gentlemerge"

echo "== home: $HOME_DIR"

# Sender publishes an urgent with 20 long lines (~8k chars total).
cd "$PROJ"
LONG_BODY=""
for i in $(seq 1 20); do
  LONG_BODY+="LINE$i $(printf 'x%.0s' $(seq 1 380))"$'\n'
done
LONG_BODY="${LONG_BODY%$'\n'}"
CHARS=$(printf '%s' "$LONG_BODY" | wc -c | tr -d ' ')
echo "== urgent body chars: $CHARS"
"$BIN" say --kind urgent --to receiver "$LONG_BODY" >/dev/null

# Reader: MCP process labelled receiver, reading via `status` (delta mode).
REQUESTS="$(
  printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"status","arguments":{"project":"'"$PROJ"'"}}}' \
    '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"brief","arguments":{"project":"'"$PROJ"'"}}}'
)"
printf '%s' "$REQUESTS" | "$BIN" mcp --label receiver --project "$PROJ" > "$HOME_DIR/mcp-out.jsonl"

python3 - "$HOME_DIR/mcp-out.jsonl" "$CHARS" <<'PY'
import json, sys
lines = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
by_id = {}
for r in lines:
    if "id" in r:
        try: by_id[int(r["id"])] = r
        except (TypeError, ValueError): pass
status = by_id[2]["result"]["content"][0]["text"]
brief = by_id[3]["result"]["content"][0]["text"]
body_chars = int(sys.argv[2])
tail_present = "LINE20 " in status
head_present = "LINE1 " in status
print("== status chars:", len(status), "(body:", body_chars, ")")
print("== status has head line:", head_present)
print("== status has tail line (LINE20):", tail_present)
print("== second brief:", repr(brief[:80]))
ok = head_present and tail_present
print("VERDICT:", "PASS (full body shown; re-read may be empty)" if ok
      else "BUG (urgent tail missing from status — remainder lost)")
sys.exit(0 if ok else 1)
PY

echo "== cleanup: $HOME_DIR $PROJ (kept for inspection)"
