#!/bin/bash
# verify.sh — the releasability gate. Green or you do not ship.
#
# Run it before any release (human or loop). The feedback loop's execution
# mode refuses to ship on anything but a clean exit here (PLAN-LAUNCH.md
# §2.4/§2.5). Steps, in order of cheapness:
#   1. shell + python syntax on the hooks
#   2. ./build.sh — the single-file swiftc compile
#   3. the four hook-contract fixture tests (tests/run-hook-tests.sh) — the
#      contracts that have historically regressed; ~70s, silence-is-pass
#      windows included
#   4. every ```json block in INSTALL.md parses (the copy-paste settings
#      snippet must never ship malformed)
#   5. launch smoke: the built app stays alive 5s and leaves no fresh crash
#      report. Skipped when SpeakySpeak is already running (we never quit a
#      live deck out from under the user).
set -u
cd "$(dirname "$0")"
FAILED=0
step() { echo; echo "=== $1 ==="; }
res() { if [ "$1" -eq 0 ]; then echo "--- PASS: $2"; else echo "--- FAIL: $2"; FAILED=1; fi }

step "1. syntax: hooks + daemon"
bash -n hooks/speak-reply.sh;                    res $? "bash -n speak-reply.sh"
[ -f hooks/session-end.sh ] && { bash -n hooks/session-end.sh; res $? "bash -n session-end.sh"; }
if [ -f hooks/tts-daemon.py ]; then python3 -m py_compile hooks/tts-daemon.py; res $? "py_compile tts-daemon.py"; fi

step "2. build"
./build.sh > /tmp/speakyspeak-verify-build.log 2>&1
res $? "build.sh (log: /tmp/speakyspeak-verify-build.log)"

step "3. hook-contract fixture tests"
bash tests/run-hook-tests.sh
res $? "tests/run-hook-tests.sh"

step "4. INSTALL.md JSON blocks parse"
JB=0; JBAD=0
while IFS= read -r block; do
  JB=$((JB+1))
  # A block may be a full document or a deliberate merge-fragment
  # ("hooks": {...} to paste inside settings.json) — wrap fragments in
  # braces before judging them.
  printf '%s' "$block" | python3 -c '
import json,sys
raw=sys.stdin.read().replace("\x01","\n")
try:
    json.loads(raw)
except json.JSONDecodeError:
    json.loads("{"+raw+"}")' || JBAD=$((JBAD+1))
done < <(awk '/^```json/{f=1;b="";next} /^```/{if(f){print b;f=0};next} f{b=b $0 "\x01"}' INSTALL.md)
echo "checked $JB json block(s), $JBAD bad"
[ "$JB" -gt 0 ] && [ "$JBAD" -eq 0 ]; res $? "INSTALL.md json blocks"

step "5. launch smoke"
if pgrep -x SpeakySpeak >/dev/null 2>&1; then
  echo "SpeakySpeak is already running — not quitting a live deck; smoke SKIPPED"
  echo "--- PASS: launch smoke (skipped: app in use)"
else
  BEFORE=$(ls ~/Library/Logs/DiagnosticReports 2>/dev/null | grep -c SpeakySpeak)
  open "$HOME/Applications/SpeakySpeak.app"
  sleep 5
  ALIVE=0; pgrep -x SpeakySpeak >/dev/null 2>&1 && ALIVE=1
  AFTER=$(ls ~/Library/Logs/DiagnosticReports 2>/dev/null | grep -c SpeakySpeak)
  osascript -e 'quit app "SpeakySpeak"' >/dev/null 2>&1
  [ "$ALIVE" -eq 1 ] && [ "$AFTER" -le "$BEFORE" ]
  res $? "app alive after 5s, no new crash report (alive=$ALIVE crashes:$BEFORE->$AFTER)"
fi

step "6. docs in sync"
# Docs rot silently: the site advertised per-row reorder chevrons for hours
# after they were deleted, and claimed "never mid-turn noise" after the
# as-it-works modes shipped (both caught by hand 2026-08-23, which is why this
# step exists). These are the checks a machine can actually make; the judgment
# calls still belong to whoever ships. Keep RETIRED growing as features go.
DOCS="README.md INSTALL.md GUIDE.md CHANGELOG.md site/index.html"
DFAIL=0

# every doc a doc links to must exist
for f in $DOCS; do
  for link in $(grep -oE '\]\(([A-Z][A-Za-z]*\.md)\)' "$f" 2>/dev/null | tr -d '])(' ); do
    [ -f "$link" ] || { echo "  $f links to missing $link"; DFAIL=$((DFAIL+1)); }
  done
done

# the release notes must mention the version we are about to ship
V=$(cat VERSION)
grep -q "^## $V " CHANGELOG.md || { echo "  CHANGELOG.md has no '## $V' entry"; DFAIL=$((DFAIL+1)); }

# phrases describing things the app no longer does
while IFS='|' read -r pat why; do
  [ -z "$pat" ] && continue
  for f in $DOCS; do
    grep -qi -- "$pat" "$f" 2>/dev/null && { echo "  $f still says '$pat' ($why)"; DFAIL=$((DFAIL+1)); }
  done
done <<'RETIRED'
move up or down|per-row reorder chevrons were removed in 1.2.0
play earlier|per-row reorder chevrons were removed in 1.2.0
never mid-turn noise|the as-it-works read modes shipped in 1.1.x
Order groups|the group-order control was cut before 1.2.0 shipped
Project or repo|grouping by project was cut before 1.2.0 shipped
RETIRED

# the guide has to actually cover what Adam asked it to cover
for must in "showMessageTimestamps" "speak-when" "Group by" "hi@speakyspeak.com"; do
  grep -q -- "$must" GUIDE.md || { echo "  GUIDE.md no longer mentions $must"; DFAIL=$((DFAIL+1)); }
done

echo "docs checked: $(echo $DOCS | wc -w | tr -d ' ') file(s), $DFAIL problem(s)"
[ "$DFAIL" -eq 0 ]; res $? "docs in sync"

echo
if [ "$FAILED" -eq 0 ]; then echo "VERIFY: ALL GREEN"; exit 0
else echo "VERIFY: FAILED"; exit 1; fi
