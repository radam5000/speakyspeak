#!/bin/bash
# Regenerate the staged app screenshots behind the site's /howto figures (and
# any future README/site shots) after a UI change. No mouse, no live-deck
# impact: each scene launches a second, isolated app instance
# (SPEAKYSPEAK_SPEECH_ROOT) seeded with canned demo content (SPEAKYSPEAK_DEMO;
# see seedDemo in main.swift) and captures its real windows.
#
# Usage:  ./build.sh && ./scripts/screenshots.sh [outdir]
# Scenes: deck+grouped, deck+flat (popover pinned open), hud (mini player),
#         settings. Crop boxes and the /howto data-URI re-inlining recipe live
#         in site/howto's git history (commit 6f639ce and after).
#
# Demo cast rule: the sessions in seedDemo are the site's home-screen trio
# (everething / events-site / markemark). Never let real or private content
# into the staged pixels — Adam, 2026-08-25.
set -euo pipefail
OUT="${1:-/tmp/ss-demo/shots}"
ROOT="$(mktemp -d /tmp/ss-shot-root.XXXX)"
APP="$HOME/Applications/SpeakySpeak.app/Contents/MacOS/SpeakySpeak"
[ -x "$APP" ] || { echo "no installed app — run ./build.sh first"; exit 1; }
mkdir -p "$OUT"

capture_scene() {
  local SCENE="$1" SORT="${2:-}"
  SPEAKYSPEAK_DEMO="$SCENE" SPEAKYSPEAK_DEMO_SORT="$SORT" \
    SPEAKYSPEAK_SPEECH_ROOT="$ROOT" "$APP" >/dev/null 2>&1 &
  local PID=$!
  sleep 3
  swift -e '
import CoreGraphics; import Foundation
let pid = Int(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in list where (w["kCGWindowOwnerPID"] as? Int) == pid {
    let b = w["kCGWindowBounds"] as! [String: Any]
    print("\(w["kCGWindowNumber"]!) \(b["Width"]!)x\(b["Height"]!)")
}' "$PID" 2>/dev/null | while read -r NUM SIZE; do
    screencapture -l "$NUM" -o -x "$OUT/${SCENE}${SORT:+-$SORT}-$SIZE.png"
    echo "captured $SCENE${SORT:+-$SORT} $SIZE -> $OUT"
  done
  kill "$PID" 2>/dev/null || true
}

capture_scene deck grouped
capture_scene deck flat
capture_scene hud
capture_scene settings
rm -rf "$ROOT"
echo "done: $(ls "$OUT" | wc -l | tr -d ' ') file(s) in $OUT"
