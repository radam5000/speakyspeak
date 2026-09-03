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

run_post() {  # $1 = transcript, $2 = speech root, $3 = speak-when mode
  printf '%s' "$3" > "$THOME/.claude/speak-when"
  printf '{"transcript_path":"%s","session_id":"%s","cwd":"%s","hook_event_name":"PostToolUse","tool_name":"Bash"}' \
    "$1" "$SID_FULL" "$PROJ" \
    | env HOME="$THOME" PATH="$STUB:$PATH" SPEAKYSPEAK_SPEECH_ROOT="$2" bash "$HOOK"
  rm -f "$THOME/.claude/speak-when"
}

# Replies open with a "[H:MM am] " stamp since 2026-09-03 (prompts do not);
# the tests compare the words, so strip it here.
untime() { sed -E '1s/^\[[0-9]+:[0-9][0-9] [ap]m\] //'; }
qtext() {  # $1 = speech root -> the text of the single queued manifest, or ""
  local j; j=$(ls "$1/queue/"*.json 2>/dev/null | head -1)
  [ -n "$j" ] && jq -r .text "$j" | untime
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
  GOT=$(jq -r .text "$J2" | untime)
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
  GOT=$(jq -r .text "$J4" | untime)
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

# --- test 5: mid-run speech is OFF by default ------------------------------
# The PostToolUse registration ships wired but inert: with no speak-when file
# (or "end"), a tool call must produce absolute silence. This is what makes the
# feature safe to install for everyone.
echo "test 5: PostToolUse stays silent in the default \"end\" mode"
R5="$TDIR/root5"; T5="$TDIR/t5.jsonl"
{ e_user u1 "do the thing"
  e_text a1 "This preamble is comfortably longer than the fifteen word floor, so only the mode can be keeping it quiet."
  e_tooluse a2 ""
  e_toolresult u2
} > "$T5"
run_post "$T5" "$R5" "end"
if ls "$R5/queue/"*.m4a >/dev/null 2>&1; then bad "spoke mid-run while mode was end"
else ok "silent in end mode"; fi
[ -f "$R5/.seen-$SID" ] && bad "end mode moved the .seen mark" || ok "left .seen untouched"

# --- test 6: mode=all speaks a mid-run entry -------------------------------
echo "test 6: PostToolUse in \"all\" mode speaks the mid-run entry"
R6="$TDIR/root6"
run_post "$T5" "$R6" "all"
if [ "$(qtext "$R6")" = "This preamble is comfortably longer than the fifteen word floor, so only the mode can be keeping it quiet." ]; then
  ok "spoke the mid-run entry"
else bad "text is '$(qtext "$R6")'"; fi

# --- test 7: THE GUARD — mid-run must never swallow the final reply --------
# This hook runs async, so the turn's real answer can land in the transcript
# while it is still rendering. If the mid-run path spoke or .seen-marked that
# answer, Stop would skip it and the reply would never be read aloud at all.
# Only text already followed by a tool call is eligible.
echo "test 7: a final reply present in the transcript is not taken by the mid-run path"
R7="$TDIR/root7"; T7="$TDIR/t7.jsonl"
{ cat "$T5"
  e_text a3 "THE FINAL ANSWER."
} > "$T7"
run_post "$T7" "$R7" "all"
GOT7=$(qtext "$R7")
case $GOT7 in
  *"THE FINAL ANSWER"*) bad "mid-run path spoke the final reply — Stop would now skip it" ;;
  "") bad "mid-run path went silent; expected the eligible preamble" ;;
  *) ok "spoke only the pre-tool-call text" ;;
esac
[ "$(cat "$R7/.seen-$SID" 2>/dev/null)" = "a3" ] \
  && bad ".seen was advanced onto the final reply" || ok "left the final reply unmarked"

# --- test 8: Stop after a mid-run speak reads the remainder, once ----------
echo "test 8: Stop after a mid-run speak reads only what is left"
run_hook "$T7" "$R7"
N8=$(ls "$R7/queue/"*.json 2>/dev/null | wc -l | tr -d " ")
LAST8=$(ls -t "$R7/queue/"*.json 2>/dev/null | head -1)
if [ "$N8" = "2" ] && [ "$(jq -r .text "$LAST8" | untime)" = "THE FINAL ANSWER." ]; then
  ok "Stop spoke the final reply and nothing else"
