# Manual VoiceOver checklist

The 1.2.7 code-level VoiceOver pass (2026-08-25) labeled everything and made the
hover-only actions reachable, but some behavior only a live VoiceOver run can
prove. Turn VO on with Command+F5 and walk this list; about six minutes.
Each line: where, what to do, what you should hear.

## Menu bar
1. VO+M twice, arrow to the SpeakySpeak icon. Expect "SpeakySpeak, playing,
   3 replies queued" (state and count vary with reality; before 1.2.7 this was
   an unnamed button).
2. Mute the app, same stop. Expect "muted, queuing silently" plus the count.
3. VO+Space on the icon: the full deck opens and VO focus moves into it.
4. VO+Shift+M on the icon: the Mute / Settings / Quit menu, each item by title.

## The full deck
5. VO+Right through the header: "Mute, button" (or "Unmute"), "Volume,
   NN percent", "Playback speed, button".
6. On Volume, VO+Up: level rises 5% and the new percentage is spoken.
7. Arrow into the now-playing card: "Now playing. <session title>" as a
   HEADING (VO+Command+H should jump to it), then time, "Reply 2 of 7 from
   this session", the preview text.
8. The scrubber: "Playback position, 0:42 of 2:15". VO+Up seeks forward 10s.
9. Transport row: "Back 10 seconds", "Pause"/"Play", "Forward 10 seconds",
   "Play next"/"Skip". VO+Space on Pause: the label flips to Play on the same
   element without focus moving.
10. Toolbar: "Sort the queue", "Clear played", "Delete all replies, played
    and queued", "Settings". Clear played reports dimmed with nothing played.
11. Open the sort menu with VO+Space: "Group by" and "Order by" pickers with
    their current selection spoken.
12. A queue row is ONE stop: "Next up. events-site. <preview...>" (state
    first). No stray "checkmark" or bare image stops anywhere in the list.
13. THE KEY ONE — on a row, open the VO actions menu (VO+Command+Space) with
    the pointer nowhere near the row. Expect "Play now", "Mute this session",
    "Remove from the queue". Fire each once; the action must actually happen.
    (These buttons only exist under a hovering pointer, so the actions menu is
    the whole accessibility path.)
14. Same on a session header row: "Play this session next" and "Remove this
    session's queued replies" in the actions menu.
15. With an update waiting, the footer: "Update X available, open Settings".

## The mini player
16. While a reply plays, the VO window list (VO+F2 twice): a window named
    "The mini player".
17. Arrow through it: session title, "Now reading: ...", "Restart this reply,
    or go back one", "Back 10 seconds", "Pause"/"Play", "Forward 10 seconds",
    "Skip this reply", "Hide the mini player".
18. VO+Space the play button: label flips Pause/Play in place.
19. The progress line: "Playback position, 0:42 of 2:15"; VO+Up seeks +10s.

## Settings
20. Window announces as "SpeakySpeak Settings".
21. Speech: "Speak Claude's replies, checkbox", "Voice, pop up", "Preview
    voice, button", "Read replies, pop up".
22. Preview button label becomes "Stop preview" while playing.
23. Appearance: "Mini player, pop up", "Accent colour hue, slider",
    "Reset accent colour to the default, button", "Show mini player, pop up".
24. About: press "Check for updates", hold focus still. Expect "SpeakySpeak is
    up to date" spoken without focus moving.
25. Report an issue: press the Claude button. Expect "Prompt copied. Paste it
    into Claude Code." spoken.

## Sanity sweep
26. Anywhere in the deck, listen for a stop that is only "image" or an SF
    Symbol name — any such stop is a decoration that still needs hiding.
