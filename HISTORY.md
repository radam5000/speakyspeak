# speakyspeak · HISTORY

Human-readable, append-only. Baseline generated from git log 2026-08-24; sessions append below, never rewrite old entries.

## 2026-06

The project started as SpeakySpeak, a spoken-reply queue panel for Claude Code, moved over from an earlier location at ~/.claude/tools/speakyspeak. Early work made the playback queue reliable: fixed sequencing races so a paused reply couldn't get overwritten by a new arrival, made session end stop deleting unheard replies, and persisted mute and playback rate across restarts so a relaunch would not blast a stale backlog. The power button became a real on/off control instead of quitting the app, queue rows became inert display-only items with icon-based status, and a footer was added with sweep and delete-all actions plus tooltips on every icon. Partway through the month the text-to-speech engine changed from macOS `say` to a local neural voice engine (Kokoro, via mlx-audio) with `say` kept as a fallback, and a volume slider with loudness normalization was added. Two hook bugs were fixed: the hook was speaking the mid-turn preamble instead of the final reply, and it could re-speak a stale reply when a transcript flushed late. Mid-month the floating panel moved into the macOS menu bar, and the app got its own brand mark ("Sy," a hand-made Optima-based icon) plus a settings window. The month closed with a mini HUD: quiet/skip controls, a global hotkey, and a dismiss button.

## 2026-07

The mini HUD grew into the app's main visible surface: full transport controls, drag-anywhere positioning, a "locate me" glow, a Liquid Glass visual treatment, a bright flash on track changes, a bottom progress bar, and a choice between "always visible" and "only while speaking." Emoji were stripped from spoken text so the voice engine would not try to read them aloud. A warm TTS daemon cut the time to render a new reply from about 3 seconds to about 0.5 seconds. The project got a public GitHub remote (radam5000/speakyspeak) and a SETUP.md written for a friends beta, meaning other people besides Adam could install it on a fresh machine. Settings gained a voice preview so a user could audition any voice before picking it, a launch crash was fixed, and the install script was made to reload the TTS daemon reliably.

Standout events:
- 2026-07-16: CLAUDE.md corrected to reflect that a public remote now exists.
- 2026-07-18: SETUP.md written specifically for the friends beta, the first sign the app was meant for people other than Adam.
- 2026-07-20: Voice preview added to Settings, plus a fix for a launch crash caused by loading the voice list on the main thread.

## 2026-08

This was the release month. The app shipped its first public version, built a full site, stood up a real bug-feedback loop, and moved through more than twenty numbered releases by month end.

Early in the month the app was made to speak a whole reply turn rather than just the text after the last tool call, a minimum-macOS-version mismatch was fixed (the binary required 26.0 while the plist advertised 14.0), and the README was rewritten for a public MIT-licensed release. AirPods got direct support: stem clicks control playback via Now Playing, and a "peer gate" was added so two Macs sharing one pair of AirPods take turns instead of fighting over them.

The bulk of the month went into the public website and a long string of design iterations: a rainbow "aurora" ripple effect on the HUD went through several redesign passes, a public mirror repo and installer/updater plumbing shipped as v1.0.1, and the site itself went through many rounds (hero copy, sticker galleries, mobile layout, an accessibility pass, and an em-dash purge of the copy). Adam set the rule that site copy must be written in his own voice with no em dashes, and that any subagent writing copy must be told this explicitly. A real bug-feedback loop went live on 2026-08-18: a support email, a verify.sh script with fixture tests, and a daily triage job under launchd. That day's polish releases were rolled into 1.1.0 with a user-facing CHANGELOG. In the last few days of the month the queue gained session-run grouping and a user-settable sort order (1.2.0), a public GUIDE.md was published (1.2.1), the menu-bar icon was fixed to hold still while its badge updates (1.2.2), an AirPods audio lead-in was added and confirmed on a real two-Mac setup (1.2.3), and a legibility and Settings-layout pass shipped as 1.2.4, followed by a deploy script added after a short self-inflicted site outage.

Standout events:
- 2026-08-16: v1.0.1 released along with a public site, an updater, and Lily as the shipped default voice.
- 2026-08-17: A single very long day of site design iteration, ending in an accessibility audit, an em-dash purge, and versions 1.0.2 through 1.0.6.
- 2026-08-18: The feedback loop (hi@speakyspeak.com, verify.sh, daily triage) went live, and the day's fixes rolled up into 1.1.0.
- 2026-08-23: v1.2.0 shipped (session-run ordering, sort control, a fix for lost replies), followed by 1.2.1 through 1.2.3 the same day.
- 2026-08-24: v1.2.4 shipped (panel legibility, one menu-bar mark, three-section Settings), and a deploy script was added after a brief self-inflicted outage.
