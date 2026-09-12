#!/bin/bash
# pick-sdk.sh: choose the macOS SDK build.sh compiles against.
#
# Why this exists (2026-09-12): Apple's Command Line Tools for Xcode 27.0 make
# SwiftUI's @State a macro that needs the SwiftUIMacros compiler plugin, and
# the CLT do not ship that plugin (full Xcode does, under Platforms/). Every
# CLT-only install broke the moment Software Update delivered the 27.0 tools:
# main.swift failed with 96 errors, the first "plugin for module
# 'SwiftUIMacros' not found", the rest a "'self' is immutable" cascade from it.
# The 27.0 tools still ship MacOSX26.5.sdk next to the 27.0 one, and against
# that SDK the same swiftc compiles the app cleanly (verified on the Air).
#
# Contract: prints the -sdk path to use on stdout, or an EMPTY line when the
# default SDK is fine, so healthy setups keep building exactly as before.
# Exits 1 with a plain explanation on stderr when no SDK works. Diagnostics
# go to stderr. Order: the default first, then every other MacOSX*.sdk at the
# same location, newest first, skipping anything below the macOS 26 SDK the
# mini player's glass code needs.
#
# Test seams (tests/run-sdk-tests.sh): SPEAKYSPEAK_SWIFTC, SPEAKYSPEAK_SDK_DIR,
# SPEAKYSPEAK_DEFAULT_SDK.
set -u

SWIFTC="${SPEAKYSPEAK_SWIFTC:-swiftc}"
DEFAULT_SDK="${SPEAKYSPEAK_DEFAULT_SDK:-$(xcrun --show-sdk-path 2>/dev/null || true)}"
SDK_DIR="${SPEAKYSPEAK_SDK_DIR:-${DEFAULT_SDK:+$(dirname "$DEFAULT_SDK")}}"
TARGET="$(uname -m)-apple-macosx14.0"
MIN_MAJOR=26

TDIR=$(mktemp -d); trap 'rm -rf "$TDIR"' EXIT
# The smallest program that trips the missing plugin: one @State property.
cat > "$TDIR/probe.swift" <<'SWIFT'
import SwiftUI
struct Probe: View {
    @State private var n = 0
    var body: some View { Text("\(n)") }
}
SWIFT

probe() { # $1 = sdk path, or empty for the toolchain default
  if [ -n "$1" ]; then
    "$SWIFTC" -typecheck -sdk "$1" -target "$TARGET" "$TDIR/probe.swift" >"$TDIR/probe.log" 2>&1
  else
    "$SWIFTC" -typecheck -target "$TARGET" "$TDIR/probe.swift" >"$TDIR/probe.log" 2>&1
  fi
}
canon() { (cd "$1" 2>/dev/null && pwd -P); }

if probe ""; then
  echo ""
  exit 0
fi
echo "pick-sdk: the default SDK (${DEFAULT_SDK:-unknown}) cannot compile SwiftUI here:" >&2
grep -m1 'error:' "$TDIR/probe.log" | sed 's/^/  /' >&2

default_real=$(canon "$DEFAULT_SDK" || true)
tried=""
for cand in $(ls -d "$SDK_DIR"/MacOSX[0-9]*.sdk 2>/dev/null | sort -rV); do
  real=$(canon "$cand") || continue
  [ "$real" = "$default_real" ] && continue
  case " $tried " in *" $real "*) continue;; esac
  tried="$tried $real"
  ver=$(basename "$cand" | sed -E 's/^MacOSX([0-9.]+)\.sdk$/\1/'); major=${ver%%.*}
  if ! [ "${major:-0}" -ge "$MIN_MAJOR" ] 2>/dev/null; then
    echo "pick-sdk: skipping $(basename "$cand") (below the macOS $MIN_MAJOR SDK the mini player needs)" >&2
    continue
  fi
  if probe "$cand"; then
    echo "pick-sdk: building against $(basename "$cand") instead" >&2
    echo "$cand"
    exit 0
  fi
  echo "pick-sdk: $(basename "$cand") fails too" >&2
done

cat >&2 <<EOF
pick-sdk: no usable macOS SDK found in ${SDK_DIR:-the toolchain}.
  Apple's Command Line Tools 27.0 cannot compile SwiftUI on their own (the
  SwiftUIMacros plugin ships only inside Xcode), and no macOS 26 SDK is left
  beside them to fall back to. Two ways out:
    1. Install Xcode from the App Store, then:
       sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
    2. Install "Command Line Tools for Xcode 26" from
       https://developer.apple.com/download/all/ and re-run the build.
EOF
exit 1
