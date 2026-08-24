# SpeakySpeak — install

This file is written for an agent (Claude Code) to execute top to bottom, unattended. Each step is one command plus one sentence describing the expected result. If a step's result doesn't match, stop and report which step failed before continuing.

SpeakySpeak is a macOS menu-bar app. A Claude Code Stop hook renders each reply to audio with a local neural voice (Kokoro) and queues it; the app plays queued replies one at a time.

Repo: `https://github.com/radam5000/speakyspeak` — clone this URL exactly.

---

## Adapt this to how the user actually uses Claude

This doc is written as if Claude Code were running in a terminal, because that's the shortest way to describe shell commands. If the person you're installing for uses Claude Code differently, adapt instead of stopping:

- **Claude Code inside the desktop app, VS Code, or Cursor** — everything here works unchanged, including the shell commands (you run them in your own tool, not in a terminal the user has to open). Hooks and settings live in `~/.claude/` no matter which surface Claude Code runs in, so the hook fires the same way. "Start a new session" in step 7 means a new conversation, a new chat tab, or a new window — whatever counts as starting over in their setup.
- **Claude Code somewhere other than a Mac** (a Linux box, a remote machine, a web surface) — the app is macOS-only and the hook has to run on the same Mac as the app. Stop and say so rather than half-installing.
- **Preferences the user mentions** (a different voice, faster speech, two Macs sharing AirPods) — set the matching knob from the Knobs section at the bottom as part of the install, don't make them come back for it.
- **A setup that can't run Claude Code hooks at all** — the app itself doesn't care where audio comes from. It plays anything dropped into `/tmp/claude-speech/queue/` as `<epoch>-<sid>.m4a` plus a matching `.json` (the queue contract, documented in [README.md](README.md)). You can write a small producer for whatever tool the user has.

When the install is done, tell the user this: the whole thing is a few plain shell scripts and one Swift file, and asking Claude to change it — the voice, the speed, when it speaks, which sessions it reads — is the intended way to customize it.

---

## 0. Requirements check

Run each command. All must pass before continuing.

```sh
sw_vers -productVersion
```
Expected: a version number `14.0` or higher.

```sh
xcode-select -p
```
Expected: a path (e.g. `/Library/Developer/CommandLineTools`), not an error. If it errors, run `xcode-select --install`, wait for the GUI installer to finish, then re-run this check.

