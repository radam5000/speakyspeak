#!/bin/bash
# Does a reply stay quiet while another app has the microphone on?
#
# MacWhisper silences the Mac while it records, so a reply that sounds then is
# lost (Adam, 2026-11-22). This launches a COPY of the built app with its own
# bundle id and queue folder (like run-pause-relaunch-test.sh), with silent
# audio, and fakes "another app has the mic" with SPEAKYSPEAK_TEST_MIC (a file
# whose presence counts as a mic in use). It reads the copy's deck.log:
#
#   1. a reply is speaking, the mic goes on -> it pauses within half a second;
#      a reply arriving meanwhile waits; the mic goes off -> it carries on
#   2. the mic is already on when a fresh reply would start -> it is held
#      before a sound; the mic goes off -> it starts
#   3. the mic is on and you press play -> it plays and stays playing
#      to its end, however often the mic comes and goes; the next reply waits,
#      and a pause by hand re-arms the dictation pause (Adam, 11/24)
#   4. the deck is idle (nothing reads the mic then), the mic is on, and the
#      first press of play plays at once
#   6. a reply held before it starts brings the mini player up after about 10 s
#   5. a pause made by hand while the mic is on stays a pause when it goes off
#
#   tests/run-mic-test.sh [path/to/SpeakySpeak.app]
set -u
cd "$(dirname "$0")/.."
APP=${1:-SpeakySpeak.app}
ID=com.adamraabe.SpeakySpeak.mictest
TMP=$(mktemp -d)
cleanup() {
  [ -n "${PID:-}" ] && kill "$PID" 2>/dev/null
  defaults delete "$ID" >/dev/null 2>&1
  rm -rf "$TMP"
}
trap cleanup EXIT
FAILS=0
check() { if [ "$1" -eq 0 ]; then echo "  ok    $2"; else echo "  FAIL  $2"; FAILS=$((FAILS+1)); fi; }
waitfor() { for _ in $(seq 1 40); do grep -q "$2" "$1/deck.log" 2>/dev/null && return 0; sleep 0.1; done; return 1; }

[ -x "$APP/Contents/MacOS/SpeakySpeak" ] || { echo "FAIL: no built app at $APP (run ./build.sh --no-install)"; exit 1; }
cp -R "$APP" "$TMP/Test.app"
/usr/libexec/PlistBuddy -c "Set CFBundleIdentifier $ID" "$TMP/Test.app/Contents/Info.plist"
codesign --force --deep -s - "$TMP/Test.app" >/dev/null 2>&1
ffmpeg -loglevel error -f lavfi -i anullsrc=r=24000:cl=mono -t 30 -c:a aac "$TMP/silence.m4a" || { echo "FAIL: ffmpeg"; exit 1; }
defaults write "$ID" rate -float 1.0

reply() {   # root id created session
  mkdir -p "$1/queue"
  cp "$TMP/silence.m4a" "$1/queue/$2.m4a"
  printf '{"session":"%s","project":"test","title":"test","preview":"p","text":"t","created":%s}\n' "$4" "$3" > "$1/queue/$2.json"
}
launch() {  # root
  SPEAKYSPEAK_TEST_MIC="$1/mic" SPEAKYSPEAK_TEST_PRESS="$1/press" SPEAKYSPEAK_SPEECH_ROOT="$1" "$TMP/Test.app/Contents/MacOS/SpeakySpeak" >/dev/null 2>&1 &
  PID=$!
}
stop() { kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; PID=; }

NOW=$(date +%s)
echo "1. speaking, then the mic goes on, then off"
R="$TMP/r1"
reply "$R" "$((NOW-5))-aaa" $((NOW-5)) aaa
launch "$R"
waitfor "$R" "playing $((NOW-5))-aaa"; check $? "the fresh reply played"
sleep 3
touch "$R/mic"
waitfor "$R" "paused for the microphone: $((NOW-5))-aaa"; check $? "it paused within a few tenths of a second"
reply "$R" "$((NOW-1))-bbb" $((NOW-1)) aaa
sleep 1.5
! grep -q "playing $((NOW-1))-bbb" "$R/deck.log"; check $? "a reply that arrived meanwhile waited"
rm "$R/mic"
waitfor "$R" "carrying on with $((NOW-5))-aaa"; check $? "the mic off: it carried on"
stop

echo "2. the mic is already on when a fresh reply would start"
R="$TMP/r2"
mkdir -p "$R"; touch "$R/mic"
reply "$R" "$((NOW-4))-ccc" $((NOW-4)) ccc
launch "$R"
waitfor "$R" "for the microphone: $((NOW-4))-ccc"; check $? "held before it sounded"
sleep 1.5
rm "$R/mic"
waitfor "$R" "carrying on with $((NOW-4))-ccc"; check $? "the mic off: it started"
stop

echo "3. the mic is on and you press play"
R="$TMP/r3"
mkdir -p "$R"; touch "$R/mic"
reply "$R" "$((NOW-3))-ddd" $((NOW-3)) ddd
launch "$R"
waitfor "$R" "for the microphone: $((NOW-3))-ddd"; check $? "held before it sounded"
touch "$R/press"
waitfor "$R" "playing anyway"; check $? "the press of play won"
sleep 1.5
[ "$(tail -1 "$R/deck.log" | grep -c "for the microphone")" = 0 ] && ! sed -n '/playing anyway/,$p' "$R/deck.log" | grep -q "for the microphone"; check $? "it stayed playing with the mic on"
for _ in 1 2; do rm "$R/mic"; sleep 1; touch "$R/mic"; sleep 1.5; done
! grep -q "paused for the microphone" "$R/deck.log"; check $? "the mic off and on twice: that reply keeps playing"
rm "$R/mic"; sleep 1
touch "$R/press"; sleep 1; touch "$R/press"; sleep 1   # paused by hand, then played with the mic off
touch "$R/mic"
waitfor "$R" "paused for the microphone: $((NOW-3))-ddd"; check $? "after a pause by hand the dictation pause works again"
stop

