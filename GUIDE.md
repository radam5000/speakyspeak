# SpeakySpeak: the full guide

Install instructions are in [INSTALL.md](INSTALL.md), and [speakyspeak.com/howto](https://speakyspeak.com/howto) is the five-minute visual tour with real screenshots. This is the full reference for after it's running: how to set up Claude Code so listening actually works, and what every setting does.

- [How SpeakySpeak works](#how-speakyspeak-works)
- [Set this up first](#set-this-up-first)
- [Timestamps in your replies](#timestamps-in-your-replies)
- [A suggested way to work](#a-suggested-way-to-work)
- [Every setting, explained](#every-setting-explained)
- [The sort menu](#the-sort-menu)
- [Plain text knobs](#plain-text-knobs)
- [Changing it yourself](#changing-it-yourself)
- [When something seems wrong](#when-something-seems-wrong)
- [Feedback: how to reach me and what happens next](#feedback-how-to-reach-me-and-what-happens-next)

## How SpeakySpeak works

The whole trip, from Claude finishing a reply to you hearing it:

1. **Claude Code finishes a reply.** Claude Code runs a small script at that moment, a Stop hook that install.sh put in `~/.claude/hooks/speak-reply.sh`. In the "as it works" read modes it also runs after each tool call, so long runs are read as they happen. When Claude is waiting on you (a permission question, say), it plays a chime and queues "Waiting on you in" plus the session name.
2. **The hook picks the words.** It reads the session's transcript and takes everything Claude wrote since your last message, so a reply split around a tool call is read in one piece and nothing is read twice.
3. **It cleans them up for listening.** Code blocks are dropped. Links read as their text, bare web addresses as "link", file paths as just the file name, slash commands as words ("code review"), arrows as "to", and emoji and markdown symbols disappear. The reply opens with the time it finished, and with the session name too if you turn that on.
4. **Your Mac turns it into audio.** With the Kokoro neural voice installed, a small always-on helper renders it in about half a second; otherwise the macOS voice reads it. The audio is evened out to normal speech loudness. Rendering happens on your Mac: the text of your replies never leaves it.
5. **It joins the queue.** Each reply becomes an audio file plus a note with its session, time and text in `/tmp/claude-speech/queue/`.
6. **The deck plays them, one at a time.** The menu-bar icon shows how many are waiting. Click it for the full deck: the reply playing now, the list of what's next, and controls. The mini player appears while a reply plays (or always, if you set it). Nothing ever talks over anything else, and ⌃⌥⌘Space silences the current reply from any app.

A few things sit around that loop:

- **The Claude strip** (optional, Settings ▸ Claude). Along the bottom of the deck and the mini player: three dials for your plan usage, three dots for status.claude.com, and your Claude Code version. It asks Anthropic for your usage with your own Claude Code sign-in, every 5 minutes. A blue NEW badge means Claude Code just updated itself, or a newer one is out than the one you have; a blue dot on the menu-bar icon means the same, a red one means a Claude service has trouble. The circular arrow checks everything again right away, reading the newest Claude Code version straight from GitHub.
- **Updates.** Once a day SpeakySpeak checks whether a new version is out. When one is, an ↑ appears next to the menu-bar icon and Settings ▸ About has an Update button. It pulls the new version into the folder you installed from, rebuilds and relaunches in about a minute, and keeps any changes you made yourself (see [Changing it yourself](#changing-it-yourself)).
- **Two Macs, one pair of AirPods.** Put the other Mac's Tailscale address in `~/.claude/speak-peer` on each. Before one starts a reply by itself, it asks the other whether it is speaking and waits its turn; if both want to start at the same moment, one goes first. This needs Tailscale running on both Macs: if one can't reach the other, each speaks as if it were alone.

What leaves your Mac: the daily update check, and, only if you turn on the Claude strip, the usage, status and Claude Code version checks. The app sends nothing about you or your replies anywhere.

## Set this up first

Two changes, about five minutes, and they matter more than anything else in this guide.

1. **Pick a voice you can stand for hours.** Settings ▸ Voice, press ▶ to hear each one. The default is `bf_lily`.
2. **Decide when it should read.** Settings ▸ Read replies. If you start long runs and walk away, choose "As it works, skipping short lines" so you hear progress instead of silence.

## Timestamps in your replies

If you run more than one Claude Code session, replies pile up while you're away. Ten minutes later you're listening to a queue and every reply sounds equally current, when some of them are half an hour old.

SpeakySpeak does this for you: every spoken reply opens with the time it finished, "three forty-two p m", so a backlog is legible by ear. The same time shows in the mini player and in each row of the queue. Nothing to set up.

If you added the old `CLAUDE.md` rule that had Claude open each reply with `[H:MM am/pm]`, you can take it out. It still works (a reply that already opens with a time is not stamped twice), it just costs Claude a `date` call every reply.

Claude Code's own `showMessageTimestamps` setting puts times in the terminal too; its display is gated server side, so it may show nothing for your account yet.

`showTurnDuration` is a separate setting that does work, and it pairs well: the start time plus "Cooked for 4m 12s" tells you when the answer actually landed.

## A suggested way to work

None of this is required. One session works fine on its own. This is the setup that made SpeakySpeak worth building.

**A window per project, each its own colour.** When you hear a reply, you already know which window to look at. This is how Adam runs it in iTerm2, and your Claude can set it up for you (INSTALL.md offers it once at the end of the install). Four settings make the whole title bar take the colour, with nothing grey left over; set them once, then right-click any window's title bar and pick a colour dot. New windows open uncoloured.

1. Settings ▸ Appearance ▸ General ▸ Theme: **Minimal**.
2. Settings ▸ Appearance ▸ Tabs ▸ check **Show tab bar even when there is only one tab**.
3. Settings ▸ Advanced, search `left of the tab bar`, set "In the Minimal theme, should the area left of the tab bar be treated as part of the first tab?" to **Yes**.
4. Optional: Settings ▸ Advanced, search `new tab button`, set "Remove the new tab button from horizontal tab bars?" to **Yes**, if you never use the + button.

Windows already open keep the old look until you reopen them. The same four from the terminal, with iTerm2 quit first:

```sh
defaults write com.googlecode.iterm2 TabStyleWithAutomaticOption -int 5
defaults write com.googlecode.iterm2 HideTab -bool false
defaults write com.googlecode.iterm2 MinimalTabStyleTreatLeftInsetAsPartOfFirstTab -bool true
defaults write com.googlecode.iterm2 RemoveAddTabButton -bool true   # the optional step 4
```

**Name your sessions.** `/rename newsletter` gives that session a name, and the full deck and the mini player use it instead of the folder name. Worth doing when two sessions live in the same repo.

**Hear which session is talking.** Settings ▸ Speech ▸ **Say the session name first**. Every reply then opens with its session name (the `/rename` name, or the folder), so when several sessions speak in a row you know which project each one is about without looking.

**Start long runs, then walk away.** Set Read replies to "As it works, skipping short lines" and you'll hear the steps that matter without hearing "Let me check that."

**Clear the list before you walk away.** While you're at the computer reading everything as it lands, pause playback. When you kick off runs and leave, clear the list first (the trash on the Up next line, or the sweep for just the played ones): once you've read everything there's no harm in it, and every reply you hear after that is news, not backlog.

**Group by session when several are running.** Sort menu ▸ Group by ▸ Session, and Order by ▸ Oldest first. Each session's replies then play as one run, in the order they happened, instead of all the sessions interleaved newest first. See [the sort menu](#the-sort-menu).

**Two Macs? Give each one a different voice.** Settings ▸ Voice on each machine. You'll know which Mac is talking without looking. If both drive the same AirPods, put the other Mac's Tailscale IP in `~/.claude/speak-peer` on each and they'll take turns instead of cutting each other off.

## Every setting, explained

Open Settings from the gear on the full deck's "Up next" line, or right-click the menu-bar icon.

### Speech

| Setting | What it does |
| --- | --- |
| **Speak Claude's replies** | The master switch. Off means replies aren't turned into audio at all. Different from Mute, which keeps building the queue silently. |
| **Read replies** | *When* it speaks. **When Claude finishes** reads a reply once Claude stops and waits for you. **As it works, skipping short lines** reads each step of a long run but stays quiet for short connective lines, which matters when Claude asks you to do something twenty minutes into a run that hasn't ended. **As it works, every line** reads all of them. install.sh registers the PostToolUse hook these need (INSTALL.md step 5 checks it). |
| **Voice** | Which voice speaks. Kokoro voices when the neural engine is installed, otherwise your macOS voices. ▶ previews the selected one. Changing it re-renders whatever is still queued, so you don't get a mix. |
| **Rate** | Words per minute, for macOS voices only. Kokoro speed is the playback speed selector instead. |
| **Say the session name first** | Every reply opens with its session name, so several sessions speaking in a row are easy to tell apart. |
| **Read scripted runs too (claude -p)** | Off by default: runs started with `claude -p` (scripts, scheduled jobs) or by programs built on the Agent SDK are not read aloud. Turn it on if the app you chat in runs Claude that way. The terminal, the desktop app, VS Code and Cursor are always read. |

### Playback

Speed, volume and mute live on the full deck itself, not in Settings: the speaker icon mutes, the slider sets volume, and the pill next to it cycles speed from 0.8× to 2×. Every reply is loudness-normalized before it plays, so 100% is normal speech level and replies match each other. All three persist across restarts.

### Appearance

| Setting | What it does |
| --- | --- |
| **Mini player** | **Classic**, **Glassy** (the default), or **Glassier**. Classic is a solid card that reads the same on any wallpaper. Glassy is translucent and adapts itself to what is behind it. Glassier is more transparent still. Both glass looks need macOS 26. |
| **Accent colour** | The orange used throughout the app. Most of the slider sweeps through colours at a fixed saturation and brightness, so any choice keeps the same muted feel; the last stretch leaves colour behind and runs white to grey to black. Reset returns the original terracotta. |
| **Show mini player** | **Only while speaking** appears with a reply and fades after. **Always visible** keeps a small controller on screen. Either way you can drag it anywhere and it stays there. |

### Claude

| Setting | What it does |
| --- | --- |
| **Show Claude usage, status and version in the deck** | Off by default. Turns on the Claude strip: usage dials, status dots and your Claude Code version along the bottom of the deck and the mini player. It uses your Claude Code sign-in to ask Anthropic for your usage. See [How SpeakySpeak works](#how-speakyspeak-works). |

### About

| Row | What it does |
| --- | --- |
| **Check for updates** | Checks for a new version now (it also checks by itself once a day). When one is out, the row becomes an Update button. |
| **How it works** | Opens this guide inside the app. |
| **How to use it** | Opens the five-minute visual tour on speakyspeak.com. |
| **What's new** | Opens the release notes. |

### Report an issue

Two buttons: **Email draft** opens an email to hi@speakyspeak.com with your version, engine and recent log lines filled in, and **Claude draft** copies a prompt that has your own Claude Code gather the logs and write the report. More in [Feedback](#feedback-how-to-reach-me-and-what-happens-next).

### Controls on the full deck

The row above the queue, on the "Up next" line. Hovering any of them replaces the label with what it does.

| Control | What it does |
| --- | --- |
| **⇅ Sort** | Grouping and play order. [Details below](#the-sort-menu). |
| **Clear played** | Clears every reply you've already heard. |
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

Group headers show the session name, how many replies are waiting, and the time span. The now-playing card shows "2 of 6" so you know how much of a session's story is left.

## Plain text knobs

The Settings window writes plain files in `~/.claude/`, so shell edits and the GUI stay in sync. You never have to touch these, but they're there.

| File | What it does |
| --- | --- |
| `speak-off` | Exists = nothing is rendered at all. A hard kill from the shell. |
| `speak-name-first` | Exists = every reply opens with its session name. Settings ▸ Speech ▸ Say the session name first. |
| `speak-headless` | Exists = `claude -p` and Agent SDK runs are read aloud too (they are quiet by default). Settings ▸ Speech ▸ Read scripted runs too. |
| `SPEAKYSPEAK_QUIET=1` (an environment variable, not a file) | Set in a process, the hook exits at once for that Claude Code run only, whatever kind of run it is. Scripted `claude -p` runs are already quiet, so this is for the rare job that starts an ordinary interactive session. |
| `speak-when` | `end`, `substantial`, or `all`. Absent means `end`. |
| `speak-min-words` | Word threshold for `substantial` mode. Default 15. |
| `speak-engine` | `kokoro` or `say`. Absent picks Kokoro when it's installed. |
| `speak-voice-kokoro` | Kokoro voice name. Default `bf_lily`. |
| `speak-voice` | macOS voice name. Absent probes for the best installed one. |
| `speak-rate` | Words per minute for macOS voices. |
| `speak-peer` | The other Mac's Tailscale IP, so the two Macs take turns on one pair of AirPods. |
| `speak-prompt-chime` | Path to a sound file played when Claude is waiting on you. Absent means the macOS Hero sound. |
| `speak-lead-in` | Seconds of silence before speech when the app has been quiet a while, so shared AirPods finish switching to this Mac before the first word. Default 1.2. Set `0` to turn it off. |

## Changing it yourself

The whole thing is a few shell scripts and one Swift file, and asking your Claude to change it (what gets read, how it sounds, when it speaks) is the intended way to customize it. Two rules keep your changes through updates:

- **Try a knob first.** Most wishes are a file above or a Settings row, and those survive everything.
- **Change the clone, not the installed copy, and commit.** Edit the files in the folder you installed from, commit there, and run `./install.sh`. The files in `~/.claude/hooks/` are overwritten on every update (an edited one is kept aside as `.mine-<date>`, but it stops running).

When an update arrives, your commits and uncommitted edits are carried over on top of it. If a change of yours and the update touch the same lines, the update stops, leaves your copy exactly as it was, and Settings ▸ About gives you a prompt that has your Claude merge the two.

## When something seems wrong

Logs live in `/tmp/claude-speech/`: `hook.log` for rendering, `deck.log` for the app.

- **Nothing is spoken.** Check `~/.claude/speak-off` doesn't exist, then check the full deck isn't muted, then look at `hook.log`.
- **A reply was skipped.** Look for it in `hook.log`. Every spoken reply logs a line.
- **An app you chat in is never read aloud.** If `hook.log` says "scripted run ... not read aloud", the app runs Claude with `claude -p`. Turn on Settings ▸ Speech ▸ Read scripted runs too.
- **It reads things you don't want.** Set Read replies back to "When Claude finishes."
- **The voice sounds wrong or slow.** The neural voice may have fallen back to macOS voices. `hook.log` records which engine each reply used.

Still stuck, or something's just annoying? Email [hi@speakyspeak.com](mailto:hi@speakyspeak.com). Settings ▸ Report an issue has two buttons ("Email draft" and "Claude draft") that write the report for you, including one that hands your own Claude Code the job of gathering the logs.

## Feedback: how to reach me and what happens next

I'm Adam, and I made SpeakySpeak. Bugs, ideas, questions, things that just bug you: I want all of it.

**Three ways to reach me:**

- **Email** [hi@speakyspeak.com](mailto:hi@speakyspeak.com). Any address at speakyspeak.com reaches me too.
- **From the app:** Settings ▸ Report an issue. **Email draft** fills in your version, engine and recent log lines for you; **Claude draft** has your own Claude Code gather the logs and write it.
- **On GitHub:** open an issue at [github.com/radam5000/speakyspeak](https://github.com/radam5000/speakyspeak/issues) if you'd rather it be public.

**What happens next:**

1. Within a couple of minutes you get an automatic "got it" email, so you know it arrived.
2. I read every message myself and write back personally.
3. When your fix or idea ships, you hear from me again. If you helped, I'd like to thank you by name in the credits; say so if you'd rather I didn't.

**Your privacy:** your email address stays in my mailbox and is never published. Your name appears only in the credits, and not if you tell me no. When a report becomes a public GitHub issue, it's a paraphrase of the technical part only. The app itself sends nothing; there is no telemetry.
