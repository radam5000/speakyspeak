# speakyspeak · ROUTINE

This project's recurring checks and jobs (SYSTEM.md). Two kinds: **timed** entries run themselves (launchd/cloud; this file documents them, it does not schedule them). **On-demand** entries run when a sweep runs them. Sources at creation (2026-08-24): root `AUTOMATION.md` + the mother-routine registry.

## Timed

| Job | When | Where it writes | How to tell it died |
|---|---|---|---|
| speakyspeak.feedback (launchd, triage-gated) | 7:45am daily | `~/Library/Logs/SpeakySpeak/loop-status.json` | outcome ok/no-work + last_run today-ish; digest email arrives ONLY on days with new/open items, so no email ≠ no run. Kill switch: `touch ~/.claude/speakyspeak-loop-off`. |
| speakyspeak-tts (launchd KeepAlive daemon) | always on | plays Stop-hook audio | `launchctl list` exit 0; knobs at ~/.claude/speak-off, speak-rate, speak-voice. |

## On-demand

| Check | How |
|---|---|
| Feedback ages | `FEEDBACK.md` "Awaiting your OK" — oldest days-waiting leads the report line. |
| Repo health | `git status` + last commit. |
| Releasable? | `./verify.sh` — compile, hook fixture tests, the INSTALL.md json blocks, launch smoke, and the docs-sync gate. Green before any release. |
