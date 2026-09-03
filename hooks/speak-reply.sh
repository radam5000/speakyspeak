#!/bin/bash
# Stop hook: render Claude's final reply to audio and enqueue it for
# SpeakySpeak (~/Applications/SpeakySpeak.app), which plays items one at
# a time — no overlapping sessions. Play order is the app's business
# (flat or grouped by session); this script only produces queue items.
# SPEAKYSPEAK_SPEECH_ROOT exists for the fixture tests in tests/ (isolated
# queue, no interference with a live deck watching /tmp/claude-speech).
# Production never sets it; the app hard-codes /tmp/claude-speech.
SPEECH_ROOT="${SPEAKYSPEAK_SPEECH_ROOT:-/tmp/claude-speech}"
LOG=$SPEECH_ROOT/hook.log
QUEUE=$SPEECH_ROOT/queue
RENDER=$SPEECH_ROOT/render           # warm TTS daemon's request queue
ALIVE="$RENDER/daemon.alive"         # daemon heartbeat; hook only uses it when fresh
APP="$HOME/Applications/SpeakySpeak.app"
[ -f "$HOME/.claude/speak-off" ] && exit 0
# no speak-rate file = the voice's natural pace, so the deck's 1× is true 1×
RATE=$(cat "$HOME/.claude/speak-rate" 2>/dev/null || echo "")
VOICE=$(cat "$HOME/.claude/speak-voice" 2>/dev/null || echo "")
RATEARGS=()
[ -n "$RATE" ] && RATEARGS=(-r "$RATE")

# No speak-voice file: probe for the best installed voice instead of
# hard-coding one — `say -v` with a voice this Mac never downloaded fails
# outright, which read as "installed fine, total silence" on a fresh machine.
# No match at all = no -v flag = the system default voice, which always works.
pick_say_voice() {
  local voices v
  voices=$(say -v '?' 2>/dev/null)
  for v in "Ava (Premium)" "Ava (Enhanced)" "Zoe (Premium)" "Samantha (Enhanced)" "Samantha"; do
    if printf '%s\n' "$voices" | grep -qF "$v"; then printf '%s' "$v"; return; fi
  done
}
VOICEARGS=()
say_voiceargs() {
  [ -n "$VOICE" ] || VOICE=$(pick_say_voice)
  [ -n "$VOICE" ] && VOICEARGS=(-v "$VOICE")
}

# Engine: Kokoro-82M (local neural TTS via mlx-audio, uv tool) when installed,
# else macOS say. Override with ~/.claude/speak-engine = "say" | "kokoro".
# speak-rate/speak-voice are say-only; Kokoro renders at natural pace and the
# deck's playback speed control handles pacing.
KOKORO_BIN="$HOME/.local/bin/mlx_audio.tts.generate"
KOKORO_MODEL="mlx-community/Kokoro-82M-bf16"
KOKORO_VOICE=$(cat "$HOME/.claude/speak-voice-kokoro" 2>/dev/null || echo "bf_lily")
ENGINE=$(cat "$HOME/.claude/speak-engine" 2>/dev/null || echo "")
if [ -z "$ENGINE" ]; then
  if [ -x "$KOKORO_BIN" ]; then ENGINE=kokoro; else ENGINE=say; fi
fi

# Released on exit by the EXIT traps in this script. There is only ever ONE
# active trap; every `trap` call in this file must route through cleanup_all
# (the afplay fallback replaces the trap and does), or a lock leaks.
MIDLOCK=""
CLAIMDIR=""
cleanup_midlock() { [ -n "$MIDLOCK" ] && rmdir "$MIDLOCK" 2>/dev/null; return 0; }
cleanup_all() {
  [ -n "$CLAIMDIR" ] && rmdir "$CLAIMDIR" 2>/dev/null
  cleanup_midlock
  return 0
}

input=$(cat)

