#!/bin/bash
# Proves the guide gate (verify.sh step 6, tests/guide-coverage.py) catches a
# gap: each case plants one in a scratch copy of the repo and expects it named.
# A gate that never fails proves nothing, so this runs with verify.sh.
set -u
cd "$(dirname "$0")/.."
T=$(mktemp -d /tmp/ss-guide-gate.XXXX)
trap 'rm -rf "$T"' EXIT
FAIL=0
fresh() {
  rm -rf "$T/r"; mkdir -p "$T/r/tests" "$T/r/hooks"
  cp main.swift GUIDE.md "$T/r/"; cp tests/guide-coverage.py "$T/r/tests/"
  cp hooks/speak-reply.sh hooks/session-end.sh hooks/tts-daemon.py "$T/r/hooks/" 2>/dev/null
}
gate() { (cd "$T/r" && python3 tests/guide-coverage.py); }
expect() {  # <case> <text the gate must print, or "" for silence>
  local out; out=$(gate)
  if [ -z "$2" ]; then
    [ -z "$out" ] && echo "  ok   $1" || { echo "  FAIL $1: printed '$out'"; FAIL=1; }
  else
    case "$out" in *"$2"*) echo "  ok   $1";; *) echo "  FAIL $1: wanted '$2', got '$out'"; FAIL=1;; esac
  fi
}
plant() {  # <python that edits file f in place> <file>
  python3 - "$T/r/$2" "$1" <<'PY'
import sys
f, code = sys.argv[1], sys.argv[2]
s = open(f).read()
exec(code)
open(f, "w").write(s)
PY
}

fresh; expect "the real guide covers the real app" ""

fresh; plant 's = s.replace("Section(\"Speech\") {", "Section(\"Speech\") {\n                Toggle(\"Brand new switch\", isOn: .constant(true))", 1)' main.swift
expect "a new Settings toggle with no guide entry" "Brand new switch"

fresh; plant 's = s.replace("Text(\"How to use it\")", "Text(\"Mystery row\")", 1)' main.swift
expect "a new Settings row label with no guide entry" "Mystery row"

fresh; plant 's = s.replace("#!/bin/bash", "#!/bin/bash\n# reads ~/.claude/speak-brandnew", 1)' hooks/speak-reply.sh
expect "a new knob in the hook with no guide entry" "speak-brandnew"

fresh; plant 's = s.replace("`speak-prompt-chime`", "`chime`")' GUIDE.md
expect "a knob dropped from the guide" "speak-prompt-chime"

fresh; plant 's = s.replace("`speak-voice-kokoro`", "`kokoro-voice`")' GUIDE.md
expect "speak-voice does not count as speak-voice-kokoro" "speak-voice-kokoro"

# the app's copy has to be this file (verify.sh compares the built bundle's)
fresh; mkdir -p "$T/r/R"; cp GUIDE.md "$T/r/R/GUIDE.md"; echo "stale" >> "$T/r/R/GUIDE.md"
if cmp -s "$T/r/GUIDE.md" "$T/r/R/GUIDE.md"; then echo "  FAIL a stale bundled guide passed cmp"; FAIL=1
else echo "  ok   a stale bundled guide fails the comparison"; fi

[ "$FAIL" -eq 0 ] && echo "guide gate: all cases caught" || echo "guide gate: FAILED"
exit $FAIL
