# SpeakySpeak: how to work with it

Install instructions are in [INSTALL.md](INSTALL.md). This is the guide for after it's running: how to set up Claude Code so listening actually works, and what every setting does.

- [Set this up first](#set-this-up-first)
- [Timestamps in your replies](#timestamps-in-your-replies)
- [A suggested way to work](#a-suggested-way-to-work)
- [Every setting, explained](#every-setting-explained)
- [The sort menu](#the-sort-menu)
- [Plain text knobs](#plain-text-knobs)
- [When something seems wrong](#when-something-seems-wrong)

## Set this up first

Three changes, about five minutes, and they matter more than anything else in this guide.

1. **Add the timestamp rule to your `CLAUDE.md`** so every reply says when it was written. See below.
2. **Pick a voice you can stand for hours.** Settings ▸ Voice, press ▶ to hear each one. The default is `bf_lily`.
3. **Decide when it should read.** Settings ▸ Read replies. If you start long runs and walk away, choose "As it works, skipping short lines" so you hear progress instead of silence.

## Timestamps in your replies

If you run more than one Claude Code session, replies pile up while you're away. Ten minutes later you're listening to a queue and every reply sounds equally current, when some of them are half an hour old.

The fix is to have Claude say the time out loud. Add this to `~/.claude/CLAUDE.md`:

```markdown
- **Timestamp substantial replies.** Open any reply longer than a few lines with
  `[H:MM am/pm]` on its own first line, before anything else. Get the time by
  reading the clock (`date "+%-I:%M %p" | tr 'A-Z' 'a-z'`), never by guessing or
  reusing an earlier one. One-line answers don't need it.
```

Now every spoken reply opens with "three forty-two p m" and a backlog becomes legible by ear. The time also shows in the floating panel and in each row of the queue.

**Why a rule and not a setting.** Claude Code has a built-in `showMessageTimestamps` setting, and it's worth turning on. But its display is gated server side and may show nothing for your account, so the `CLAUDE.md` rule is the one that reliably works today. Leave the setting on so the native stamps appear whenever that gate opens.

`showTurnDuration` is a separate setting that does work, and it pairs well: the start time plus "Cooked for 4m 12s" tells you when the answer actually landed.

## A suggested way to work

None of this is required. One session works fine on its own. This is the setup that made SpeakySpeak worth building.

**A window per project, each its own color.** In iTerm2: Session ▸ Edit Session ▸ Tab Color. When you hear a reply, you already know which window to look at.

**Name your sessions.** `/rename wedding` gives that session a name, and the panel and the floating player use it instead of the folder name. Worth doing when two sessions live in the same repo.

**Start long runs, then walk away.** Set Read replies to "As it works, skipping short lines" and you'll hear the steps that matter without hearing "Let me check that."

**Group by session when several are running.** Sort menu ▸ Group by ▸ Session, and Order by ▸ Oldest first. Each session's replies then play as one run, in the order they happened, instead of all the sessions interleaved newest first. See [the sort menu](#the-sort-menu).

**Two Macs? Give each one a different voice.** Settings ▸ Voice on each machine. You'll know which Mac is talking without looking. If both drive the same AirPods, put the other Mac's Tailscale IP in `~/.claude/speak-peer` on each and they'll take turns instead of cutting each other off.

## Every setting, explained

Open Settings from the gear on the panel's "Up next" line, or right-click the menu-bar icon.

### Speech

| Setting | What it does |
| --- | --- |
| **Speak Claude's replies** | The master switch. Off means replies aren't turned into audio at all. Different from Mute, which keeps building the queue silently. |
| **Read replies** | *When* it speaks. **When Claude finishes** reads a reply once Claude stops and waits for you. **As it works, skipping short lines** reads each step of a long run but stays quiet for short connective lines, which matters when Claude asks you to do something twenty minutes into a run that hasn't ended. **As it works, every line** reads all of them. The two "as it works" modes need the PostToolUse hook registered (INSTALL.md step 5). |
| **Voice** | Which voice speaks. Kokoro voices when the neural engine is installed, otherwise your macOS voices. ▶ previews the selected one. Changing it re-renders whatever is still queued, so you don't get a mix. |
| **Rate** | Words per minute, for macOS voices only. Kokoro speed is the playback speed selector instead. |

### Playback

| Setting | What it does |
| --- | --- |
| **Speed** | 0.8× to 2×. Also on the panel, as the pill next to the volume slider. |
| **Volume** | Playback volume. Every reply is loudness-normalized before it plays, so 100% is normal speech level and replies match each other. |
| **Mute** | The speaker icon. Replies keep rendering and queueing, nothing plays. Survives restarts. |

### Appearance

| Setting | What it does |
| --- | --- |
| **Menu-bar icon** | The Sy mark or a speaker glyph. Either one carries the queue count and pulses while speaking. |
| **Reading panel style** | **Liquid Glass** (macOS 26+) or **Frosted**, the solid card. Switch to Frosted if the glass is hard to read over your wallpaper. |
| **When it shows** | **Only while speaking** appears with a reply and fades after. **Always visible** keeps a small controller on screen. Either way you can drag it anywhere and it stays there. |

### Controls on the panel

The row above the queue, on the "Up next" line. Hovering any of them replaces the label with what it does.

| Control | What it does |
| --- | --- |
| **⇅ Sort** | Grouping and play order. [Details below](#the-sort-menu). |
| **Sweep** | Clears every reply you've already heard. |
| **Trash** | Deletes everything, played and queued. |
| **Gear** | Settings. |

Hovering a row in the queue gives you **Play now** and **Remove** for that one reply. Hovering a session header gives you **Play this session next** and **Remove this session's queued replies**.

### Elsewhere

| Control | What it does |
| --- | --- |
| **Skip** (⏭) | Stops the current reply and moves to the next one. Unlike Mute, it doesn't stop the pipeline, it just drops the one you don't want. |
| **⌃⌥⌘Space** | Quiet now, from any app. Silences the current reply and moves on. Does nothing when nothing is playing. |
| **AirPods stem** | One click pauses, two skips ahead, three restarts or steps back. |

## The sort menu

The ⇅ button. Two settings, and they're remembered.

**Group by**: None or Session.
**Order by**: Newest first or Oldest first.

Sorting the list is also sorting the queue: replies are read from the top down.

The default is None and Newest first, a flat list with the newest reply next. That's the right setting when one session is talking to you.

**When several sessions run at once, switch to Session and Oldest first.** Each session's replies are a sequence: one agent lands, then another, and reply eight only makes sense if you heard reply one. Flat and newest first plays that story backwards with another project's replies dropped into the middle. Grouped by session, each session plays as one run in the order it happened, one session at a time, and a new reply extends its own session's run instead of jumping the queue.

Group headers show the session name, how many replies are waiting, and the time span. The now playing card shows "2 of 6" so you know how much of a session's story is left.

## Plain text knobs

The Settings window writes plain files in `~/.claude/`, so shell edits and the GUI stay in sync. You never have to touch these, but they're there.

| File | What it does |
| --- | --- |
| `speak-off` | Exists = nothing is rendered at all. A hard kill from the shell. |
| `speak-when` | `end`, `substantial`, or `all`. Absent means `end`. |
| `speak-min-words` | Word threshold for `substantial` mode. Default 15. |
| `speak-engine` | `kokoro` or `say`. Absent picks Kokoro when it's installed. |
| `speak-voice-kokoro` | Kokoro voice name. Default `bf_lily`. |
| `speak-voice` | macOS voice name. Absent probes for the best installed one. |
| `speak-rate` | Words per minute for macOS voices. |
| `speak-peer` | The other Mac's Tailscale IP, so two decks take turns on one pair of AirPods. |
| `speak-lead-in` | Seconds of silence before speech when the deck has been quiet a while, so shared AirPods finish switching to this Mac before the first word. Default 1.2. Set `0` to turn it off. |

## When something seems wrong

Logs live in `/tmp/claude-speech/`: `hook.log` for rendering, `deck.log` for the app.

- **Nothing is spoken.** Check `~/.claude/speak-off` doesn't exist, then check the panel isn't muted, then look at `hook.log`.
- **A reply was skipped.** Look for it in `hook.log`. Every spoken reply logs a line.
- **It reads things you don't want.** Set Read replies back to "When Claude finishes."
- **The voice sounds wrong or slow.** The neural voice may have fallen back to macOS voices. `hook.log` records which engine each reply used.

Still stuck, or something's just annoying? Email [hi@speakyspeak.com](mailto:hi@speakyspeak.com). Settings ▸ About & support has two buttons that write the report for you, including one that hands your own Claude Code the job of gathering the logs.
