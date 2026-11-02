#!/bin/bash
# Does a pause survive a relaunch?
#
# An update or a reinstall relaunches the deck. Before 1.2.27 the pause lived
# only in the audio player, so the relaunched deck forgot it and a reply that
# had arrived in the last 2 minutes played by itself (twice on 2026-10-20).
# This launches a COPY of the built app with its own bundle id (so its
# preferences never touch the real app's) and its own queue folder
# (SPEAKYSPEAK_SPEECH_ROOT), with silent audio, and reads its deck.log:
#
#   1. paused before the relaunch + a fresh reply -> the paused reply comes back
#      paused at its spot and nothing plays
#   2. the saved pause names a reply that is gone -> it is forgotten and the
#      fresh reply plays as before (a relaunch with no pause is unchanged)
#   3. playback was on the iPhone -> the Mac restores nothing and stays quiet
#
# It runs beside a live deck: the copy's peer and phone listeners cannot take
# the live deck's ports, and a second menu-bar mark shows for a few seconds.
#
#   tests/run-pause-relaunch-test.sh [path/to/SpeakySpeak.app]
set -u
cd "$(dirname "$0")/.."
APP=${1:-SpeakySpeak.app}
ID=com.adamraabe.SpeakySpeak.pausetest
TMP=$(mktemp -d)
cleanup() {
  [ -n "${PID:-}" ] && kill "$PID" 2>/dev/null
  defaults delete "$ID" >/dev/null 2>&1
  rm -rf "$TMP"
}
trap cleanup EXIT
FAILS=0
check() { if [ "$1" -eq 0 ]; then echo "  ok    $2"; else echo "  FAIL  $2"; FAILS=$((FAILS+1)); fi; }

[ -x "$APP/Contents/MacOS/SpeakySpeak" ] || { echo "FAIL: no built app at $APP (run ./build.sh --no-install)"; exit 1; }
cp -R "$APP" "$TMP/Test.app"
/usr/libexec/PlistBuddy -c "Set CFBundleIdentifier $ID" "$TMP/Test.app/Contents/Info.plist"
codesign --force --deep -s - "$TMP/Test.app" >/dev/null 2>&1
ffmpeg -loglevel error -f lavfi -i anullsrc=r=24000:cl=mono -t 20 -c:a aac "$TMP/silence.m4a" || { echo "FAIL: ffmpeg"; exit 1; }

# root, id, created(epoch), session
reply() {
  mkdir -p "$1/queue"
  cp "$TMP/silence.m4a" "$1/queue/$2.m4a"
  printf '{"session":"%s","project":"test","title":"test","preview":"p","text":"t","created":%s}\n' "$4" "$3" > "$1/queue/$2.json"
}

run_deck() {   # root
  SPEAKYSPEAK_SPEECH_ROOT="$1" "$TMP/Test.app/Contents/MacOS/SpeakySpeak" >/dev/null 2>&1 &
  PID=$!
  for _ in $(seq 1 40); do grep -q "playing \|autoplay held\|restored " "$1/deck.log" 2>/dev/null && break; sleep 0.25; done
  sleep 3   # the peer check can take 1.2s before an autoplay starts
  kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; PID=
}

NOW=$(date +%s)
echo "1. paused before the relaunch, a fresh reply waiting"
R1="$TMP/r1"
reply "$R1" "$((NOW-600))-aaa" $((NOW-600)) aaa
reply "$R1" "$((NOW-5))-bbb" $((NOW-5)) bbb
defaults write "$ID" pausedReply -dict id "$((NOW-600))-aaa" at -float 6.5
run_deck "$R1"
grep -q "restored $((NOW-600))-aaa paused at 6s" "$R1/deck.log"; check $? "the paused reply came back paused at its spot"
! grep -q "playing " "$R1/deck.log"; check $? "nothing played"
defaults read "$ID" pausedReply >/dev/null 2>&1; check $? "the pause is still remembered"

echo "2. the saved pause names a reply that is gone"
R2="$TMP/r2"
reply "$R2" "$((NOW-5))-ccc" $((NOW-5)) ccc
defaults write "$ID" pausedReply -dict id "gone" at -float 3
run_deck "$R2"
grep -q "saved pause no longer applies" "$R2/deck.log"; check $? "the stale pause was forgotten"
grep -q "playing $((NOW-5))-ccc" "$R2/deck.log"; check $? "the fresh reply played, as before"
! defaults read "$ID" pausedReply >/dev/null 2>&1; check $? "no pause left in its preferences"

echo "3. playing on the iPhone when the Mac relaunches: the phone keeps it"
R3="$TMP/r3"
reply "$R3" "$((NOW-600))-ddd" $((NOW-600)) ddd
reply "$R3" "$((NOW-5))-eee" $((NOW-5)) eee
defaults write "$ID" onPhone -bool true
defaults write "$ID" pausedReply -dict id "$((NOW-600))-ddd" at -float 6.5
run_deck "$R3"
! grep -q "restored " "$R3/deck.log"; check $? "no paused reply pinned on the Mac"
! grep -q "playing " "$R3/deck.log"; check $? "the Mac stayed quiet"

[ "$FAILS" -eq 0 ] && echo "PAUSE RELAUNCH: ALL GREEN" || echo "PAUSE RELAUNCH: $FAILS FAILED"
[ "$FAILS" -eq 0 ]
