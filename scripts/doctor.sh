#!/bin/bash
# doctor.sh: what is right and wrong with SpeakySpeak on this Mac, in plain
# words, each problem with the one thing that fixes it. Changes nothing.
#
#   scripts/doctor.sh            everything (this Mac, then the install)
#   scripts/doctor.sh --before   only what has to be true before an install
#
# Exit 0: nothing in the way. Exit 1: at least one line starts with "FIX".
# setup.sh runs it first and last. Output names no person, project or reply,
# so it is safe to paste into a report. Seams for tests/: SPEAKYSPEAK_DOCTOR_*.
set -u
cd "$(dirname "$0")/.."
BEFORE=0; [ "${1:-}" = "--before" ] && BEFORE=1
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
BAD=0
ok()   { echo "ok    $1"; }
note() { echo "note  $1"; }
fix()  { echo "FIX   $1"; echo "      -> $2"; BAD=1; }

CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
OSV="${SPEAKYSPEAK_DOCTOR_OS:-$(sw_vers -productVersion)}"
ARCH="${SPEAKYSPEAK_DOCTOR_ARCH:-$(uname -m)}"

echo "This Mac"
maj=${OSV%%.*}; rest=${OSV#*.}; min=${rest%%.*}; [ "$rest" = "$OSV" ] && min=0
if [ "$maj" -gt 15 ] || { [ "$maj" -eq 15 ] && [ "$min" -ge 6 ]; }; then ok "macOS $OSV"
else fix "macOS $OSV is too old (15.6 is the oldest that can build the app)" "System Settings > General > Software Update"; fi

if ! xcode-select -p >/dev/null 2>&1; then
  fix "Apple's command line tools are not installed" "run: xcode-select --install   (a window opens; click Install. It is free, about 1.3 GB, and macOS may ask for your Mac password. Then run this again)"
else
  ok "Apple's command line tools"
  if sdk=$(bash scripts/pick-sdk.sh 2>/tmp/speakyspeak-sdk.log); then
    ok "they can build the app${sdk:+ (using $(basename "$sdk"))}"
  else
    fix "Apple's command line tools cannot build the app" "look for a Command Line Tools update in System Settings > General > Software Update. If there is none: \"Command Line Tools for Xcode 26\" or newer from https://developer.apple.com/download/all/ (free Apple account). Then run this again"
  fi
fi

if command -v jq >/dev/null 2>&1; then ok "jq"
else fix "jq is missing (macOS 15 and later include it at /usr/bin/jq)" "put /usr/bin back on your PATH, or install jq"; fi

if [ -d "$CFG" ]; then ok "Claude Code's settings folder"
else fix "Claude Code has not run on this Mac yet (no $CFG)" "open Claude Code once and sign in, then run this again"; fi
if [ -f "$CFG/settings.json" ]; then
  if ! jq -e . "$CFG/settings.json" >/dev/null 2>&1; then
    fix "settings.json in Claude Code's folder is not valid JSON, so no hook can be added" "ask your Claude to repair it, then run this again"
  elif [ "$(jq -r '.disableAllHooks // false' "$CFG/settings.json")" = true ]; then
    fix "hooks are switched off in Claude Code (disableAllHooks), so nothing can be read aloud" "take \"disableAllHooks\": true out of settings.json"
  fi
fi
MANAGED="${SPEAKYSPEAK_DOCTOR_MANAGED:-/Library/Application Support/ClaudeCode/managed-settings.json}"
if [ -f "$MANAGED" ] && [ "$(jq -r '(.allowManagedHooksOnly // false) or (.disableAllHooks // false)' "$MANAGED" 2>/dev/null)" = true ]; then
  fix "your organization's Claude Code settings block hooks, which SpeakySpeak needs" "ask whoever manages this Mac"
fi
case "${CLAUDE_CODE_ENTRYPOINT:-}" in
  sdk-cli|sdk-ts|sdk-py)
    [ -f "$HOME/.claude/speak-headless" ] \
      || note "this Claude runs through claude -p or the Agent SDK, which stays silent by default. To hear it: touch ~/.claude/speak-headless" ;;
esac
[ -n "${SSH_CONNECTION:-}" ] && note "this is an SSH session: the sound plays on this Mac, not on the one you are typing on"

