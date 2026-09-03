#!/bin/bash
# Register SpeakySpeak's hooks in Claude Code's ~/.claude/settings.json.
# Called by install.sh (so the in-app updater runs it too); safe to re-run.
#
# Rules, in order of what matters most to a user who already has a settings
# file full of their own things:
#   - only ADD, never rewrite: an event whose array already carries a hook
#     command naming our script is left exactly as it is, timeouts and all.
#     Everything else in the file (permissions, env, other people's hooks)
#     passes through jq untouched.
#   - a file that is not valid JSON is never written; the block is printed
#     for a human (or their agent) to merge, and install.sh still succeeds.
#   - a backup sits next to the file before the first write of a run.
#   - missing file: created with just the hooks object.
# Until 2026-09-03 install.sh printed a block and INSTALL.md step 5 had the
# user's agent merge JSON by hand, so every new hook event (PostToolUse in
# 1.1, Notification in 1.2.8) silently missed everyone who updated in-app.
# SPEAKYSPEAK_SETTINGS overrides the path; it exists only for tests/.
set -u
SETTINGS="${SPEAKYSPEAK_SETTINGS:-$HOME/.claude/settings.json}"
SPEAK='bash ~/.claude/hooks/speak-reply.sh'
END='bash ~/.claude/hooks/session-end.sh'

group() {  # $1 matcher, $2 command, $3 timeout ("" = none, not async)
  if [ -n "$3" ]; then
    jq -nc --arg m "$1" --arg c "$2" --argjson t "$3" \
      '{matcher:$m, hooks:[{type:"command", command:$c, timeout:$t, async:true}]}'
  else
    jq -nc --arg m "$1" --arg c "$2" '{matcher:$m, hooks:[{type:"command", command:$c}]}'
  fi
}

# event ; matcher ; command ; timeout   (";" because matchers contain "|")
WANT=$(cat <<W
Stop;*;$SPEAK;600
PostToolUse;*;$SPEAK;600
Notification;permission_prompt|elicitation_dialog|agent_needs_input;$SPEAK;120
SessionEnd;*;$END;
W
)

print_block() {
  echo
  echo "Could not edit $SETTINGS ($1)."
  echo "Add this inside its top-level \"hooks\" object (merge, don't replace):"
  echo
  sed -n '/^"hooks": {$/,/^}$/p' "$(dirname "$0")/../INSTALL.md" | sed 's/^/  /'
}

if ! command -v jq >/dev/null 2>&1; then print_block "jq is not installed"; exit 0; fi

if [ -f "$SETTINGS" ]; then
  if ! jq -e 'type == "object"' "$SETTINGS" >/dev/null 2>&1; then
    print_block "not valid JSON, left untouched"; exit 0
  fi
  cur=$(cat "$SETTINGS")
else
  mkdir -p "$(dirname "$SETTINGS")"
  cur='{}'
fi

added=(); kept=()
while IFS=';' read -r ev matcher cmd timeout; do
  [ -n "$ev" ] || continue
  script=${cmd##*/}
  if printf '%s' "$cur" | jq -e --arg ev "$ev" --arg s "$script" \
       '[.hooks[$ev][]?.hooks[]?.command // "" | select(contains($s))] | length > 0' >/dev/null; then
    kept+=("$ev"); continue
  fi
  g=$(group "$matcher" "$cmd" "$timeout")
  cur=$(printf '%s' "$cur" | jq --arg ev "$ev" --argjson g "$g" '.hooks //= {} | .hooks[$ev] += [$g]') || { print_block "jq edit failed"; exit 0; }
  added+=("$ev")
done <<< "$WANT"

if [ ${#added[@]} -eq 0 ]; then
  echo "Claude Code hooks already registered in $SETTINGS (${kept[*]})."
  exit 0
fi
if [ -f "$SETTINGS" ]; then
  cp "$SETTINGS" "$SETTINGS.bak-speakyspeak-$(date +%Y%m%d-%H%M%S)"
fi
printf '%s\n' "$cur" | jq . > "$SETTINGS.tmp-speakyspeak" && mv "$SETTINGS.tmp-speakyspeak" "$SETTINGS" \
  || { rm -f "$SETTINGS.tmp-speakyspeak"; print_block "write failed"; exit 0; }
echo "Registered Claude Code hooks in $SETTINGS: added ${added[*]}${kept[*]:+ (already there: ${kept[*]})}."
echo "Claude Code picks the change up on its own; no restart needed."