# WHEN to speak. Two entry points share this script and everything below it:
#
#   Stop         - the turn is over and Claude is waiting for the user. The
#                  only behaviour that existed until 2026-08-22.
#   PostToolUse  - fires mid-turn, after each tool call, so a long agentic run
#                  is narrated as it happens instead of going silent for twenty
#                  minutes. (Adam, 2026-08-22: a 20-minute everething debug run
#                  in which three "press the power button now" instructions were
#                  never spoken, because the turn simply never ended.)
#
# ~/.claude/speak-when picks the mode; absent file = "end" = the old behaviour:
#   end          - Stop only.
#   substantial  - Stop + mid-run entries of at least $MINWORDS words, so the
#                  short connective lines ("Let me check that.") stay quiet.
#   all          - Stop + every mid-run entry.
# ~/.claude/speak-min-words overrides the 15-word threshold (no GUI; a tuning
# escape hatch, deliberately not a second control in the Settings window).
#
# Checked here, before any other work, because in "end" mode this script is
# spawned after every single tool call and must cost as close to nothing as
# it can.
event=$(printf '%s' "$input" | jq -r '.hook_event_name // "Stop"')

# Third entry point (2026-09-03, Adam: "I'm getting a lot of permission
# questions in various sessions and don't even hear a chime"):
#
#   Notification - Claude Code is WAITING ON THE USER: a permission prompt
#                  (yes/no on a tool call), an elicitation dialog, an agent
#                  that needs input. Nothing in the transcript announces it,
#                  so a session parked behind another window just sits there.
#
# Play a chime distinct from the end-of-reply one at once (the render below
# takes a second), then queue the question as a normal item so the deck
# says which session wants what. No .seen bookkeeping: this text is not in
# the transcript, and every prompt should be spoken even if it repeats.
# speak-when is not consulted; a prompt is never "mid-run noise".
# Chime: ~/.claude/speak-prompt-chime holds a path; absent = Hero.aiff
# (the Stop chime is Glass.aiff, wired separately in settings.json).
kind=reply
if [ "$event" = "Notification" ]; then
  ntype=$(printf '%s' "$input" | jq -r '.notification_type // empty')
  case $ntype in permission_prompt|elicitation_dialog|agent_needs_input) ;; *) exit 0 ;; esac
  kind=notify
  CHIME=$(cat "$HOME/.claude/speak-prompt-chime" 2>/dev/null || echo "")
  [ -n "$CHIME" ] || CHIME=/System/Library/Sounds/Hero.aiff
  [ -f "$CHIME" ] && { afplay "$CHIME" >/dev/null 2>&1 & }
fi
WHEN=$(cat "$HOME/.claude/speak-when" 2>/dev/null | tr -d '[:space:]')
[ -n "$WHEN" ] || WHEN=end
case $WHEN in end|substantial|all) ;; *) WHEN=end ;; esac
[ "$kind" = reply ] && [ "$event" != "Stop" ] && [ "$WHEN" = end ] && exit 0
MINWORDS=$(cat "$HOME/.claude/speak-min-words" 2>/dev/null | tr -cd '0-9')
[ -n "$MINWORDS" ] || MINWORDS=15
[ "$WHEN" = all ] && MINWORDS=0

t=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
[ "$kind" = notify ] || [ -f "$t" ] || exit 0
full_sid=$(printf '%s' "$input" | jq -r '.session_id // "session"')
sid=$(printf '%s' "$full_sid" | cut -c1-8)
proj=$(basename "$(printf '%s' "$input" | jq -r '.cwd // "project"')" | tr -cd '[:alnum:]._-')

