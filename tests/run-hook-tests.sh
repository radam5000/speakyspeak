#!/bin/bash
# Hook-contract fixture tests for hooks/speak-reply.sh.
#
# These four contracts have each regressed at least once in this project's
# history (see CLAUDE.md), so they are the floor any change to the hook must
# clear:
#   1. gate/race    — a mid-turn preamble followed by a tool call must NOT speak
#   2. gather       — a multi-entry turn speaks ALL its text entries (8/11 bug)
#   3. seen/resume  — a resumed turn never re-speaks what .seen recorded (8/12 bug)
#   4. queue contract — <epoch>-<sid>.m4a + .json with session/project/title/
#                       preview/text/created
#
# The REAL hook file is executed (hooks/speak-reply.sh), not a copy — the only
# test affordances are env: SPEAKYSPEAK_SPEECH_ROOT isolates the queue from any
# live deck, HOME points at an empty temp dir (no knob files, no kokoro binary,
# so the engine resolves to `say`), and PATH stubs replace say/open/afplay so
# nothing renders, launches, or plays.
#
# Runtime note: the negative tests (1 and 3a) each wait out the hook's full
# 30-second poll window — silence IS the pass condition. ~70s total.
set -u
cd "$(dirname "$0")/.."
HOOK="$PWD/hooks/speak-reply.sh"

TDIR=$(mktemp -d)
trap 'rm -rf "$TDIR"' EXIT
STUB="$TDIR/bin"; THOME="$TDIR/home"; PROJ="$TDIR/myproject"
mkdir -p "$STUB" "$THOME/.claude" "$PROJ"