else bad "expected 2 queued items ending in the final reply; got $N8, last='$(jq -r .text "$LAST8" 2>/dev/null)'"; fi

# --- test 9: substantial mode drops short filler, keeps the real line ------
echo "test 9: \"substantial\" mode skips the short connective lines"
R9="$TDIR/root9"; T9="$TDIR/t9.jsonl"
{ e_user u1 "do the thing"
  e_text a1 "Still there."
  e_tooluse a2 ""
  e_toolresult u2
  e_text a3 "Double-press the power button a few times now, because the capture is running for about thirty seconds."
  e_tooluse a4 ""
  e_toolresult u3
} > "$T9"
run_post "$T9" "$R9" "substantial"
GOT9=$(qtext "$R9")
case $GOT9 in
  *"Still there"*) bad "short filler was spoken: '$GOT9'" ;;
  *"Double-press the power button"*) ok "kept the instruction, dropped the filler" ;;
  *) bad "text is '$GOT9'" ;;
esac

# --- test 10: a task-notification injection is NOT a turn boundary ---------
# Background subagents finishing mid-turn inject type:"user" entries with
# origin.kind:"task-notification" and string content — no isMeta, no
# tool_result, so they matched realuser and truncated the gather (2026-08-25
# audit: reproduced the 8/11 content-loss class on multi-agent sessions).
e_tasknotify() { printf '{"type":"user","uuid":"%s","timestamp":"%s","promptSource":"system","origin":{"kind":"task-notification"},"message":{"content":"<task-notification>agent done</task-notification>"}}\n' "$1" "$(now)"; }
echo "test 10: a task-notification entry does not truncate the gather"
R10="$TDIR/root10"; T10="$TDIR/t10.jsonl"
{ e_user u1 "do the thing"
  e_text a1 "PART ONE of the answer."
  e_tooluse a2 ""
  e_toolresult u2
  e_tasknotify n1
  e_text a3 "PART TWO of the answer."
} > "$T10"
run_hook "$T10" "$R10"
GOT10=$(qtext "$R10")
WANT10=$'PART ONE of the answer.\n\nPART TWO of the answer.'
if [ "$GOT10" = "$WANT10" ]; then ok "both parts spoken across the injection"
else bad "text is '$GOT10' — the injection was read as a turn boundary"; fi

# --- test 11: concurrent PostToolUse + Stop never share an id ---------------
# Same-second TOCTOU: with the render in flight the final names don't exist
# yet, so both hooks used to claim the same stamp and one reply silently
# overwrote the other (~coin flip at <0.15s spacing, reproduced 2026-08-25).
# A slow say stub holds the render open so the two runs genuinely overlap.
echo "test 11: overlapping mid-run and Stop hooks queue two distinct items"
SLOW="$TDIR/slowbin"; mkdir -p "$SLOW"
cat > "$SLOW/say" <<'EOF'
#!/bin/bash
out=""
while [ $# -gt 0 ]; do
  [ "$1" = "-o" ] && { out="$2"; shift; }
  shift
done
cat > /dev/null
sleep 2
[ -n "$out" ] && printf 'FAKEAUDIO' > "$out"
EOF
chmod +x "$SLOW/say"
R11="$TDIR/root11"
printf 'all' > "$THOME/.claude/speak-when"
printf '{"transcript_path":"%s","session_id":"%s","cwd":"%s","hook_event_name":"PostToolUse","tool_name":"Bash"}' \
  "$T7" "$SID_FULL" "$PROJ" \
  | env HOME="$THOME" PATH="$SLOW:$STUB:$PATH" SPEAKYSPEAK_SPEECH_ROOT="$R11" bash "$HOOK" &
MID_PID=$!
sleep 0.1
printf '{"transcript_path":"%s","session_id":"%s","cwd":"%s"}' "$T7" "$SID_FULL" "$PROJ" \
  | env HOME="$THOME" PATH="$SLOW:$STUB:$PATH" SPEAKYSPEAK_SPEECH_ROOT="$R11" bash "$HOOK"
wait "$MID_PID"
rm -f "$THOME/.claude/speak-when"
N11=$(ls "$R11/queue/"*.json 2>/dev/null | wc -l | tr -d " ")
if [ "$N11" = "2" ]; then ok "two items survived the overlap"
else bad "expected 2 queued items, got $N11 — an id collision ate a reply"; fi
DUP11=0
for j in "$R11/queue/"*.json; do
  case $(jq -r .text "$j" 2>/dev/null | untime) in
    "THE FINAL ANSWER.") : ;;
    *"THE FINAL ANSWER"*) DUP11=1 ;;   # Stop re-gathered the mid-run text too
  esac
