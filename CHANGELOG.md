# Changelog

What changed in each SpeakySpeak release. The app offers updates itself: when a new version is out, the menu-bar icon shows an ↑ and one button in Settings ▸ About & support installs it.

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
