#!/bin/bash
# Contract tests for scripts/wire-hooks.sh: it may only ADD SpeakySpeak's hook
# groups, and everything a user already had must come out byte-for-byte equal.
set -u
cd "$(dirname "$0")/.."
W="$PWD/scripts/wire-hooks.sh"
TDIR=$(mktemp -d); trap 'rm -rf "$TDIR"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; }
run() { SPEAKYSPEAK_SETTINGS="$1" bash "$W" >"$TDIR/out" 2>&1; }

echo "wire 1: no settings file -> created with all four events"
S1="$TDIR/a/settings.json"; run "$S1"
[ "$(jq -r '.hooks | keys | join(",")' "$S1")" = "Notification,PostToolUse,SessionEnd,Stop" ] && ok "four events" || bad "got: $(cat "$S1")"
[ "$(jq -r '.hooks.Notification[0].matcher' "$S1")" = "permission_prompt|elicitation_dialog|agent_needs_input" ] && ok "Notification matcher" || bad "matcher"
[ "$(jq -r '.hooks.Stop[0].hooks[0].async' "$S1")" = "true" ] && ok "Stop async" || bad "Stop async"
[ "$(jq -r '.hooks.SessionEnd[0].hooks[0] | has("timeout")' "$S1")" = "false" ] && ok "SessionEnd plain" || bad "SessionEnd"

echo "wire 2: existing file (old install: Stop+SessionEnd, foreign hooks, other keys) -> only adds"
S2="$TDIR/b/settings.json"; mkdir -p "$TDIR/b"
cat > "$S2" <<'J'
{"permissions":{"allow":["Bash(ls:*)"]},"env":{"X":"1"},
 "hooks":{"Stop":[{"matcher":"*","hooks":[{"type":"command","command":"afplay /System/Library/Sounds/Glass.aiff"},{"type":"command","command":"bash ~/.claude/hooks/speak-reply.sh","timeout":300,"async":true}]}],
          "SessionEnd":[{"matcher":"*","hooks":[{"type":"command","command":"bash ~/.claude/hooks/session-end.sh"}]}],
          "PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo hi"}]}]}}
J
before=$(jq -S . "$S2"); run "$S2"
[ "$(jq -S 'del(.hooks.PostToolUse, .hooks.Notification)' "$S2")" = "$before" ] && ok "everything pre-existing untouched (incl. Stop timeout 300)" || bad "pre-existing content changed"
[ "$(jq '.hooks.Stop | length' "$S2")" = 1 ] && ok "Stop not duplicated" || bad "Stop duplicated"
[ "$(jq '.hooks.PostToolUse | length' "$S2")" = 1 ] && [ "$(jq '.hooks.Notification | length' "$S2")" = 1 ] && ok "PostToolUse + Notification added" || bad "missing additions"
ls "$TDIR/b/settings.json.bak-speakyspeak-"* >/dev/null 2>&1 && ok "backup written" || bad "no backup"
grep -q "added PostToolUse Notification" "$TDIR/out" && ok "reports what it added" || bad "report: $(cat "$TDIR/out")"

echo "wire 3: second run is a no-op (no new backup, same bytes)"
mid=$(cat "$S2"); n=$(ls "$TDIR/b/" | grep -c bak); run "$S2"
[ "$(cat "$S2")" = "$mid" ] && [ "$(ls "$TDIR/b/" | grep -c bak)" = "$n" ] && ok "idempotent" || bad "changed on re-run"
grep -q "already registered" "$TDIR/out" && ok "says so" || bad "report: $(cat "$TDIR/out")"

echo "wire 4: invalid JSON is never written"
S4="$TDIR/c/settings.json"; mkdir -p "$TDIR/c"; printf '{"hooks": \n' > "$S4"; run "$S4"
[ "$(cat "$S4")" = '{"hooks": ' ] && ok "file untouched" || bad "file rewritten"
grep -q '"Notification"' "$TDIR/out" && ok "printed the block to merge by hand" || bad "no block printed: $(cat "$TDIR/out")"

echo; echo "wire tests: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