done
[ "$DUP11" = 0 ] && ok "Stop spoke only the remainder (fresh .seen re-read)" \
  || bad "Stop re-spoke the mid-run text — stale .seen snapshot"

# --- test 12: a failed render does not permanently consume the reply --------
echo "test 12: after a say failure, the next Stop can still speak the reply"
FAILBIN="$TDIR/failbin"; mkdir -p "$FAILBIN"
printf '#!/bin/bash\ncat > /dev/null\nexit 1\n' > "$FAILBIN/say"
chmod +x "$FAILBIN/say"
R12="$TDIR/root12"; T12="$TDIR/t12.jsonl"
{ e_user u1 "do the thing"
  e_text a1 "The important answer."
} > "$T12"
printf '{"transcript_path":"%s","session_id":"%s","cwd":"%s"}' "$T12" "$SID_FULL" "$PROJ" \
  | env HOME="$THOME" PATH="$FAILBIN:$STUB:$PATH" SPEAKYSPEAK_SPEECH_ROOT="$R12" bash "$HOOK"
if ls "$R12/queue/"*.m4a >/dev/null 2>&1; then bad "queued audio from a failing renderer"
else ok "failed render queued nothing"; fi
run_hook "$T12" "$R12"
if [ "$(qtext "$R12")" = "The important answer." ]; then ok "reply recovered on the next Stop"
else bad "reply lost for good: .seen was not rolled back on failure"; fi

# --- test 13: a reply that is entirely a code block queues nothing ----------
# Real `say` renders empty stdin into a valid silent m4a, so this used to
# queue a playable empty row. .seen must still advance: an unspeakable reply
# is skipped by decision, and without the mark every later Stop would re-poll it.
echo "test 13: code-block-only reply is skipped, marked seen, no phantom item"
R13="$TDIR/root13"; T13="$TDIR/t13.jsonl"
{ e_user u1 "do the thing"
  e_text a1 '```\nrm -rf build && make\n```'
} > "$T13"
run_hook "$T13" "$R13"
if ls "$R13/queue/"*.m4a >/dev/null 2>&1; then bad "phantom silent item queued"
else ok "nothing queued"; fi
grep -q "nothing speakable after cleaning" "$R13/hook.log" 2>/dev/null \
  && ok "hook logged the deliberate skip" || bad "expected 'nothing speakable' in hook.log"
[ "$(cat "$R13/.seen-$SID" 2>/dev/null)" = "a1" ] \
  && ok ".seen advanced past the skipped reply" || bad ".seen not advanced — later Stops will re-poll this reply"

# --- test 14: a permission prompt is chimed and spoken, never .seen-marked --
# Notification hooks carry no transcript text; the prompt must queue as a
# normal item whose text names the session and repeats Claude Code's message,
# and must leave .seen alone (it is not a reply). Any other notification_type
# stays silent, and the chime plays even when the deck would not.
echo "test 14: Notification permission_prompt is spoken with a chime, other types stay silent"
R14="$TDIR/root14"
run_notify() {  # $1 = notification_type, $2 = speech root
  printf '{"session_id":"%s","cwd":"%s","session_title":"finance sweep","hook_event_name":"Notification","notification_type":"%s","title":"Permission needed","message":"Claude needs your permission to use Bash"}' \
    "$SID_FULL" "$PROJ" "$1" \
    | env HOME="$THOME" PATH="$STUB:$PATH" SPEAKYSPEAK_SPEECH_ROOT="$2" bash "$HOOK"
}
run_notify permission_prompt "$R14"
if [ "$(qtext "$R14")" = "Waiting on you in finance sweep. Claude needs your permission to use Bash" ]; then ok "prompt queued with session name + message"
else bad "prompt text wrong: '$(qtext "$R14")'"; fi
[ -e "$R14/.seen-$SID" ] && bad ".seen written by a prompt" || ok ".seen untouched"
R14b="$TDIR/root14b"
run_notify auth_success "$R14b"
if ls "$R14b/queue/"*.m4a >/dev/null 2>&1; then bad "auth_success notification was spoken"
else ok "unrelated notification type stays silent"; fi

echo
echo "hook tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
