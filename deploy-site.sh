#!/bin/bash
# Deploy site/ to production. Exists because `vercel deploy --prod` run from
# the REPO ROOT publishes a directory with no index.html and takes
# speakyspeak.com down with a 404 — which is exactly what happened on
# 2026-08-24 (about three minutes of outage) when a shell's cwd had silently
# reset to the repo root between commands. Always deploy through this.
set -euo pipefail
cd "$(dirname "$0")/site"
[ -f index.html ] || { echo "no index.html in $(pwd) — refusing to deploy"; exit 1; }
vercel deploy --prod "$@"
echo
# Cache-bust: without this the check can pass against a CDN copy of the PREVIOUS
# deploy and tell you the new one is fine. Seen 2026-08-25, same byte count as
# before the deploy, which is what gave it away.
BUST="https://speakyspeak.com/?deploycheck=$$"
CODE=$(curl -s -o /dev/null -w '%{http_code}' "$BUST")
BYTES=$(curl -s "$BUST" | wc -c | tr -d ' ')
echo "speakyspeak.com -> HTTP $CODE, $BYTES bytes"
[ "$CODE" = "200" ] && [ "$BYTES" -gt 10000 ] || { echo "LIVE SITE LOOKS WRONG — check it now"; exit 1; }
echo "live site OK"