# Item label: the session's title (set via /rename or --name), best source
# first — hook input, then the Remote Control bridge files. Falls back to
# the project folder name.
title=$(printf '%s' "$input" | jq -r '.session_title // empty')
if [ -z "$title" ]; then
  title=$(jq -rs --arg sid "$full_sid" \
    '[.[] | select(.sessionId == $sid and (.name // "") != "")] | sort_by(.updatedAt) | last | .name // empty' \
    "$HOME"/.claude/sessions/*.json 2>/dev/null)
fi
{ [ -z "$title" ] || [ "$title" = "null" ]; } && title="$proj"

mkdir -p "$QUEUE"
find "$SPEECH_ROOT" \( -name '*.m4a' -o -name '*.json' -o -name '*.end' -o -name '*.done' -o -name '.seen-*' -o -name '.claim-*' \) -mtime +2 -delete 2>/dev/null

# Returns "<uuid>\t<timestamp>\t<text>" — but ONLY when the last assistant
# entry in the file is a text entry. Mid-turn preambles ("Quick check on X
# before answering.") are always followed by tool_use entries, so they can
# never qualify; while the turn's final reply hasn't flushed yet the last
# entry is a tool_use/thinking entry and this returns "", which keeps the
# poll loop below waiting. Sidechain (subagent) entries are excluded so a
# background agent finishing after Stop isn't spoken as the reply.
# NOTE: the array filter below is load-bearing for the GATE. If a transcript
# format ever carries assistant text as a plain string, that entry becomes
# invisible here and an OLDER entry reads as "last" — a gate-widening failure.
# Censused 2026-08-25: 100% of assistant entries are arrays today.
extract() {
  jq -rs '
    [.[] | select(.type == "assistant" and ((.isSidechain // false) | not)
                  and (.message.content | type) == "array")]
    | last
    | if . == null then ""
      elif ([.message.content[] | select(.type == "tool_use")] | length) > 0 then ""
      else ([.message.content[] | select(.type == "text") | .text] | join("\n")) as $t
        | if $t == "" then ""
          else (.uuid // "x") + "\t" + (.timestamp // "x") + "\t" + $t end
      end
  ' "$t" 2>/dev/null
}

# extract() decides WHEN to speak; this decides WHAT. A turn's prose is usually
# split across several assistant text entries with tool_use entries between them
# — a long answer, an Artifact publish, a closing paragraph. Speaking only the
# last entry meant everything before the tool call went unread. So once extract()
# has settled, collect every text entry back to whichever boundary comes first
# walking backwards:
#
#   1. the last real user message — a non-meta user entry not carrying a
#      tool_result; tool_results, meta injections, and the system/frame-link/mode
#      bookkeeping entries must never be read as a turn boundary; or
#   2. the entry already spoken last time (the uuid in .seen-<sid>).
#
# Boundary 2 is what makes this safe. A turn can resume with no real user message
# in between — a cross-session message, a background task finishing, any meta
# injection — and boundary 1 alone then walks back through turns that were
# already read aloud. Observed 2026-08-12 in three sessions: finance re-spoke
# 6.4k chars of the previous reply, and one session re-spoke a reply from 14
# hours earlier, which is untraceable to anything on screen. Boundary 2 can't be
# fooled by a transcript shape nobody has seen yet: anything at or before the
# seen uuid was spoken, full stop. The seen entry itself is excluded, same as the
# real-user entry is.
#
# Thinking blocks are excluded, and each entry's own text blocks join with "\n"
# exactly as extract() does, so the tail of this always equals extract()'s body
# (the check below relies on it).
gather_turn() {
  jq -rs --arg seen "$last_seen" '
    def realuser: .type == "user"
      and ((.isMeta // false) | not)
      and ((.origin.kind // "human") != "task-notification")
      and ((.message.content | type) == "string"
           or ([.message.content[]? | select(.type == "tool_result")] | length) == 0);
    [.[] | select(((.isSidechain // false) | not)
                  and (.type == "user" or .type == "assistant"))]
    | reverse
    | (map(realuser) | index(true)) as $u
    | (if $seen == "" then null else (map(.uuid == $seen) | index(true)) end) as $s
    | ([$u, $s] | map(select(. != null)) | min) as $i
    | (if $i == null then . else .[0:$i] end)
    | reverse
    | [.[] | select(.type == "assistant")
           | ([.message.content[]? | select(.type == "text") | .text] | join("\n"))]
    | map(select(test("\\S")))
    | join("\n\n")
  ' "$t" 2>/dev/null
}

# Mid-turn counterpart to gather_turn(). Same two boundaries walking backwards
# (last real user message / last spoken uuid), plus ONE extra guard that
# gather_turn does not need:
#
#   only text entries that are ALREADY FOLLOWED BY A TOOL CALL are eligible.
#
# That guard is the whole safety of this path. A turn's real final reply is by
# definition the text that comes after the last tool call, and this hook runs
# async - the final reply can land in the transcript while we are still
# rendering. Without the guard we could mark that reply as spoken, and Stop
# would then skip it: the actual answer would never be read aloud. With it,
# the newest thing this path can ever touch is a mid-turn preamble.
#
# Returns "<uuid>\t<text>". The uuid is the newest ELIGIBLE entry whether or
# not the word filter kept it, so filler that was deliberately skipped is not
# offered again at Stop - "skip" means skip, not "read it later".
gather_midturn() {
  jq -rs --arg seen "$last_seen" --argjson minw "$MINWORDS" '
    def realuser: .type == "user"
      and ((.isMeta // false) | not)
      and ((.origin.kind // "human") != "task-notification")
      and ((.message.content | type) == "string"
           or ([.message.content[]? | select(.type == "tool_result")] | length) == 0);
    def istool: ((.message.content | type) == "array")
      and (((.type == "assistant")
            and ([.message.content[] | select(.type == "tool_use")] | length) > 0)
        or ((.type == "user")
            and ([.message.content[] | select(.type == "tool_result")] | length) > 0));
    [.[] | select(((.isSidechain // false) | not)
                  and (.type == "user" or .type == "assistant"))]
    | reverse
    | (map(realuser) | index(true)) as $u
    | (if $seen == "" then null else (map(.uuid == $seen) | index(true)) end) as $s
    | ([$u, $s] | map(select(. != null)) | min) as $i
    | (if $i == null then . else .[0:$i] end)
    # still newest-first here: drop everything newer than the last tool call
    | (map(istool) | index(true)) as $k
    | (if $k == null then [] else .[$k:] end)
    | reverse
    | [.[] | select(.type == "assistant" and (.message.content | type) == "array")
           | { uuid: (.uuid // ""),
               text: ([.message.content[] | select(.type == "text") | .text] | join("\n")) }]
    | map(select(.text | test("\\S")))
    | if length == 0 then "" else
        (last.uuid) as $mark
        | ( map(select((.text | [splits("[ \t\n]+")]
                              | map(select(length > 0)) | length) >= $minw))
            | map(.text) | join("\n\n") ) as $body
        | if ($body | test("\\S")) then $mark + "\t" + $body else "" end
      end
  ' "$t" 2>/dev/null
}

# Stop fires a beat BEFORE the turn's final text entry hits the transcript
# file (observed: hook grabbed the previous reply at 20:42:17 while the real
# one flushed at 20:42:17.073). So the last text in the file at hook start is
# usually the PREVIOUS turn's reply. Accept an entry only if it
#   (a) appeared after the hook started (definitely this turn's reply), or
#   (b) was already there but is unspoken (uuid != .seen) AND fresh (<120s) —
#       the fast-flush case.
# Stale backlog can never qualify; if nothing fresh lands in 30s, stay silent.
SEEN="$SPEECH_ROOT/.seen-$sid"
last_seen=$(cat "$SEEN" 2>/dev/null || echo "")
# Mid-turn (PostToolUse). Sets $text and falls through to the render pipeline,
# or exits. The Stop gate below is deliberately not consulted: at PostToolUse
# time the newest entry is a tool_use, so extract() would return "" every time.
uuid=""
if [ "$kind" = notify ]; then
  # "Waiting on you in <session>. <what Claude Code said>." The session name
  # comes first because that is the thing the listener has to go find; the
  # message is capped so a prompt quoting a long command stays a sentence.
  nmsg=$(printf '%s' "$input" | jq -r '.message // empty' | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ +//; s/ +$//')
  [ ${#nmsg} -gt 240 ] && nmsg="${nmsg:0:240}"
  [ -n "$nmsg" ] || nmsg="Claude Code needs an answer from you."
  text="Waiting on you in $title. $nmsg"
  echo "$(date) $sid prompt type=$ntype chars=${#text}" >> "$LOG"
fi

if [ "$kind" = reply ] && [ "$event" != "Stop" ]; then
  # Parallel tool calls ("Ran 3 shell commands") fire this hook several times
  # at once. Without a mutex each copy reads the same .seen and queues the same
  # words two or three times. Whoever loses the race just exits - nothing is
  # lost, because .seen only advances when text is actually spoken, so the next
  # winner picks up everything that accumulated.
  MIDLOCK="$SPEECH_ROOT/.mid-$sid.lock"
  if [ -d "$MIDLOCK" ]; then
    lmt=$(stat -f %m "$MIDLOCK" 2>/dev/null || echo 0)
    [ $(( $(date +%s) - lmt )) -gt 600 ] && rmdir "$MIDLOCK" 2>/dev/null
  fi
  mkdir "$MIDLOCK" 2>/dev/null || exit 0
  trap cleanup_all EXIT
  out=$(gather_midturn)
  [ -n "$out" ] || exit 0
  uuid=${out%%$'\t'*}
  body=${out#*$'\t'}
  { [ -z "$body" ] || [ "$body" = "$out" ]; } && exit 0
  text=$body
  printf '%s' "$uuid" > "$SEEN"
  echo "$(date) $sid midturn mode=$WHEN minw=$MINWORDS chars=${#text}" >> "$LOG"
fi

if [ "$kind" = reply ] && [ "$event" = "Stop" ]; then
start_out=$(extract)
start_uuid=${start_out%%$'\t'*}
text=""
for _ in $(seq 1 60); do
  out=$(extract)
  uuid=${out%%$'\t'*}
  rest=${out#*$'\t'}
  ts=${rest%%$'\t'*}
  body=${rest#*$'\t'}
  if [ -n "$body" ] && [ "$body" != "null" ] && [ "$uuid" != "$last_seen" ]; then
    ok=0
    if [ "$uuid" != "$start_uuid" ]; then
      ok=1   # appeared after Stop fired
    else
      entry_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "${ts%%.*}" +%s 2>/dev/null || echo 0)
      age=$(( $(date +%s) - entry_epoch ))
      [ "$age" -le 120 ] && ok=1
    fi
    if [ "$ok" = 1 ]; then
      # a text entry flushes a beat before its sibling tool_use entry
      # (observed ~300ms gap), so "last entry is text" can be a preamble
      # caught mid-flush — accept only if still last after a beat
      sleep 0.5
      [ "$(extract)" != "$out" ] && continue
      # re-read .seen NOW: it was snapshotted before a poll loop that can run
      # 30s, and a mid-turn hook may have spoken (and marked) text in that
      # window — gathering against the stale snapshot re-spoke it (2026-08-25
      # audit, reproduced). Must happen BEFORE the overwrite on the next line,
      # or the boundary would become this entry's own uuid and gather nothing.
      last_seen=$(cat "$SEEN" 2>/dev/null || echo "")
      text=$body
      printf '%s' "$uuid" > "$SEEN"
      break
    fi
  fi
  sleep 0.5
done
if [ -z "$text" ]; then
  echo "--- $(date) $sid no fresh text after polling (start: $start_uuid, seen: $last_seen)" >> "$LOG"
  exit 0
fi

# Widen from the settled entry to the whole turn — but only if the gathered text
# still ENDS with that entry. If it doesn't, the transcript moved under us or the
# shape is unexpected, and the settled entry alone stays the safe answer. (The
# quoted expansion in a case pattern matches literally, so markdown in $text
# can't act as a glob.)
full=$(gather_turn)
case $full in
  *"$text") text=$full ;;
  *) echo "--- $(date) $sid gather_turn tail mismatch, speaking last entry only" >> "$LOG" ;;
esac
fi

# Turn the raw reply into something pleasant to LISTEN to (not read): drop
# fenced code blocks, then in one Unicode-aware perl pass rewrite the bits that
# read terribly aloud, then strip leftover markdown punctuation. perl -CSD so
# emoji match by codepoint. Order matters: links/slash-commands/paths resolve
# before the blanket symbol strip removes their delimiters, and arrows become
# "to" before \p{Extended_Pictographic} would otherwise delete the emoji ones.
#   [text](url) -> text   ·   bare url -> "link"
#   /code-review -> "code review"   ·   ~/a/b/c.swift -> "c.swift"
#   → -> "to"   ·   ✅🚀⏰™ℹ㊙ any emoji + skin-tone/ZWJ/keycap joiners -> removed
# \p{Extended_Pictographic} covers every pictographic emoji (incl. future ones)
# without touching digits/#/*; the second pass mops up flags, modifiers,
# variation selectors, keycap joiners, and bullet/geometric-shape glyphs.
clean=$(printf '%s' "$text" \
  | sed -E '/^[[:space:]]*```/,/^[[:space:]]*```/d' \
  | perl -CSD -pe '
      s/\[([^\]]+)\]\([^)]*\)/$1/g;
      s{https?://\S+}{link}g;
      s{(^|[\s(\[\x60"'\''])/([A-Za-z][\w-]*)(?![\w/])}{$1 . ($2 =~ tr/-/ /r)}ge;
      s{(^|[\s(\[\x60"'\''])((?:~|\.{1,2})?(?:/[\w.\-]+){2,}/?)}{ $1 . (grep { length } split m{/}, $2)[-1] }ge;
      s/[\x{2190}-\x{21FF}\x{27A1}\x{2B05}-\x{2B07}]/ to /g;
      s/\p{Extended_Pictographic}//g;
      s/[\x{1F1E6}-\x{1F1FF}\x{1F3FB}-\x{1F3FF}\x{FE00}-\x{FE0F}\x{200D}\x{20E3}\x{2022}\x{25A0}-\x{25FF}]//g;
    ' \
  | sed -E 's/[*_`#>|]+/ /g' \
  | sed -E 's/^[[:space:]]*[-+][[:space:]]+/ /' \
  | sed -E 's/[[:space:]]+/ /g; s/ +([.,;:!?])/\1/g; s/^ +//; s/ +$//')

# A reply that was entirely fenced code cleans down to nothing; real `say`
# happily renders empty stdin into a 28-byte silent m4a, which queued a
# playable empty row (reproduced 2026-08-25). .seen stays advanced: skipping
# an unspeakable reply is a decision, not a failure.
case $clean in
  *[![:space:]]*) ;;
  *) echo "--- $(date) $sid nothing speakable after cleaning" >> "$LOG"; exit 0 ;;
esac

# one-line preview for the deck's list (project + opening words); truncation
# happens codepoint-aware in the jq below — BSD `cut -c` counts bytes and
# split multi-byte characters into a trailing U+FFFD
preview=$(printf '%s' "$clean" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ +//')

# The id doubles as the filename, and `date +%s` only has 1-second
# resolution, so two replies from ONE session inside the same second used to
# write the same path and the first was silently overwritten — a reply the
# user never heard, with no error anywhere. That is not hypothetical: the
# mid-run PostToolUse speak followed by the Stop speak lands about a second
# apart, which made tests/run-hook-tests.sh test 8 fail ~50% of the time
# (diagnosed 2026-08-23). Walking the stamp forward keeps the documented
# <epoch>-<sid> queue contract intact and keeps ids monotonic; `created`
# moves with it, which is what the deck should show anyway.
# The probe alone is a TOCTOU: while a render is in flight the files are still
# named .tmp-*, so a second hook in the same second saw an empty slot and both
# wrote the same final path (reproduced 2026-08-25: a PostToolUse and a Stop
# 0.05s apart destroyed the mid-turn reply, both logging success on one id).
# mkdir is the atomic claim; the EXIT trap and the 2-day sweep free it.
stamp=$(date +%s)
while [ -e "$QUEUE/${stamp}-${sid}.json" ] || [ -e "$QUEUE/${stamp}-${sid}.m4a" ] \
   || ! mkdir "$QUEUE/.claim-${stamp}-${sid}" 2>/dev/null; do
  stamp=$((stamp + 1))
done
id="${stamp}-${sid}"
CLAIMDIR="$QUEUE/.claim-$id"
trap cleanup_all EXIT

# Reply time on the deck row AND in the spoken text, derived from `created`
# (2026-09-03, Adam). This replaces the global "open every substantial reply
# with [H:MM am]" rule: CC 2.1.246 prints the finish time on the terminal's
# duration line, so the reply text no longer carries one, and the deck lost
# its "[10:50 am] TL..." label. Skipped when the text already opens with a
# stamp (sessions started before the rule was retired).
tstamp=$(date -r "$stamp" "+%-I:%M %p" | tr 'A-Z' 'a-z')
case $clean in
  \[*[0-9]:[0-9][0-9]\ [ap]m\]*) ;;
  *) [ "$kind" = reply ] && { clean="[$tstamp] $clean"; preview="[$tstamp] $preview"; } ;;
esac

# wake the deck before rendering so it's already watching when the audio
# lands — a cold start mid-render used to miss fresh arrivals
app_ok=1
open -g -a "$APP" 2>>"$LOG" || app_ok=0

# audio first, manifest second, both via atomic rename — the deck only acts
# on .json files whose .m4a already exists
# Kokoro renders ~12dB quieter than say; normalize to the -16 LUFS speech
# standard while encoding. afconvert (no gain stage) only if ffmpeg is missing.
FFMPEG=$(command -v ffmpeg || echo /opt/homebrew/bin/ffmpeg)
convert_wav() {
  if [ -x "$FFMPEG" ]; then
    "$FFMPEG" -hide_banner -loglevel error -y -i "$1" \
      -af "loudnorm=I=-16:TP=-1.5:LRA=11" -c:a aac -b:a 96k "$2" >>"$LOG" 2>&1
  else
    afconvert -f m4af -d aac "$1" "$2" >>"$LOG" 2>&1
  fi
}

# Warm daemon (tts-daemon.py, launched by launchd) renders in ~0.5s vs the ~3s
# cold CLI. Ask it via a request file, but only when its heartbeat is fresh;
# on a stale/absent heartbeat, timeout, or error, fall through to the cold CLI.
# Both paths write the same .tmp-$id.wav, so the convert + say fallback below
# stay identical.
render_via_daemon() {   # writes "$QUEUE/.tmp-$id.wav"; returns 0 on success
  [ -f "$ALIVE" ] || return 1
  local amt; amt=$(stat -f %m "$ALIVE" 2>/dev/null || echo 0)
  [ $(( $(date +%s) - amt )) -le 8 ] || return 1
  mkdir -p "$RENDER"
  local req="$RENDER/$id.req" mark="$RENDER/$id.done"
  rm -f "$mark"
  jq -n --arg text "$clean" --arg voice "$KOKORO_VOICE" --arg out "$QUEUE/.tmp-$id.wav" \
    '{text:$text, voice:$voice, out:$out}' > "$RENDER/.tmp-$id.req" || return 1
  mv "$RENDER/.tmp-$id.req" "$req"
  # Render time tracks text length (~285 chars/s measured on this Mac), so a flat
  # 20s ceiling was already marginal at 4k chars and full-turn text goes well past
  # it — every long reply would have fallen back to the cold CLI and re-rendered
  # the same words. Scale it: 15s slack + 1s per 80 chars (3x slower than observed),
  # in 0.05s ticks. A DEAD daemon is still bounded to ~8s by the liveness re-check
  # below; only a slow-but-alive one earns the extra grace.
  local cap=$(( 300 + ${#clean} / 4 ))
  local i=0
  while [ ! -f "$mark" ]; do
    sleep 0.05; i=$((i + 1))
    [ "$i" -gt "$cap" ] && { rm -f "$req"; return 1; }
    if [ $(( i % 40 )) -eq 0 ]; then                          # re-check liveness ~every 2s
      amt=$(stat -f %m "$ALIVE" 2>/dev/null || echo 0)
      [ $(( $(date +%s) - amt )) -le 8 ] || { rm -f "$req"; return 1; }
    fi
  done
  local st; st=$(cat "$mark" 2>/dev/null); rm -f "$mark"
  [ "$st" = ok ] && [ -s "$QUEUE/.tmp-$id.wav" ]
}

rendered=0
engine_used=say
t0=$(date +%s)
if [ "$ENGINE" = kokoro ] && [ -x "$KOKORO_BIN" ]; then
  if render_via_daemon; then
    engine_used=kokoro-warm
  else
    "$KOKORO_BIN" --model "$KOKORO_MODEL" --voice "$KOKORO_VOICE" --join_audio \
         --file_prefix "$QUEUE/.tmp-$id" --text "$clean" >>"$LOG" 2>&1 \
      || true
    engine_used=kokoro-cold
  fi
  if [ -s "$QUEUE/.tmp-$id.wav" ] && convert_wav "$QUEUE/.tmp-$id.wav" "$QUEUE/.tmp-$id.m4a"; then
    rendered=1
  else
    echo "--- $(date) $sid kokoro render failed, falling back to say" >> "$LOG"
    rm -f "$QUEUE/.tmp-$id.m4a"
    engine_used=say
  fi
  rm -f "$QUEUE/.tmp-$id.wav"
fi
if [ "$rendered" != 1 ]; then
  say_voiceargs
  if ! printf '%s' "$clean" | say "${VOICEARGS[@]}" "${RATEARGS[@]}" -o "$QUEUE/.tmp-$id.m4a" --data-format=aac; then
    echo "--- $(date) $sid say render failed" >> "$LOG"
    rm -f "$QUEUE/.tmp-$id.m4a"
    # roll .seen back to what it was when this hook gated (only if no later
    # hook has advanced it), so a transient TTS failure does not permanently
    # consume the reply — the stated .seen design is "advances when text is
    # actually spoken". The success path still writes .seen at gate time,
    # which is what keeps concurrent gathers from double-speaking.
    [ -n "$uuid" ] && [ "$(cat "$SEEN" 2>/dev/null)" = "$uuid" ] && printf '%s' "$last_seen" > "$SEEN"
    exit 0
  fi
fi

# the user may have hit the power button while a long reply rendered
if [ -f "$HOME/.claude/speak-off" ]; then
  echo "--- $(date) $sid speech turned off mid-render, dropping" >> "$LOG"
  rm -f "$QUEUE/.tmp-$id.m4a"
  exit 0
fi
mv "$QUEUE/.tmp-$id.m4a" "$QUEUE/$id.m4a"

# full cleaned text rides along so the app can re-render queued items when a
# new voice is picked (older manifests without it just keep their audio)
if jq -n --arg session "$sid" --arg project "$proj" --arg title "$title" --arg preview "$preview" --arg text "$clean" --argjson created "$stamp" \
  '{session: $session, project: $project, title: $title, preview: ($preview | .[0:120]), text: $text, created: $created}' \
  > "$QUEUE/.tmp-$id.json"; then
  mv "$QUEUE/.tmp-$id.json" "$QUEUE/$id.json"
else
  # a truncated manifest must not be promoted, and the orphan m4a would hold
  # its id slot until the 2-day sweep; roll .seen back (only if still ours)
  # so the reply is not permanently consumed by a failed write
  rm -f "$QUEUE/.tmp-$id.json" "$QUEUE/$id.m4a"
  [ -n "$uuid" ] && [ "$(cat "$SEEN" 2>/dev/null)" = "$uuid" ] && printf '%s' "$last_seen" > "$SEEN"
  echo "--- $(date) $sid manifest write failed" >> "$LOG"
  exit 0
fi

# ONE success line per spoken reply. Until 2026-08-17 this log recorded only
# failures, so a healthy install produced an EMPTY hook.log and INSTALL.md's
# verification read that as "hook never fired" (Sasha's install report, 3b).
echo "$(date) $sid spoke $id engine=$engine_used chars=${#clean} secs=$(( $(date +%s) - t0 ))" >> "$LOG"

if [ "$app_ok" != 1 ]; then
  # fallback if the app is missing: serialized afplay (lock dir = the queue's mutex)
  echo "--- $(date) $sid SpeakySpeak missing, afplay fallback" >> "$LOG"
  # same staleness breaker as MIDLOCK: a hook killed while holding the lock
  # otherwise blocks every later fallback forever (broken-install path, the
  # population least able to debug it)
  if [ -d "$SPEECH_ROOT/.lock" ]; then
    llmt=$(stat -f %m "$SPEECH_ROOT/.lock" 2>/dev/null || echo 0)
    [ $(( $(date +%s) - llmt )) -gt 600 ] && rmdir "$SPEECH_ROOT/.lock" 2>/dev/null
  fi
  i=0
  while ! mkdir "$SPEECH_ROOT/.lock" 2>/dev/null; do
    sleep 0.5
    i=$((i + 1))
    [ "$i" -gt 600 ] && exit 0
  done
  trap 'rmdir "$SPEECH_ROOT/.lock" 2>/dev/null; cleanup_all' EXIT
  afplay "$QUEUE/$id.m4a"
fi
exit 0
