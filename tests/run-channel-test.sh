#!/bin/bash
# Is "Claude Code X is out" true for the user's own release channel?
#
# Claude Code's stable channel installs a release about a week after the
# changelog names it, so the Claude strip told stable users about versions
# they could not install yet. On that channel the strip now asks npm for its
# "stable" version. This lifts the real helper out of main.swift (the block
# between the claude-channel sentinels), compiles it alone and checks:
#
#   1. no settings file, or no autoUpdatesChannel  -> "latest"
#   2. autoUpdatesChannel "stable" in settings.json -> "stable"
#   3. npm's dist-tags answer                       -> its stable x.y.z
#   4. an answer with no stable tag, or not JSON    -> nil (the strip keeps its last reading)
#
# No network: the dist-tags answer is a fixture.
set -u
cd "$(dirname "$0")/.."
SRC=${CHANNEL_TEST_SRC:-main.swift}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

BLOCK=$(awk '/\/\/ <<<claude-channel/{f=1;next} /\/\/ claude-channel>>>/{f=0} f' "$SRC")
if [ -z "$BLOCK" ]; then
  echo "FAIL: could not find the claude-channel block in $SRC (sentinels moved?)"
  exit 1
fi

mkdir -p "$TMP/none" "$TMP/plain" "$TMP/stable"
echo '{"model":"opus"}' > "$TMP/plain/settings.json"
echo '{"autoUpdatesChannel":"stable","model":"opus"}' > "$TMP/stable/settings.json"

{
echo "import Foundation"
echo "$BLOCK"
cat <<SWIFT
var fails = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "  ok    \(what)" : "  FAIL  \(what)"); if !ok { fails += 1 } }
check(ClaudeChannel.current(configDir: "$TMP/none") == "latest", "no settings file: latest")
check(ClaudeChannel.current(configDir: "$TMP/plain") == "latest", "settings without a channel: latest")
check(ClaudeChannel.current(configDir: "$TMP/stable") == "stable", "autoUpdatesChannel stable: stable")
check(ClaudeChannel.stableVersion(from: Data(#"{"stable":"2.1.309","next":"2.1.316","latest":"2.1.316"}"#.utf8)) == "2.1.309", "npm dist-tags: the stable version")
check(ClaudeChannel.stableVersion(from: Data(#"{"latest":"2.1.316"}"#.utf8)) == nil, "no stable tag: nothing")
check(ClaudeChannel.stableVersion(from: Data("<html>rate limited</html>".utf8)) == nil, "not JSON: nothing")
check(ClaudeChannel.distTags.host == "registry.npmjs.org", "asks npm's registry")
print(fails == 0 ? "CHANNEL: ALL GREEN" : "CHANNEL: \(fails) FAILED")
exit(fails == 0 ? 0 : 1)
SWIFT
} > "$TMP/t.swift"

SDK=$(bash scripts/pick-sdk.sh) || exit 1
SDKFLAG=(); [ -n "$SDK" ] && SDKFLAG=(-sdk "$SDK")
swiftc ${SDKFLAG[@]+"${SDKFLAG[@]}"} -o "$TMP/t" "$TMP/t.swift" 2> "$TMP/err" || { echo "FAIL: compile"; cat "$TMP/err"; exit 1; }
"$TMP/t"
