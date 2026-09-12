#!/bin/bash
# Contract tests for scripts/pick-sdk.sh, the fallback that keeps the build
# alive under Command Line Tools 27.0 (no SwiftUIMacros plugin, 2026-09-12).
# A fake swiftc decides which SDK "compiles"; a fixture SDKs dir copies the
# CLT layout: MacOSX.sdk -> 27.0, versioned symlinks, real 26.5 beside it.
set -u
cd "$(dirname "$0")/.."
P="$PWD/scripts/pick-sdk.sh"
TDIR=$(mktemp -d); trap 'rm -rf "$TDIR"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; }

SDKS="$TDIR/SDKs"; mkdir -p "$SDKS/MacOSX27.0.sdk" "$SDKS/MacOSX26.5.sdk" "$SDKS/MacOSX15.5.sdk"
ln -s MacOSX27.0.sdk "$SDKS/MacOSX.sdk"; ln -s MacOSX27.0.sdk "$SDKS/MacOSX27.sdk"; ln -s MacOSX26.5.sdk "$SDKS/MacOSX26.sdk"
cat > "$TDIR/swiftc" <<'FAKE'
#!/bin/bash
# FAKE_MODE: all-ok | only26 | only15 | none. Logs every call's args.
echo "$*" >> "$FAKE_LOG"
sdk=""; while [ $# -gt 0 ]; do [ "$1" = "-sdk" ] && sdk="$2"; shift; done
case "$FAKE_MODE" in
  all-ok) exit 0;;
  only26) case "$sdk" in *MacOSX26*) exit 0;; esac; echo "error: external macro implementation type 'SwiftUIMacros.StateMacro' could not be found"; exit 1;;
  only15) case "$sdk" in *MacOSX15*) exit 0;; esac; echo "error: plugin for module 'SwiftUIMacros' not found"; exit 1;;
  *) echo "error: plugin for module 'SwiftUIMacros' not found"; exit 1;;
esac
FAKE
chmod +x "$TDIR/swiftc"
run() { # $1 = FAKE_MODE
  : > "$TDIR/calls"
  FAKE_MODE="$1" FAKE_LOG="$TDIR/calls" SPEAKYSPEAK_SWIFTC="$TDIR/swiftc" \
  SPEAKYSPEAK_DEFAULT_SDK="$SDKS/MacOSX.sdk" SPEAKYSPEAK_SDK_DIR="$SDKS" \
  bash "$P" >"$TDIR/out" 2>"$TDIR/err"; RC=$?
}

echo "sdk 1: default SDK compiles -> empty answer, nothing else probed"
run all-ok
[ "$RC" -eq 0 ] && [ -z "$(cat "$TDIR/out")" ] && ok "empty stdout, exit 0" || bad "rc=$RC out='$(cat "$TDIR/out")'"
[ "$(wc -l < "$TDIR/calls" | tr -d ' ')" = 1 ] && ok "one probe only" || bad "probes: $(cat "$TDIR/calls")"

echo "sdk 2: CLT 27 layout, default broken, 26.5 works -> 26.5 chosen"
run only26
want=$(cd "$SDKS/MacOSX26.5.sdk" && pwd -P); got=$(cd "$(cat "$TDIR/out")" 2>/dev/null && pwd -P)
[ "$RC" -eq 0 ] && [ "$got" = "$want" ] && ok "prints the 26.5 SDK" || bad "rc=$RC out='$(cat "$TDIR/out")'"
grep -q "building against MacOSX26" "$TDIR/err" && ok "says so on stderr" || bad "stderr: $(cat "$TDIR/err")"
grep -q "SwiftUIMacros" "$TDIR/err" && ok "quotes the compiler's first error" || bad "no error quoted"
grep -q -- "-sdk .*MacOSX27" "$TDIR/calls" && bad "re-probed the default via its 27 aliases" || ok "27.x aliases of the default skipped"
[ "$(grep -c -- "-sdk .*MacOSX26" "$TDIR/calls")" = 1 ] && ok "26 probed once despite two names" || bad "26 probes: $(grep -c -- '-sdk .*MacOSX26' "$TDIR/calls")"
grep -q -- "-sdk .*MacOSX15" "$TDIR/calls" && bad "probed a pre-26 SDK" || ok "pre-26 SDK never probed"

echo "sdk 3: only a pre-26 SDK would compile -> refused, exit 1"
run only15
[ "$RC" -eq 1 ] && ok "exit 1" || bad "rc=$RC"
grep -q "below the macOS 26 SDK" "$TDIR/err" && ok "explains the skip" || bad "stderr: $(cat "$TDIR/err")"

echo "sdk 4: nothing compiles -> exit 1 with the two ways out"
run none
[ "$RC" -eq 1 ] && [ -z "$(cat "$TDIR/out")" ] && ok "exit 1, empty stdout" || bad "rc=$RC out='$(cat "$TDIR/out")'"
grep -q "xcode-select -s" "$TDIR/err" && grep -q "developer.apple.com/download" "$TDIR/err" && ok "names Xcode and the CLT 26 download" || bad "stderr: $(cat "$TDIR/err")"

echo "sdk 5: this machine's real toolchain has a usable SDK"
real=$(bash "$P" 2>"$TDIR/err"); RC=$?
[ "$RC" -eq 0 ] && ok "picker exits 0 (chose: ${real:-default})" || bad "rc=$RC $(cat "$TDIR/err")"

echo; echo "sdk tests: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
