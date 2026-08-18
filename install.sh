#!/bin/bash
# Build SpeakySpeak and install the whole pipeline: app + Claude Code hooks.
# Idempotent — run it again after pulling changes.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

# Remember where this clone lives so the app's Updater can `git pull` +
# re-run this script from the menu ("Update to X…"). Deleting the clone
# doesn't break the app — the updater falls back to opening the repo page.
defaults write com.adamraabe.SpeakySpeak srcPath -string "$PWD"

mkdir -p "$HOME/.claude/hooks"
cp hooks/speak-reply.sh hooks/session-end.sh hooks/tts-daemon.py "$HOME/.claude/hooks/"
chmod +x "$HOME/.claude/hooks/speak-reply.sh" "$HOME/.claude/hooks/session-end.sh" "$HOME/.claude/hooks/tts-daemon.py"
echo "Installed hooks to ~/.claude/hooks/"

# Warm TTS daemon: loads Kokoro once and stays resident so each reply renders in
# ~0.5s instead of ~3s cold. Only when mlx-audio is installed; the hook falls
# back to the cold CLI (and then `say`) whenever the daemon isn't answering, so
# this stays a pure speedup. LaunchAgent keeps it alive across crashes/login.
SHIM="$HOME/.local/bin/mlx_audio.tts.generate"
LABEL="com.adamraabe.speakyspeak-tts"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
if [ -x "$SHIM" ]; then
  # Pre-cache the voice the hook will actually request BEFORE the daemon starts:
  # the daemon runs with HF_HUB_OFFLINE=1 and can never fetch a missing voice
  # itself, so an uncached voice means every first render fails to the cold CLI
  # (Sasha's install report 2026-08-17, Defect 1). This render also pulls the
  # model on a truly fresh machine. Voice default: bf_lily (5 sync points, grep it).
  VOICE=$(cat "$HOME/.claude/speak-voice-kokoro" 2>/dev/null || echo "bf_lily")
  if ! ls "$HOME/.cache/huggingface/hub/models--prince-canuma--Kokoro-82M/snapshots"/*/voices/"$VOICE".safetensors >/dev/null 2>&1; then
    echo "Caching Kokoro voice '$VOICE' (first time may also download the ~350MB model)..."
    "$SHIM" --model mlx-community/Kokoro-82M-bf16 --voice "$VOICE" \
      --text "Voice ready." --file_prefix /tmp/speaky-precache --join_audio >/dev/null 2>&1 \
      && rm -f /tmp/speaky-precache*.wav \
      || echo "WARNING: could not cache voice '$VOICE' — first replies will use the slower cold render until it succeeds online."
  fi
  PYBIN=$(head -1 "$SHIM" | sed 's/^#!//')
  mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
  cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>$PYBIN</string>
    <string>$HOME/.claude/hooks/tts-daemon.py</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>EnvironmentVariables</key><dict>
    <key>HF_HUB_OFFLINE</key><string>1</string>
    <key>HF_HUB_DISABLE_TELEMETRY</key><string>1</string>
    <key>TOKENIZERS_PARALLELISM</key><string>false</string>
  </dict>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/speakyspeak-tts.out.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/speakyspeak-tts.err.log</string>
</dict></plist>
PL
  DOMAIN="gui/$(id -u)"
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  # bootout is async — if the old registration hasn't fully drained, an
  # immediate re-bootstrap fails and the daemon silently stays down
  # (bit us 2026-07-20). Wait it out, retry, then VERIFY.
  for _ in $(seq 1 10); do
    launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break
    sleep 0.5
  done
  loaded=0
  for _ in 1 2 3; do
    launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null && { loaded=1; break; }
    sleep 2
  done
  [ "$loaded" = 1 ] || launchctl load "$PLIST" 2>/dev/null || true
  # trust nothing: confirm launchd actually has it running
  ok=0
  for _ in $(seq 1 20); do
    launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -q 'state = running' && { ok=1; break; }
    sleep 0.5
  done
  if [ "$ok" = 1 ]; then
    echo "Warm TTS daemon running ($LABEL); model warms in the background (~20s)."
  else
    echo "WARNING: TTS daemon is NOT running — replies will fall back to the slow cold render."
    echo "Load it manually:  launchctl bootstrap $DOMAIN \"$PLIST\""
  fi
else
  echo "mlx-audio not installed — skipping warm TTS daemon (say fallback stays)."
fi

cat <<'EOF'

If this is a first install, wire the hooks in ~/.claude/settings.json:

  "hooks": {
    "Stop": [{ "matcher": "*", "hooks": [
      { "type": "command", "command": "bash ~/.claude/hooks/speak-reply.sh",
        "timeout": 600, "async": true }
    ]}],
    "SessionEnd": [{ "matcher": "*", "hooks": [
      { "type": "command", "command": "bash ~/.claude/hooks/session-end.sh" }
    ]}]
  }

Optional knobs (plain files):
  ~/.claude/speak-off    hard kill — replies aren't rendered at all
  ~/.claude/speak-rate   words per minute; absent = voice's natural pace
  ~/.claude/speak-voice  say voice; absent = best installed voice is auto-probed
EOF