# --- stubs -----------------------------------------------------------------
cat > "$STUB/say" <<'EOF'
#!/bin/bash
out=""
while [ $# -gt 0 ]; do
  [ "$1" = "-o" ] && { out="$2"; shift; }
  shift
done
cat > /dev/null   # consume stdin like the real say
[ -n "$out" ] && printf 'FAKEAUDIO' > "$out"
EOF
cat > "$STUB/open"   <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$STUB/afplay" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$STUB/say" "$STUB/open" "$STUB/afplay"

SID_FULL="fixturesession0001"
SID=$(printf '%s' "$SID_FULL" | cut -c1-8)   # fixtures
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL - $1"; }

run_hook() {  # $1 = transcript, $2 = speech root
  printf '{"transcript_path":"%s","session_id":"%s","cwd":"%s"}' "$1" "$SID_FULL" "$PROJ" \
    | env HOME="$THOME" PATH="$STUB:$PATH" SPEAKYSPEAK_SPEECH_ROOT="$2" bash "$HOOK"
}

now() { date -u +%Y-%m-%dT%H:%M:%S.000Z; }

# jsonl builders
e_user()      { printf '{"type":"user","uuid":"%s","timestamp":"%s","message":{"content":"%s"}}\n' "$1" "$(now)" "$2"; }
e_toolresult(){ printf '{"type":"user","uuid":"%s","timestamp":"%s","message":{"content":[{"type":"tool_result","content":"r"}]}}\n' "$1" "$(now)"; }
e_metauser()  { printf '{"type":"user","isMeta":true,"uuid":"%s","timestamp":"%s","message":{"content":[{"type":"text","text":"meta"}]}}\n' "$1" "$(now)"; }
e_text()      { printf '{"type":"assistant","uuid":"%s","timestamp":"%s","message":{"content":[{"type":"text","text":"%s"}]}}\n' "$1" "$(now)" "$2"; }
e_tooluse()   { printf '{"type":"assistant","uuid":"%s","timestamp":"%s","message":{"content":[{"type":"text","text":"%s"},{"type":"tool_use","name":"Bash","input":{}}]}}\n' "$1" "$(now)" "$2"; }

# --- test 1: preamble + tool call must stay silent (the Stop-event race) ----
echo "test 1: mid-turn preamble followed by a tool call does not fire the gate"
R1="$TDIR/root1"; T1="$TDIR/t1.jsonl"
{ e_user u1 "do the thing"
  e_tooluse a1 "Quick check on X before answering."
} > "$T1"
run_hook "$T1" "$R1"
if ls "$R1/queue/"*.m4a >/dev/null 2>&1; then bad "queue has audio; the preamble was spoken"
else ok "no audio queued"; fi
grep -q "no fresh text after polling" "$R1/hook.log" 2>/dev/null \
  && ok "hook logged the silent exit" || bad "expected 'no fresh text after polling' in hook.log"

# --- test 2: multi-entry turn gathers every text entry (the 8/11 bug) -------
echo "test 2: a multi-entry turn speaks all assistant text entries, not just the last"
R2="$TDIR/root2"; T2="$TDIR/t2.jsonl"
{ e_user u1 "do the thing"
  e_text a1 "First part."
  e_tooluse a2 ""
  e_toolresult u2
  e_text a3 "Second part."
} > "$T2"
run_hook "$T2" "$R2"
J2=$(ls "$R2/queue/"*.json 2>/dev/null | head -1)
if [ -n "$J2" ]; then
  GOT=$(jq -r .text "$J2")
  WANT=$'First part.\n\nSecond part.'   # entries join with a blank line; the cleaner collapses spaces per line, never newlines
  if [ "$GOT" = "$WANT" ]; then ok "gathered both entries"
  else bad "text is '$GOT', expected both entries joined by a blank line"; fi
else bad "no queue manifest produced"; fi

# --- test 3a: fully-seen turn stays silent on a re-fired Stop ---------------
echo "test 3a: a turn whose final uuid is already in .seen is not re-spoken"
R3="$TDIR/root3"; mkdir -p "$R3"
printf 'a3' > "$R3/.seen-$SID"
run_hook "$T2" "$R3"
if ls "$R3/queue/"*.m4a >/dev/null 2>&1; then bad "re-spoke an already-seen turn"
else ok "stayed silent"; fi

# --- test 3b: resumed turn (meta injection, no real user msg) speaks ONLY the new text
echo "test 3b: a resumed turn speaks only entries after the .seen boundary"
R4="$TDIR/root4"; T4="$TDIR/t4.jsonl"; mkdir -p "$R4"
printf 'a3' > "$R4/.seen-$SID"
{ cat "$T2"
  e_metauser m1
  e_text a4 "Fourth part."
} > "$T4"
run_hook "$T4" "$R4"
J4=$(ls "$R4/queue/"*.json 2>/dev/null | head -1)
if [ -n "$J4" ]; then
  GOT=$(jq -r .text "$J4")
  if [ "$GOT" = "Fourth part." ]; then ok "spoke only the post-seen entry"
  else bad "text is '$GOT', expected 'Fourth part.' — the 8/12 repeat bug is back"; fi
else bad "no queue manifest produced for the resumed turn"; fi

# --- test 4: the queue contract ---------------------------------------------
echo "test 4: queue contract — <epoch>-<sid>.m4a + full manifest"
A2=$(ls "$R2/queue/"*.m4a 2>/dev/null | head -1)
if [ -n "$A2" ] && basename "$A2" | grep -Eq "^[0-9]{10}-${SID}\.m4a$"; then
  ok "audio filename matches <epoch>-<sid>.m4a"
else bad "audio filename '$(basename "${A2:-none}")' violates the contract"; fi
if [ -n "${J2:-}" ] && jq -e 'has("session") and has("project") and has("title") and has("preview") and has("text") and (.created|type=="number")' "$J2" >/dev/null 2>&1; then
  ok "manifest carries session/project/title/preview/text/created"
else bad "manifest is missing contract fields"; fi
if [ -n "${J2:-}" ] && [ "$(jq -r .project "$J2")" = "myproject" ]; then
  ok "project field derives from cwd"
else bad "project field wrong"; fi

echo
echo "hook tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
