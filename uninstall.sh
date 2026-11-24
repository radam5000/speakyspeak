#!/bin/bash
# uninstall.sh: take SpeakySpeak off this Mac. Shows what it would remove;
# does it only with --yes. Other hooks and settings are left alone, and
# settings.json is backed up first.
#   --keep-voice   keep the neural voice (mlx-audio)
set -u
cd "$(dirname "$0")"
YES=0; KEEP=0
for a in "$@"; do case "$a" in --yes) YES=1 ;; --keep-voice) KEEP=1 ;; *) echo "usage: ./uninstall.sh [--yes] [--keep-voice]"; exit 2 ;; esac; done
PATH="$PATH:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin"
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; S="$CFG/settings.json"
LABEL=com.adamraabe.speakyspeak-tts
KNOBS="speak-off speak-quit speak-rate speak-voice speak-voice-kokoro speak-engine speak-when speak-min-words speak-prompt-chime speak-peer speak-phone speak-lead-in speak-name-first speak-headless"
echo "Removes: the app, its three scripts in ~/.claude/hooks, its entries in settings.json,"
echo "the voice helper, its settings (the speak-* files in ~/.claude), and /tmp/claude-speech."
[ "$KEEP" = 0 ] && echo "Also the neural voice (mlx-audio), if nothing else here uses it. --keep-voice keeps it."
[ "$YES" = 1 ] || { echo; echo "Nothing has been removed. To go ahead: ./uninstall.sh --yes"; exit 0; }

# settings.json first: a hook whose script is gone prints an error every turn
if [ -f "$S" ]; then
  T=$(mktemp)
  if jq 'if (.hooks | type) == "object" then
           .hooks |= (with_entries(.value |= (if type == "array" then
               map(if (.hooks | type) == "array"
                   then .hooks |= map(select((.command // "") | test("hooks/(speak-reply|session-end)\\.sh") | not))
                   else . end)
               | map(select((.hooks | type) != "array" or (.hooks | length) > 0)) else . end))
             | with_entries(select((.value | type) != "array" or (.value | length) > 0)))
         else . end' "$S" > "$T" && [ -s "$T" ]; then
    cmp -s <(jq -S . "$S") <(jq -S . "$T") || { cp -p "$S" "$S.before-speakyspeak-uninstall"; cat "$T" > "$S"; echo "settings.json: entries removed (backup: $S.before-speakyspeak-uninstall)"; }
  else echo "settings.json could not be read: take out the entries that name speak-reply.sh and session-end.sh by hand."; fi
  rm -f "$T"
fi
pkill -x SpeakySpeak 2>/dev/null
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/SpeakySpeak.app" "${SPEAKYSPEAK_SPEECH_ROOT:-/tmp/claude-speech}"
rm -f "$HOME/.claude/hooks/speak-reply.sh" "$HOME/.claude/hooks/session-end.sh" "$HOME/.claude/hooks/tts-daemon.py"
for k in $KNOBS; do rm -f "$HOME/.claude/$k"; done
defaults delete com.adamraabe.SpeakySpeak >/dev/null 2>&1
if [ "$KEEP" = 0 ] && command -v uv >/dev/null 2>&1; then uv tool uninstall mlx-audio >/dev/null 2>&1 && echo "The neural voice is removed. Its model (about 350 MB) stays in ~/.cache/huggingface."; fi
echo "Done. Last, delete this folder: $PWD"