echo "3b. the press covers that reply only"
R="$TMP/r3b"
mkdir -p "$R"; touch "$R/mic"
ffmpeg -loglevel error -y -f lavfi -i anullsrc=r=24000:cl=mono -t 5 -c:a aac "$TMP/short.m4a"
reply "$R" "$((NOW-4))-iii" $((NOW-4)) iii; cp "$TMP/short.m4a" "$R/queue/$((NOW-4))-iii.m4a"
launch "$R"
waitfor "$R" "for the microphone: $((NOW-4))-iii"
touch "$R/press"; waitfor "$R" "playing anyway"; sleep 1
rm "$R/mic"; sleep 1; touch "$R/mic"; sleep 0.5
reply "$R" "$((NOW))-jjj" $NOW jjj
for _ in $(seq 1 12); do grep -q "finished $((NOW-4))-iii" "$R/deck.log" && break; sleep 1; done
grep -q "finished $((NOW-4))-iii" "$R/deck.log"; check $? "it played to the end"
sleep 4
! grep -q "playing $NOW-jjj" "$R/deck.log"; check $? "the next reply waits"
rm "$R/mic"; waitfor "$R" "playing $NOW-jjj"; check $? "and plays when the mic goes off"
stop

echo "3c. who holds it"
R="$TMP/r3c"
mkdir -p "$R"; echo /System/Library/CoreServices/MediaRemoteUIService.app/Contents/MacOS/MediaRemoteUIService > "$R/mic"
reply "$R" "$((NOW-2))-kkk" $((NOW-2)) kkk
launch "$R"
waitfor "$R" "playing $((NOW-2))-kkk"; sleep 1.5
! grep -q "for the microphone" "$R/deck.log"; check $? "the Now Playing helper never pauses a reply"
rm "$R/mic"; sleep 0.6; echo /usr/libexec/replayd > "$R/mic"
waitfor "$R" "paused for the microphone"; check $? "a screen recording does"
for _ in $(seq 1 13); do grep -q "long wait" "$R/deck.log" && break; sleep 1; done
grep -q "Waiting: a screen recording is using the microphone" "$R/deck.log"; check $? "and is called a screen recording"
stop

echo "4. idle, the mic comes on, and the first press of play"
R="$TMP/r4"
reply "$R" "$((NOW-900))-eee" $((NOW-900)) eee   # old: restored silent, nothing tries to start it
launch "$R"
waitfor "$R" "queued $((NOW-900))-eee\|restored\|quiet hotkey"; sleep 2
! grep -q "playing $((NOW-900))-eee" "$R/deck.log"; check $? "an old backlog stays silent on its own"
touch "$R/mic"; sleep 1   # idle: nothing is reading the mic when it comes on
touch "$R/press"
waitfor "$R" "playing $((NOW-900))-eee"; check $? "the first press played it"
sleep 1.5
! grep -q "for the microphone" "$R/deck.log"; check $? "and nothing held it"
stop

echo "5. paused by hand while the mic is on"
R="$TMP/r5"
reply "$R" "$((NOW-900))-fff" $((NOW-900)) fff   # an old backlog, silent by design
reply "$R" "$((NOW-2))-ggg" $((NOW-2)) ggg
launch "$R"
waitfor "$R" "playing"; sleep 1
touch "$R/mic"; waitfor "$R" "paused for the microphone"; check $? "the mic paused the reply"
touch "$R/press"; waitfor "$R" "playing anyway"; sleep 0.5
touch "$R/press"; sleep 1     # paused by hand now
N=$(grep -c " playing \| carrying on\| resume" "$R/deck.log")
rm "$R/mic"; waitfor "$R" "microphone off"; sleep 2
[ "$(grep -c " playing \| carrying on\| resume" "$R/deck.log")" = "$N" ]; check $? "a pause made by hand stayed a pause"
stop

echo "6. a reply held before it starts says why once the wait is long"
R="$TMP/r6"
mkdir -p "$R/queue"
launch "$R"
waitfor "$R" "quiet hotkey"; sleep 0.5
touch "$R/mic"
reply "$R" "$((NOW))-hhh" $NOW hhh
waitfor "$R" "autoplay held: the microphone is on"; check $? "the reply was held"
sleep 4
! grep -q "long wait" "$R/deck.log"; check $? "a short wait shows nothing"
for _ in $(seq 1 10); do grep -q "long wait, showing the mini player" "$R/deck.log" && break; sleep 1; done
grep -q "long wait, showing the mini player: Waiting: test-mic is using the microphone" "$R/deck.log"; check $? "after about 10 s the mini player comes up with the reason"
rm "$R/mic"
waitfor "$R" "playing $NOW-hhh"; check $? "the mic off: it plays"
stop

[ "$FAILS" -eq 0 ] && echo "MIC: ALL GREEN" || { echo "MIC: $FAILS FAILED"; echo "--- r1"; cat "$TMP/r1/deck.log"; echo "--- r2"; cat "$TMP/r2/deck.log"; echo "--- r3"; cat "$TMP/r3/deck.log"; echo "--- r4"; cat "$TMP/r4/deck.log"; echo "--- r5"; cat "$TMP/r5/deck.log"; echo "--- r6"; cat "$TMP/r6/deck.log"; }
[ "$FAILS" -eq 0 ]
