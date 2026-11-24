#!/bin/bash
# setup.sh: the whole install in one command. Safe to run again any time; it
# skips what is already there. It asks nothing and needs no Homebrew.
#
#   ./setup.sh               everything
#   ./setup.sh --no-neural   skip the neural voice (about 1.5 GB) and use the macOS voice
#   ./setup.sh --quiet       do not say hello at the end
#
# 1. checks this Mac (scripts/doctor.sh --before) and stops if something is in the way
# 2. installs the neural voice (Apple silicon): uv if missing, then mlx-audio and its model
# 3. builds and installs the app and the hooks (install.sh)
# 4. opens the app and says hello out loud, through the same queue replies use
# 5. checks the result (scripts/doctor.sh)
#
# A voice that fails to install never stops the rest: the macOS voice reads
# replies until a later run gets it. The in-app updater runs install.sh, not this.
set -u
cd "$(dirname "$0")"
NEURAL=1; HELLO=1
for a in "$@"; do case "$a" in
  --no-neural) NEURAL=0 ;; --quiet) HELLO=0 ;;
  -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "unknown option: $a (try --help)"; exit 2 ;;
esac; done
[ "$(id -u)" = 0 ] && { echo "Run this as yourself, without sudo."; exit 2; }
say_step() { echo; echo "== $1"; }

cat <<'T'
SpeakySpeak reads Claude Code's replies aloud, on this Mac.

It needs:  macOS 15.6 or newer, Claude Code, Apple's free command line tools,
           and internet plus about 1.5 GB for the neural voice (Apple silicon).
It adds:   an app in ~/Applications, three scripts in ~/.claude/hooks, four hooks
           in Claude Code's settings (backed up first), and a small voice helper.
To undo:   ./uninstall.sh
T
say_step "1 of 5  Checking this Mac"
bash scripts/doctor.sh --before || exit 1

VOICE_OK=1
say_step "2 of 5  The voice"
BIN="$HOME/.local/bin"; KOKORO="$BIN/mlx_audio.tts.generate"
if [ "$(uname -m)" != arm64 ]; then echo "Intel Mac: using the macOS voice."
elif [ "$NEURAL" = 0 ]; then echo "Skipped (--no-neural): using the macOS voice."
else
  V=$(cat "$HOME/.claude/speak-voice-kokoro" 2>/dev/null || echo bf_lily)
  if [ ! -x "$KOKORO" ]; then
    UV=$(PATH="$BIN:$PATH:/opt/homebrew/bin:/usr/local/bin" command -v uv)
    if [ -z "$UV" ]; then
      echo "Getting uv (it keeps the voice's Python in its own folder; nothing else on this Mac changes)..."
      curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="$BIN" UV_NO_MODIFY_PATH=1 sh >/tmp/speakyspeak-uv.log 2>&1
      UV="$BIN/uv"
    fi
    if [ -x "$UV" ]; then
      echo "Getting the neural voice (about 1 GB, a few minutes)..."
      # pinned: 0.4.4 renders long text wrong (mlx-audio issue 784). The date
      # freezes everything it depends on to a set that was installed from
      # nothing and spoke; move it only after doing that again.
      "$UV" tool install --python 3.12 --exclude-newer 2026-11-23 "mlx-audio[tts]==0.4.1" --with "misaki[en]" \
        --with "en_core_web_sm @ https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl" \
        >/tmp/speakyspeak-voice.log 2>&1 || VOICE_OK=0
    else VOICE_OK=0; fi
  fi
  # the model and the voice have to be on disk before the always-on helper
  # starts, because it runs offline
  if [ "$VOICE_OK" = 1 ] && [ -x "$KOKORO" ]; then
    echo "Trying it out (the first time downloads the model, about 350 MB)..."
    T=$(mktemp -d)
    "$KOKORO" --model mlx-community/Kokoro-82M-bf16 --voice "$V" --join_audio \
      --file_prefix "$T/try" --text "Voice ready." >>/tmp/speakyspeak-voice.log 2>&1
    [ -s "$T/try.wav" ] && echo "The neural voice works." || VOICE_OK=0
    rm -rf "$T"
  else VOICE_OK=0; fi
  [ "$VOICE_OK" = 1 ] || echo "The neural voice did not install (details: /tmp/speakyspeak-voice.log). The macOS voice reads replies for now; run ./setup.sh again later to retry."
fi

say_step "3 of 5  Building and installing the app"
if ! ./install.sh >/tmp/speakyspeak-install.log 2>&1; then
  echo "This step failed. The last lines of /tmp/speakyspeak-install.log:"; tail -15 /tmp/speakyspeak-install.log; exit 1
fi
grep -E '^(Installed|Registered|Claude Code hooks|Could not|NOTE|Warm TTS|WARNING)' /tmp/speakyspeak-install.log

say_step "4 of 5  Saying hello"
open "$HOME/Applications/SpeakySpeak.app" || { echo "The app did not open."; exit 1; }
for _ in $(seq 1 40); do pgrep -x SpeakySpeak >/dev/null 2>&1 && break; sleep 0.25; done
Q="${SPEAKYSPEAK_SPEECH_ROOT:-/tmp/claude-speech}/queue"; mkdir -p "$Q"
if [ "$HELLO" = 1 ]; then
  ID="$(date +%s)-setup000"
  TEXT="Hi, I'm SpeakySpeak. From now on I'll read Claude's replies to you, one at a time. Click the S Y in your menu bar to show or hide me."
  T=$(mktemp -d)
  if [ "$VOICE_OK" = 1 ] && [ "$NEURAL" = 1 ] && [ -x "$KOKORO" ]; then
    "$KOKORO" --model mlx-community/Kokoro-82M-bf16 --voice "$V" --join_audio --file_prefix "$T/hi" --text "$TEXT" >/dev/null 2>&1
  fi
  [ -s "$T/hi.wav" ] || say -o "$T/hi.wav" --data-format=LEI16@22050 "$TEXT"
  "$HOME/Applications/SpeakySpeak.app/Contents/MacOS/SpeakySpeak" --encode "$T/hi.wav" "$T/hi.m4a" \
    && mv "$T/hi.m4a" "$Q/$ID.m4a" \
    && jq -n --arg t "$TEXT" --argjson c "$(date +%s)" \
        '{session:"setup000",project:"SpeakySpeak",title:"SpeakySpeak",preview:$t,text:$t,created:$c}' > "$Q/.tmp-$ID.json" \
    && mv "$Q/.tmp-$ID.json" "$Q/$ID.json"
  rm -rf "$T"
  D="${SPEAKYSPEAK_SPEECH_ROOT:-/tmp/claude-speech}/deck.log"; PLAYED=0
  for _ in $(seq 1 40); do grep -aq "playing $ID" "$D" 2>/dev/null && { PLAYED=1; break; }; sleep 0.25; done
  if [ "$PLAYED" = 1 ]; then echo "You should hear it now."
  else echo "It is in the list but has not started (muted, paused, or another app is using the microphone). Click the Sy in the menu bar and press play."; fi
else echo "Skipped (--quiet)."; fi

say_step "5 of 5  Checking the result"
bash scripts/doctor.sh; RC=$?
echo
[ "$RC" = 0 ] && echo "SpeakySpeak is installed. Keep this folder: updates come through it." || echo "Installed, with something left to fix (above)."
exit "$RC"
