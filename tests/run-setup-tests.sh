#!/bin/bash
# The install a stranger gets, in an empty home with a system PATH: doctor.sh
# names each problem with its fix, setup.sh installs and is safe to run twice,
# the built-in encoder reaches normal loudness without ffmpeg, and uninstall.sh
# leaves other people's hooks exactly as they were. Nothing here touches the
# live install: HOME is a temp folder, and defaults, launchctl, open, pkill and
# pgrep are stubs. The neural voice (1 GB) is not fetched; that path was run
# from nothing by hand for 1.2.30 (see setup.sh, --exclude-newer).
set -u
cd "$(dirname "$0")/.."
[ -x SpeakySpeak.app/Contents/MacOS/SpeakySpeak ] || { echo "FAIL: no built app (run ./build.sh --no-install)"; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; }
has() { grep -q -- "$2" "$1" && ok "$3" || { bad "$3"; sed 's/^/       /' "$1"; }; }

H="$T/home"; ST="$T/stub"; SRC="$T/src"; mkdir -p "$H/.claude" "$ST" "$SRC" "$T/root"
cp -R setup.sh uninstall.sh install.sh VERSION GUIDE.md scripts hooks "$SRC/"
# the voice env is never fetched here; Homebrew is hidden so nothing leaks in
for f in setup.sh uninstall.sh scripts/doctor.sh hooks/speak-reply.sh; do sed -i '' 's#:/opt/homebrew/bin:/usr/local/bin##g' "$SRC/$f"; done
printf '#!/bin/bash\nmkdir -p "$HOME/Applications"; rm -rf "$HOME/Applications/SpeakySpeak.app"; cp -R "%s" "$HOME/Applications/"; echo "Installed $HOME/Applications/SpeakySpeak.app"\n' "$PWD/SpeakySpeak.app" > "$SRC/build.sh"; chmod +x "$SRC/build.sh"
printf '#!/bin/bash\ncase "$1" in read) [ "$2" = -g ] && printf "(\\n    \\"%%s\\"\\n)\\n" "${FAKE_LANG:-en-US}"; [ "$2" = -g ] || exit 1;; esac\nexit 0\n' > "$ST/defaults"
printf '#!/bin/bash\nexit 0\n' | tee "$ST/launchctl" "$ST/pkill" "$ST/pgrep" >/dev/null
# "open" stands in for the deck: anything queued counts as played
printf '#!/bin/bash\n(for i in $(seq 1 60); do for j in "%s"/queue/*.json; do [ -f "$j" ] && echo "playing $(basename "$j" .json)" >> "%s/deck.log" && exit; done; sleep 0.2; done) >/dev/null 2>&1 &\n' "$T/root" "$T/root" > "$ST/open"
chmod +x "$ST"/*
run() { env -i HOME="$H" USER="$USER" TMPDIR="${TMPDIR:-/tmp}" PATH="$ST:/usr/bin:/bin:/usr/sbin:/sbin" SPEAKYSPEAK_SPEECH_ROOT="$T/root" ${X:-A=1} ${X2:-A=1} "$@" > "$T/out" 2>&1; }
cd "$SRC"

echo "doctor: problems are named with their fix"
X=SPEAKYSPEAK_DOCTOR_OS=15.5 run bash scripts/doctor.sh --before && bad "macOS 15.5 passed" || has "$T/out" "macOS 15.5 is too old" "macOS 15.5 is refused"
X=SPEAKYSPEAK_DOCTOR_OS=15.6 run bash scripts/doctor.sh --before; has "$T/out" "ok    macOS 15.6" "macOS 15.6 is fine"
X=SPEAKYSPEAK_DOCTOR_OS=26 run bash scripts/doctor.sh --before; has "$T/out" "ok    macOS 26" "a bare major version is fine"
X=SPEAKYSPEAK_DOCTOR_ARCH=x86_64 run bash scripts/doctor.sh --before; has "$T/out" "Intel: uses the macOS voice" "Intel is told what it gets"
X=FAKE_LANG=de-DE run bash scripts/doctor.sh --before; has "$T/out" "speaks English only" "a German Mac is told"
X=CLAUDE_CODE_ENTRYPOINT=sdk-cli run bash scripts/doctor.sh --before; has "$T/out" "speak-headless" "claude -p is told"
echo '{"disableAllHooks": true}' > "$H/.claude/settings.json"; run bash scripts/doctor.sh --before && bad "disableAllHooks passed" || has "$T/out" "disableAllHooks" "hooks switched off are caught"
echo '{oops' > "$H/.claude/settings.json"; run bash scripts/doctor.sh --before && bad "broken JSON passed" || has "$T/out" "not valid JSON" "a broken settings.json is caught"
echo '{"allowManagedHooksOnly": true}' > "$T/managed.json"; echo '{}' > "$H/.claude/settings.json"
X="SPEAKYSPEAK_DOCTOR_MANAGED=$T/managed.json" run bash scripts/doctor.sh --before && bad "managed hooks passed" || has "$T/out" "your organization" "an organization that blocks hooks is caught"
mv "$H/.claude" "$H/.off"; run bash scripts/doctor.sh --before && bad "no Claude Code passed" || has "$T/out" "has not run on this Mac" "no Claude Code is caught"; mv "$H/.off" "$H/.claude"

echo "setup: from nothing"
echo '{"permissions":{"allow":["Bash(ls:*)"]},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo mine"}]}]}}' > "$H/.claude/settings.json"
cp "$H/.claude/settings.json" "$T/orig.json"
run ./setup.sh --no-neural && ok "exit 0" || { bad "exit $?"; cat "$T/out"; }
has "$T/out" "You should hear it now" "it said hello through the queue"
has "$T/out" "All good" "the check at the end passes"
N=$(jq '[.hooks[][].hooks[].command | select(test("hooks/(speak-reply|session-end)"))] | length' "$H/.claude/settings.json")
[ "$N" = 4 ] && ok "four hooks registered" || bad "$N hooks registered"
M=$(ls "$T/root/queue/"*.m4a 2>/dev/null | head -1)
if [ -n "$M" ] && command -v ffmpeg >/dev/null 2>&1; then
  L=$(ffmpeg -hide_banner -nostats -i "$M" -af ebur128 -f null - 2>&1 | awk '/^ +I:/{print $2}' | tail -1)
  awk -v l="$L" 'BEGIN{exit !(l > -17.5 && l < -14.5)}' && ok "the hello is at speech level ($L LUFS) without ffmpeg" || bad "the hello is at $L LUFS"
fi
run ./setup.sh --no-neural --quiet && ok "a second run is fine" || bad "second run exit $?"
N=$(jq '[.hooks[][].hooks[].command | select(test("hooks/(speak-reply|session-end)"))] | length' "$H/.claude/settings.json")
[ "$N" = 4 ] && ok "and adds no second set of hooks" || bad "$N hooks after two runs"

echo "encoder: what the hook asks of the app"
E="$H/Applications/SpeakySpeak.app/Contents/MacOS/SpeakySpeak"
"$E" --encode /nonexistent.wav "$T/x.m4a" && bad "a missing file passed" || ok "a missing file fails, quietly"
[ -f "$H/Applications/SpeakySpeak.app/Contents/Resources/ENCODER" ] && ok "the app says it can encode" || bad "no ENCODER marker"

echo "uninstall: only its own things go"
run ./uninstall.sh; [ -d "$H/Applications/SpeakySpeak.app" ] && ok "without --yes it removes nothing" || bad "removed without --yes"
run ./uninstall.sh --yes
diff <(jq -S . "$T/orig.json") <(jq -S . "$H/.claude/settings.json") >/dev/null && ok "settings.json is back to what it was" || bad "settings.json differs"
[ ! -e "$H/Applications/SpeakySpeak.app" ] && [ ! -e "$H/.claude/hooks/speak-reply.sh" ] && [ ! -e "$H/Library/LaunchAgents/com.adamraabe.speakyspeak-tts.plist" ] && ok "app, hooks and helper are gone" || bad "something was left"

echo; echo "setup tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
