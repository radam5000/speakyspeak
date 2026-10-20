# Sourced by install.sh as its very last step.
#
# The updater in 1.0.0 to 1.0.9 (2026-08-16 to 08-18) ran, from a shell the
# app itself started:
#   cd <clone> && git pull --ff-only && ./install.sh >> update.log 2>&1 &&
#   pkill -x SpeakySpeak; sleep 1; open -g ~/Applications/SpeakySpeak.app
# pkill leaves out its own ancestors, and the app is that shell's parent, so
# the app was never killed and `open -g` found it still running. Those
# installs update on disk but keep running the old code, and every later
# Update click does the same (F-0008, reported on 10/17). They do run
# the newly pulled install.sh, so it finishes the job: when that chain is an
# ancestor of this script, quit the app that started it, and the chain's own
# `open -g` launches the new bundle a second later. 1.0.10 and later relaunch
# themselves and never match; neither does install.sh run by hand.
# Every step tolerates failure: install.sh runs under set -euo pipefail, and a
# rescue that cannot tell must never fail the install.
rescue_old_updater() {
  local pid=$$ cmd app="" exe
  while [ "${pid:-0}" -gt 1 ]; do
    cmd=$(ps -o command= -p "$pid" 2>/dev/null) || return 0
    case "$cmd" in
      *"pkill -x SpeakySpeak"*) app=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ') || return 0; break ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ') || return 0
  done
  [ -n "$app" ] || return 0
  exe=$(ps -o comm= -p "$app" 2>/dev/null) || return 0
  case "$exe" in */SpeakySpeak.app/Contents/MacOS/SpeakySpeak) ;; *) return 0 ;; esac
  echo "Restarting SpeakySpeak (pid $app): this updater's own relaunch cannot reach it."
  kill "$app" 2>/dev/null || return 0
  for _ in $(seq 1 25); do kill -0 "$app" 2>/dev/null || return 0; sleep 0.2; done
  kill -9 "$app" 2>/dev/null || true
  return 0
}