if [ "$ARCH" = arm64 ]; then
  ok "Apple silicon: gets the neural voice"
  if [ ! -x "$HOME/.local/bin/mlx_audio.tts.generate" ]; then
    free=$(df -g "$HOME" | awk 'NR==2{print $4}')
    if [ "${free:-9}" -ge 4 ]; then ok "${free} GB free (the neural voice takes about 1.5)"
    else note "only ${free} GB free; the neural voice needs about 1.5 and will be skipped if it does not fit"; fi
  fi
else note "Intel: uses the macOS voice; everything else is the same"; fi
lang=$(defaults read -g AppleLanguages 2>/dev/null | sed -n '2s/[^A-Za-z-]//gp')
case "$lang" in en*|"") ;; *) note "this Mac's language is $lang and the neural voice speaks English only. For replies in another language: echo say > ~/.claude/speak-engine, and a voice from say -v '?' in ~/.claude/speak-voice" ;; esac

if [ "$BEFORE" = 1 ]; then echo; [ "$BAD" = 0 ] && echo "Ready to install." || echo "Fix the lines above, then run this again."; exit "$BAD"; fi

echo; echo "SpeakySpeak"
APP="$HOME/Applications/SpeakySpeak.app"
if [ -x "$APP/Contents/MacOS/SpeakySpeak" ]; then ok "the app is installed ($(cat "$APP/Contents/Resources/VERSION" 2>/dev/null))"
else fix "the app is not in ~/Applications" "run ./setup.sh"; fi
if pgrep -x SpeakySpeak >/dev/null 2>&1; then ok "it is running"
elif [ -f "$HOME/.claude/speak-quit" ]; then fix "it was quit, so replies stay silent" "run: open ~/Applications/SpeakySpeak.app"
else fix "it is not running" "run: open ~/Applications/SpeakySpeak.app"; fi
miss=""
for h in speak-reply.sh session-end.sh tts-daemon.py; do [ -f "$HOME/.claude/hooks/$h" ] || miss="$miss $h"; done
[ -z "$miss" ] && ok "its scripts are in ~/.claude/hooks" || fix "missing in ~/.claude/hooks:$miss" "run ./install.sh"
evs=""
for e in Stop PostToolUse Notification SessionEnd; do
  jq -e --arg e "$e" '[.hooks[$e][]?.hooks[]?.command // ""] | any(test("speak-reply.sh|session-end.sh"))' "$CFG/settings.json" >/dev/null 2>&1 || evs="$evs $e"
done
[ -z "$evs" ] && ok "Claude Code calls it (4 hooks)" || fix "Claude Code does not call it for:$evs" "run: bash scripts/wire-hooks.sh"
[ -f "$HOME/.claude/speak-off" ] && fix "speech is switched off" "run: rm ~/.claude/speak-off   (or Settings > Speech > Speak Claude's replies)"
[ "$(defaults read com.adamraabe.SpeakySpeak muted 2>/dev/null)" = 1 ] && note "it is muted: click the speaker on the player"
if [ -x "$HOME/.local/bin/mlx_audio.tts.generate" ]; then
  a=/tmp/claude-speech/render/daemon.alive
  if [ -f "$a" ] && [ $(( $(date +%s) - $(/usr/bin/stat -f %m "$a") )) -le 10 ]; then ok "the neural voice is ready"
  else note "the voice helper is not answering yet (normal for a minute after an install; replies still play, a few seconds slower)"; fi
else note "the neural voice is not installed; replies use the macOS voice"; fi
last=$(grep -a ' spoke ' /tmp/claude-speech/hook.log 2>/dev/null | tail -1 | sed 's/ [0-9a-f]\{8\} spoke .*//')
[ -n "$last" ] && ok "last reply read aloud: $last" || note "no reply has been read aloud yet"
m=$(grep -aE 'microphone (on|off)' /tmp/claude-speech/deck.log 2>/dev/null | tail -1)
case "$m" in *"microphone on:"*) note "replies wait while another app uses the microphone (${m##*microphone on: }); press play to hear them anyway" ;; esac
echo; [ "$BAD" = 0 ] && echo "All good." || echo "See the FIX lines above."
exit "$BAD"
