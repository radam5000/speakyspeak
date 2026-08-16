#!/bin/bash
# SessionEnd hook: drop a marker so SpeechDeck removes this session's items.
QUEUE=/tmp/claude-speech/queue
[ -d "$QUEUE" ] || exit 0
sid=$(jq -r '.session_id // empty' | cut -c1-8)
[ -n "$sid" ] || exit 0
touch "$QUEUE/$(date +%s)-$sid.end"
exit 0
