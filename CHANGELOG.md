# Changelog

What changed in each SpeakySpeak release. The app offers updates itself: when a new version is out, the menu-bar icon shows an ↑ and one button in Settings ▸ About & support installs it.

## 1.2.7 (2026-08-25)

**The right-click Mute actually mutes.** The Mute item in the menu-bar right-click menu flipped the setting without stopping the voice, so a reply already speaking talked to the end while the icon claimed silence, and unmuting from the menu did not resume. Both now behave exactly like the speaker button on the full deck: mute pauses on the spot, unmute picks up where it left off.

**Skip stays quiet while muted.** Pressing skip while the app was muted started the next reply out loud and silently cleared the mute. Skip now means "make this stop" even then: the current reply is marked played and the app stays silent until you unmute.

**Muted sessions stay muted.** A session's mute used to clear itself whenever its replies left the list, so Delete all, Clear played, or plain queue aging quietly unmuted everything and the next reply played aloud. A mute now clears only when its session actually ends.

**A tour button in Settings.** Settings ▸ About & support now has a "How to use it" row with an Open the tour button, which opens the visual tour at speakyspeak.com/howto. The "Up to date" confirmation also sits inside its own row now instead of being clipped by the section edge.

**VoiceOver can drive the whole app now.** The menu-bar icon says its state and queue count out loud (the count is drawn into the icon, so assistive tech could not see it at all). Each queue row is one spoken summary, state first, and play, mute session, and remove are reachable as VoiceOver actions without a pointer, which they never were, since those buttons only existed under a hovering mouse. Both progress bars can be heard and seeked. Every mini player button has a name. The two windows are named the full deck and the mini player. Checking for updates and copying the report prompt announce their result.

**Fixes for rare lost replies.** Three timing bugs in the hook could lose or repeat a reply when mid-turn speech is on: two hooks landing in the same second could overwrite one file with the other, the end-of-turn hook could re-speak what the mid-turn hook had just read, and a background agent finishing could cut the gathered reply short. A reply whose voice render fails is no longer permanently swallowed, and a reply that is entirely a code block no longer queues a silent empty row. The updater's progress check also no longer stalls while a menu is open.

## 1.2.6 (2026-08-25)

**Mute a single session.** With several Claude Code sessions running, one busy session can drown out the ones you care about. Hover any reply in the queue and a speaker-slash now sits between play and remove: click it and that whole terminal session goes quiet, immediately if it is the one speaking. Its replies keep arriving and stay in the list, each with a visible speaker-slash and a grey dot so it is always clear what is muted, and clicking the icon again brings the whole backlog back. Nothing is deleted: playback simply steps over muted sessions, and the count on the menu-bar icon only includes replies that will actually play.

**The scroll bar no longer sits on top of the row buttons.** The queue hides its scroll indicator (scrolling itself is unchanged), and the row and header buttons are a little larger and moved in from the right edge.

## 1.2.5 (2026-08-25)

**Pick your own accent colour.** The terracotta was never adjustable. Settings ▸ Appearance now has a slider that repaints the whole app, from the play button to the queue badge in the menu bar. Most of the track sweeps through colours at a fixed saturation and brightness, so any choice keeps the same muted feel, and the last stretch leaves colour behind and runs white to grey to black. Reset returns the original.

**Three looks for the mini player.** Classic is a solid card that reads the same on any wallpaper. Glassy is translucent and adapts to what is behind it, and is the default. Glassier is more transparent still. All three share the same width and the same flat transport buttons now.

**Settings shows you the change while you make it.** Opening Settings brings the mini player up as a live preview and keeps it there, so choosing a look or dragging the accent shows you the result on the thing itself. With that, most of the explanatory captions are gone.

**The menu-bar icon holds still and says more.** A waiting queue now shows as the count over the mark rather than a number beside it, orange when those replies are going to play and grey when they are not. The icon is the same width in every state, so it never shifts under your cursor.

**Smaller things.** "Reading panel" is now called the mini player. Version and Check for updates share one line, and the check confirms itself without moving the window. Reporting is one section at the bottom with two buttons side by side. Speed, volume and mute were removed from Settings, since all three are on the player itself.

## 1.2.4 (2026-08-24)

**The floating panel is readable on any wallpaper.** The Frosted panel style was never actually solid: it used a translucent material, so over a dark desktop the card darkened and took the text with it. It is opaque now, and the reply preview text was measured and strengthened, so contrast no longer depends on what is behind the window.

**One menu-bar icon, with a slash when it is silent.** The alternate speaker icon set and its setting are gone. The Sy mark now wears a diagonal slash whenever nothing is going to be heard, meaning speech is off, muted, or paused part way through a reply. That replaces the old dimming, which looked much the same in every state.

