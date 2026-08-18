# Changelog

What changed in each SpeakySpeak release. The app offers updates itself: when a new version is out, the menu-bar icon shows an ↑ and one button in Settings ▸ About & support installs it.

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