```sh
which brew
```
Expected: a path (e.g. `/opt/homebrew/bin/brew`). If missing, install Homebrew first (https://brew.sh) — this doc does not cover that.

```sh
which claude
ls -d ~/.claude
```
Expected: `which claude` prints a path, and `~/.claude` exists. Claude Code must already be installed and signed in. If `which claude` prints nothing but `~/.claude` exists, that's fine — it just means the `claude` binary isn't on this shell's `PATH` (common when Claude Code runs from the desktop app or an IDE extension). Continue; nothing later in this doc calls `claude`.

```sh
uname -m
```
Expected: `arm64` (Apple Silicon, gets the neural voice) or `x86_64` (Intel, falls back to macOS `say` — everything else still works; skip step 3).

---

## 1. Clone the repo

```sh
git clone https://github.com/radam5000/speakyspeak.git ~/speakyspeak
cd ~/speakyspeak
```
Expected: the folder `~/speakyspeak` now exists and contains `install.sh`, `README.md`, `main.swift`.

The location is free-form — `~/speakyspeak` is just a sensible default; a projects folder like `~/Development/speakyspeak` works the same (the app records wherever the clone lives).

**Do not delete this folder after install.** The app checks for updates daily and shows "Update to X…" in Settings ▸ About & support (the menu-bar icon grows a ↑ when one is waiting); updating re-pulls from this exact clone. Deleting it breaks future updates, not just the source copy.

---

## 2. Install command-line dependencies

```sh
brew install jq ffmpeg espeak-ng uv
```
Expected: brew reports each formula installed or already installed, no errors.

What each is for:
- `jq` — required. The hook parses its JSON input with it; without it nothing renders.
- `ffmpeg` — required for correct volume on the Kokoro neural-voice path (so: needed on Apple Silicon, unused on the `say` fallback). It loudness-normalizes audio to −16 LUFS during encoding. Kokoro's raw output is ~12dB quieter than `say`; without ffmpeg the hook silently falls back to `afconvert`, which has no gain stage, and every reply plays back too quiet.
- `espeak-ng`, `uv` — needed only for the Kokoro neural voice (Apple Silicon). Skipping them is harmless on Intel; the hook falls back to `say` automatically.

Verify ffmpeg specifically, since a quiet install is the least visible failure:
```sh
command -v ffmpeg
```
Expected: a path. If empty, redo the brew install for ffmpeg before moving on.

---

## 3. Install the Kokoro neural voice (Apple Silicon only — skip on Intel)

Install mlx-audio as an isolated uv tool, **pinned to exactly 0.4.1**. Version 0.4.4 has a length-dependent audio-render regression (upstream issue [#784](https://github.com/Blaizzy/mlx-audio/issues/784)) — do not install latest or omit the version pin.

```sh
uv tool install --python 3.12 "mlx-audio[tts]==0.4.1" \
  --with "misaki[en]" \
  --with "en_core_web_sm @ https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl"
```
Expected: uv reports the installed executables with no errors — currently `Installed 5 executables` including `mlx_audio.tts.generate` (older mlx-audio versions reported 1; any success output that includes `mlx_audio.tts.generate` counts).

```sh
ls ~/.local/bin/mlx_audio.tts.generate
```
Expected: the file exists.

### Test-render now (downloads the model)

The model (`mlx-community/Kokoro-82M-bf16`, ~350MB) downloads on first render. Do that here, not on the user's first Claude Code reply — and not after step 4, because the warm-TTS LaunchAgent that `install.sh` sets up runs offline and will crash-loop if the model isn't cached yet.

The voice must be `bf_lily` — that is the pipeline's default voice, and the warm daemon runs offline, so it can only use voices cached here (a different voice would cache the wrong file and the first replies would fall back to the slow cold render).

```sh
~/.local/bin/mlx_audio.tts.generate \
  --model mlx-community/Kokoro-82M-bf16 --voice bf_lily \
  --text "Hello, this is SpeakySpeak." --file_prefix /tmp/speakytest --join_audio
afplay /tmp/speakytest.wav && rm -f /tmp/speakytest*.wav
```
Expected: the command exits without error, `/tmp/speakytest.wav` gets created, and the user hears a synthesized voice say the test sentence. If nobody is at the machine to listen, a clean exit plus a non-empty `.wav` counts as a pass. If this step fails for any reason, it is not fatal — the pipeline falls back to macOS `say` automatically. Continue to step 4 and retry this step (then re-run `./install.sh`) later.

---

## 4. Build and install the app + hooks

From `~/speakyspeak`:

```sh
./install.sh
```

This is idempotent (safe to re-run). It runs `./build.sh` (compiles `main.swift`, ad-hoc signs, installs to `~/Applications/SpeakySpeak.app`), then:
- copies `hooks/speak-reply.sh`, `hooks/session-end.sh`, `hooks/tts-daemon.py` to `~/.claude/hooks/` and makes them executable
- if `~/.local/bin/mlx_audio.tts.generate` exists (step 3 succeeded), writes and bootstraps the LaunchAgent `com.adamraabe.speakyspeak-tts`, which keeps the Kokoro model warm in memory so replies render in ~0.3–0.9s instead of ~3s cold
- **does not touch `~/.claude/settings.json`** — it only prints the hook-registration snippet to the terminal. Step 5 below does the actual registration.

Expected output includes `Installed hooks to ~/.claude/hooks/` and either `Warm TTS daemon running (com.adamraabe.speakyspeak-tts)...` or `mlx-audio not installed — skipping warm TTS daemon (say fallback stays).` (expected on Intel, or if step 3 was skipped/failed).

Verify:
```sh
ls ~/Applications/SpeakySpeak.app/Contents/MacOS/SpeakySpeak
ls ~/.claude/hooks/speak-reply.sh ~/.claude/hooks/session-end.sh ~/.claude/hooks/tts-daemon.py
```
Expected: all four paths exist.

---

## 5. Register the hooks in Claude Code

`install.sh` does **not** edit `~/.claude/settings.json` for you. Open that file and add the following inside the top-level `"hooks"` object. **Merge, don't replace** — if `"hooks"` or existing `Stop`/`SessionEnd` entries already exist, add these hook objects alongside what's there, don't overwrite the file.

```json
"hooks": {
  "Stop": [{ "matcher": "*", "hooks": [
    { "type": "command", "command": "bash ~/.claude/hooks/speak-reply.sh",
      "timeout": 600, "async": true }
  ]}],
  "PostToolUse": [{ "matcher": "*", "hooks": [
    { "type": "command", "command": "bash ~/.claude/hooks/speak-reply.sh",
      "timeout": 600, "async": true }
  ]}],
  "SessionEnd": [{ "matcher": "*", "hooks": [
    { "type": "command", "command": "bash ~/.claude/hooks/session-end.sh" }
  ]}]
}
```

The `PostToolUse` entry is what lets SpeakySpeak read a long run aloud **as it
happens**, instead of staying silent through twenty minutes of tool calls and
then reading the whole thing at the end. It is the same script; it does nothing
until the user turns it on in Settings ▸ Speech ▸ "Read replies", and in the
default setting it exits within milliseconds of being called. Wire it now even
if the user doesn't want mid-run speech yet — then the setting just works later,
with no second trip into `settings.json`.

If `~/.claude/settings.json` doesn't exist yet, create it with just:
```json
{
  "hooks": {
    "Stop": [{ "matcher": "*", "hooks": [
      { "type": "command", "command": "bash ~/.claude/hooks/speak-reply.sh",
        "timeout": 600, "async": true }
    ]}],
    "PostToolUse": [{ "matcher": "*", "hooks": [
      { "type": "command", "command": "bash ~/.claude/hooks/speak-reply.sh",
        "timeout": 600, "async": true }
    ]}],
    "SessionEnd": [{ "matcher": "*", "hooks": [
      { "type": "command", "command": "bash ~/.claude/hooks/session-end.sh" }
    ]}]
  }
}
```

Verify the file is valid JSON after editing:
```sh
jq . ~/.claude/settings.json > /dev/null && echo "valid JSON"
```
Expected: `valid JSON`, no error.

---

## 6. Launch the app

```sh
open ~/Applications/SpeakySpeak.app
```
Expected: a "Sy" icon appears in the menu bar (left-click for the queue panel, right-click for Settings / Mute / Quit). You can't see the menu bar yourself, so treat the next command as the real check and ask the user to confirm the icon.

```sh
pgrep -f SpeakySpeak.app/Contents/MacOS/SpeakySpeak
```
Expected: a process ID (a number). Empty output means the app isn't running — re-run `open` above.

---

## 6.5 (optional but recommended). Verify playback yourself, before involving the user

The queue contract lets you prove "the app plays audio" without a new session: render a short clip and drop it into the queue exactly the way the hook does.

```sh
V=$(cat ~/.claude/speak-voice-kokoro 2>/dev/null || echo bf_lily)
~/.local/bin/mlx_audio.tts.generate --model mlx-community/Kokoro-82M-bf16 --voice "$V" \
  --text "SpeakySpeak install verified." --file_prefix /tmp/speakyverify --join_audio
ID="$(date +%s)-installtest"
ffmpeg -y -i /tmp/speakyverify.wav -af "loudnorm=I=-16:TP=-1.5:LRA=11" -c:a aac -b:a 96k "/tmp/claude-speech/queue/$ID.m4a" 2>/dev/null
printf '{"session":"installtest","project":"install","title":"Install test","preview":"SpeakySpeak install verified.","text":"SpeakySpeak install verified.","created":%s}' "$(date +%s)" > "/tmp/claude-speech/queue/$ID.json"
sleep 6; tail -5 /tmp/claude-speech/deck.log; rm -f /tmp/speakyverify*.wav
```
Expected: the clip plays aloud and `deck.log` shows `queued` → `playing` → `finished` for the test id. (On Intel/`say`-only setups, replace the first two lines with `say -o /tmp/claude-speech/queue/$ID.m4a --data-format=aac "SpeakySpeak install verified."`.) This isolates the app half; step 7 then tests only the hook half.

---

## 7. Test end to end

On current Claude Code, `settings.json` hook changes are picked up without restarting — so THIS session's next reply may already be spoken aloud. Send any short reply and listen. If it speaks: step 7 is done. (On older Claude Code versions hooks only load at session start; in that case ask the user to start a **new** session — a new terminal window, a new chat in the desktop app, or a new Claude Code panel/tab in VS Code or Cursor — and send it any short message.)

Within a few seconds of the reply finishing, expected: the reply is spoken aloud, the menu-bar icon shows a queue badge and pulses, and a small floating player appears under the icon.

Then confirm it from the log — this is the part you can check yourself:
```sh
tail -5 /tmp/claude-speech/hook.log
```
Expected: a `spoke <id> engine=... chars=... secs=...` line per spoken reply (added 2026-08-17). **Note:** on installs of versions before 1.0.6 the hook logged only FAILURES, so an empty `hook.log` there means everything worked; success lives in `deck.log` (`queued` → `playing` → `finished`). Never report a broken install while `deck.log` shows playback.

---

## Logs

- `/tmp/claude-speech/hook.log` — the Stop hook (per-reply render)
- `/tmp/claude-speech/deck.log` — the app
- `/tmp/claude-speech/tts-daemon.log` — the warm Kokoro renderer (also `~/Library/Logs/speakyspeak-tts.out.log` / `.err.log` from the LaunchAgent)

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Audio plays but is much quieter than normal speech | `ffmpeg` not installed; hook fell back to `afconvert` with no gain stage | `brew install ffmpeg`, then just wait for the next reply (no reinstall needed — the hook checks for ffmpeg on every run) |
| ~3 second delay before every reply starts speaking | Warm TTS daemon isn't running, OR the daemon is fine but the **active voice isn't cached** — the daemon runs offline (`HF_HUB_OFFLINE=1`) and can't fetch a missing voice, so every render falls to the cold CLI. `tts-daemon.log` showing `IncompleteSnapshotError` with a `voices/*.safetensors` file confirms it | Cache the voice the hook actually uses: `V=$(cat ~/.claude/speak-voice-kokoro 2>/dev/null \|\| echo bf_lily); ~/.local/bin/mlx_audio.tts.generate --model mlx-community/Kokoro-82M-bf16 --voice "$V" --text ok --file_prefix /tmp/vfix --join_audio; rm -f /tmp/vfix*.wav`, then `launchctl kickstart -k gui/$(id -u)/com.adamraabe.speakyspeak-tts`; check `~/Library/Logs/speakyspeak-tts.err.log` for other crash detail |
| No speech at all, and `/tmp/claude-speech/hook.log` has no new lines after a turn | Hook not registered in `~/.claude/settings.json`, or the session predates the registration on an older Claude Code | Recheck step 5's JSON is valid and merged correctly; if still silent, start a **new** Claude Code session |
| No speech at all, but `hook.log` shows the hook ran | `~/.claude/speak-off` exists (hard kill), or the deck is muted | `rm -f ~/.claude/speak-off`; right-click the menu-bar icon and check Mute is off |
| Voice sounds robotic / like the built-in macOS voice | Kokoro isn't installed, the daemon/CLI failed, or the **active voice isn't cached** (see the delay row above) and both Kokoro paths failed | Check `hook.log` for `engine=say` lines; cache the active voice per the delay row, redo step 3 if Kokoro was never installed, then `./install.sh` again; or in System Settings → Accessibility → Spoken Content → System Voice, download a better voice (e.g. Ava Premium) — the hook finds it automatically |
| No menu-bar icon | App isn't running | `open ~/Applications/SpeakySpeak.app` |

Still stuck after the table? Email **hi@speakyspeak.com** with the step that failed and the last lines of `/tmp/claude-speech/hook.log` — a human reads it and replies.

---

## Knobs (plain files, read by the hook and app)

All under `~/.claude/`, created by touching/writing the file — no file means default behavior.

- `speak-off` — hard kill; touch this file to stop rendering entirely (`rm -f` to re-enable)
- `speak-rate` — words per minute, `say` engine only
- `speak-voice` — `say` voice name (e.g. `Ava (Premium)`); absent = best installed voice is auto-probed
- `speak-voice-kokoro` — Kokoro voice id (default `bf_lily`; ~54 voices in the model card). New voices must be cached online once (the warm daemon runs offline) — `install.sh` handles the active voice, and auditioning a voice in Settings caches it too
- `speak-engine` — force `say` or `kokoro`; absent = kokoro when installed, else say

### Optional: two Macs sharing one pair of AirPods

If this Mac and another Mac both run SpeakySpeak and share AirPods, they can take turns instead of fighting over playback. On each Mac, write the *other* Mac's IP address to the file below. Any address the two Macs can reach each other on works — a Tailscale IP if they use Tailscale, otherwise the local network address (System Settings → Network → Wi-Fi → Details).

```sh
echo "<other-mac-ip>" > ~/.claude/speak-peer
```

Before auto-playing, each deck asks the peer (TCP port 48765) and waits if the peer is currently speaking, so macOS's AirPods auto-switching hands off cleanly instead of overlapping. Manual plays (clicking a queued item) never wait. If the file is absent, the peer is off, or it's unreachable, the deck just plays — this fails open and is skippable if only one Mac is in use.

---

Full architecture, controls reference, and settings-window documentation: [README.md](README.md).

## Next: hand them the guide

Installation done. Point the user at [GUIDE.md](GUIDE.md) and say what it covers: the `CLAUDE.md` timestamp rule (so a queue of replies says when each was written), the suggested setup for running several sessions at once, and what every setting does. If they run more than one Claude Code session, the sort menu's "Group by: Session" plus "Order by: Oldest first" is the single most useful thing in it.