**A tidier Settings window.** Three sections now: Speech, Appearance, About. Voice sits at the top where you reach for it. Speed, volume and mute have moved out, since all three are already on the panel itself, one click away. The two report buttons line up on the right with everything else.

## 1.2.3 (2026-08-23)

**No more clipped first words when two Macs share one pair of AirPods.** The headphones only move to a Mac once it starts producing audio, and that switch takes about a second, so the opening words of a reply were playing into headphones still attached to the other machine. Now, when the deck has been quiet for a while, it engages the audio output a moment before speaking and starts the reply once the headphones have arrived. Replies that follow one another are unaffected, since the route never left. Set `~/.claude/speak-lead-in` to change the delay in seconds, or to `0` to turn it off.

## 1.2.2 (2026-08-23)

**The menu-bar icon stops moving.** The queue count now sits before the icon instead of after it. A menu bar item keeps its right edge fixed and grows leftward, so with the count on the right the icon slid sideways every time the count appeared, cleared, or went from 9 to 10. That left the panel's arrow pointing at bare menu bar after you cleared the queue, and it meant the icon you aim your cursor at was never quite in the same place. Now it holds still. The panel and the floating player also aim at the icon itself rather than at the middle of the item, so the arrow lands on the glyph even when a count is showing.

## 1.2.1 (2026-08-23)

**A guide.** [GUIDE.md](GUIDE.md) is new: how to set up Claude Code so listening actually works, and what every setting does. The part worth reading first is the timestamp rule. Add one line to your `CLAUDE.md` and every reply opens by saying what time it was written, which is what makes a queue of replies legible when you come back to it.

**The floating player shows what it's reading.** The title line now carries the opening words of the reply instead of a "1 of 13" counter. The counter is still on the panel's now playing card, where there's room for both.

## 1.2.0 (2026-08-23)

**Hear a session's replies in order.** If you run several Claude Code sessions at once, their replies used to arrive interleaved and newest first, so a session's story played backwards with another project's replies spliced into the middle. There is now a sort button on the "Up next" line. Set Group by to Session and Order by to Oldest first, and each session's replies play as one run, in the order they actually happened, one session at a time. A new reply extends its own session's run instead of jumping the queue.

Group headers show the session, how many replies are waiting, and the time span. Hover one to play that whole session next, or clear its queued replies. The now playing card and the floating panel show "2 of 6" so you know how much of a session's story is left. Your choice is remembered. The default is unchanged: a flat list, newest first.

**Controls moved onto the "Up next" line.** Sort, clear played, delete all, and settings now sit on that line instead of at the bottom of the panel. Hovering any of them replaces the label with what it does.

**Fixed: a reply could go missing.** Two replies from the same session inside the same second wrote to the same file, and the first was silently overwritten. Nothing reported an error, you simply never heard it. This was most likely to happen when reading a long run as it works, where a mid-run reply and the final reply can land about a second apart.

## 1.1.0 (2026-08-18)

A day of polish driven by real user reports, rolled up into a minor release.

**Updates you can see.** The updater was rebuilt after it once finished an update without telling anyone. It now shows live progress in Settings (pulling, rebuilding, about a minute), relaunches itself reliably, confirms "Updated from X, you're on the latest version" afterward, and the app speaks a short confirmation aloud in your chosen voice on its first launch after an update (skipped if you're muted). Update checks are no longer cached, so a fresh release is visible seconds after it ships.

**Consistent loudness everywhere.** The spoken update confirmation, the Settings voice previews, and re-rendered queued items all play at the same normalized level as regular replies, and every sound honors the Volume slider, on both the neural voice and the built-in macOS voice. ffmpeg is found whether it came from Homebrew or MacPorts.

**A simpler menu.** The right-click menu is now just Mute, Settings, and Quit, so it can never clip on a short screen. Version, updates, and support all live in Settings ▸ About & support.

**Ways to reach us.** Email hi@speakyspeak.com, use "Email a report" in Settings (pre-fills your version, engine, and recent log lines), or "Have Claude write a report" (copies a prompt so your own Claude Code gathers the logs and drafts the mail for you to send).

## 1.0.7 (2026-08-18)

- Feedback goes live: hi@speakyspeak.com on the site, README, INSTALL, and a Send Feedback item in the app.

## 1.0.6 (2026-08-17)

- Fixes from the first real install report: the neural voice could silently fall back to the slow path when the active voice wasn't cached (now pre-cached at install), Settings could show a different voice than the one speaking, and a healthy install produced an empty log that read as a broken one (the hook now logs each spoken reply).

## 1.0.2 - 1.0.5 (2026-08-17)

- Built-in updates: daily check, ↑ badge on the menu-bar icon, one-click install and relaunch.

## 1.0.0 (2026-08-16)

- First public release: menu-bar deck, serial playback across parallel Claude Code sessions, Kokoro neural voice with `say` fallback, mini reading panel, Claude-driven install.
