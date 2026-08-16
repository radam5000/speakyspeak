# SpeakySpeak setup guide

SpeakySpeak is a small macOS menu-bar app that reads Claude Code's replies out loud. Every time Claude finishes a turn, a hook renders the reply to audio with a local neural voice and queues it in the deck, which plays replies one at a time (multiple sessions never talk over each other). You get a menu-bar icon with a queue, a floating mini player while it speaks, and a global hotkey to shut it up.

**If you use Claude Code:** the easiest way to install is to open a Claude Code session in this folder and say:

> Read SETUP.md and set SpeakySpeak up on this machine, following it exactly.

The rest of this file is written so the agent (or you) can follow it top to bottom.

## What you need

- A Mac on macOS 14 or newer. The mini player gets a Liquid Glass look on macOS 26.
- **Apple Silicon (M1 or later) for the neural voice (Kokoro).** On an Intel Mac, skip the Kokoro steps; everything still works using the built-in macOS `say` voice.
- Claude Code installed and signed in.
- Xcode Command Line Tools (for `swiftc`). If `xcode-select -p` errors, run `xcode-select --install` first.
- Homebrew.

No prebuilt binary ships in this folder. The app builds from source on your machine in a few seconds and is ad-hoc signed, so there are no Gatekeeper or notarization hoops.

## Step 1: command-line dependencies

```sh
brew install jq ffmpeg espeak-ng uv
```

What each is for: `jq` parses the hook input (required). `ffmpeg` loudness-normalizes the audio so the neural voice isn't quiet (optional but recommended; without it the hook uses `afconvert` with no gain fix). `espeak-ng` and `uv` are only needed for the Kokoro neural voice; skip them on Intel.

## Step 2: install the Kokoro neural voice (Apple Silicon only)

This installs mlx-audio as an isolated uv tool. **The version pin matters**: 0.4.4 has a render bug on longer texts (upstream issue #784), so install exactly this:

```sh
uv tool install --python 3.12 "mlx-audio[tts]==0.4.1" \
  --with "misaki[en]" \
  --with "en_core_web_sm @ https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl"
```

Then download the voice model (about 350 MB, one time) by doing a test render. **Do this before Step 3**, because the background daemon that install.sh sets up runs in offline mode and will crash-loop if the model isn't cached yet:

```sh
~/.local/bin/mlx_audio.tts.generate \
  --model mlx-community/Kokoro-82M-bf16 --voice af_heart \
  --text "Hello, this is SpeakySpeak." --file_prefix /tmp/speakytest --join_audio
afplay /tmp/speakytest.wav && rm -f /tmp/speakytest*.wav
```

If you hear a voice, Kokoro works. If this step fails, don't worry: the pipeline falls back to the macOS `say` voice automatically and you can retry later (just re-run `./install.sh` afterwards).

## Step 3: build and install

From this folder:

```sh
./install.sh
```

This builds the app to `~/Applications/SpeakySpeak.app`, copies the hook scripts to `~/.claude/hooks/`, and (if Kokoro is installed) sets up a LaunchAgent (`com.adamraabe.speakyspeak-tts`) that keeps the voice model warm so replies render in about half a second instead of three. It's idempotent; re-run it any time.

## Step 4: wire the hooks into Claude Code

Add these to the `"hooks"` section of `~/.claude/settings.json`. **Merge, don't replace**: if you already have a `"hooks"` key or existing `Stop`/`SessionEnd` entries, add these hook objects alongside what's there.

```json
"hooks": {
  "Stop": [{ "matcher": "*", "hooks": [
    { "type": "command", "command": "bash ~/.claude/hooks/speak-reply.sh",
      "timeout": 600, "async": true }
  ]}],
  "SessionEnd": [{ "matcher": "*", "hooks": [
    { "type": "command", "command": "bash ~/.claude/hooks/session-end.sh" }
  ]}]
}
```

## Step 5: test it

Start a **new** Claude Code session (hooks load at session start) and ask anything. Within a few seconds of the reply finishing you should hear it spoken, a "Sy" icon should appear in the menu bar, and a small floating player should drop down under it.

Quick tour: left-click the menu-bar icon for the queue, right-click it for Settings / Mute / Quit. The hotkey ⌃⌥⌘Space silences the current reply from anywhere. Full controls and settings are documented in README.md.

## If something doesn't work

- **Nothing speaks and there's no `/tmp/claude-speech/hook.log` file after a turn**: the hook isn't wired. Re-check Step 4 (valid JSON? new session started?).
- **The log exists**: read it. `/tmp/claude-speech/hook.log` is the hook's log, `deck.log` is the app's, `tts-daemon.log` is the warm renderer's.
- **No menu-bar icon**: launch `~/Applications/SpeakySpeak.app` once by hand.
- **Replies take ~3s to start and the daemon log shows crashes**: the model wasn't downloaded before the daemon started. Do the test render in Step 2, then restart it: `launchctl kickstart -k gui/$(id -u)/com.adamraabe.speakyspeak-tts`
- **Voice sounds robotic**: you're on the `say` fallback. Either fix Kokoro (Step 2) or download a better system voice in System Settings > Accessibility > Spoken Content > System Voice (Ava Premium is good); the hook finds it automatically.
- **Want it quiet**: right-click icon > Mute (keeps queueing, plays nothing), or the master switch in Settings, or `touch ~/.claude/speak-off` from the shell.

## Uninstall

```sh
launchctl bootout gui/$(id -u)/com.adamraabe.speakyspeak-tts 2>/dev/null
rm -f ~/Library/LaunchAgents/com.adamraabe.speakyspeak-tts.plist
rm -rf ~/Applications/SpeakySpeak.app /tmp/claude-speech
rm -f ~/.claude/hooks/speak-reply.sh ~/.claude/hooks/session-end.sh ~/.claude/hooks/tts-daemon.py
uv tool uninstall mlx-audio 2>/dev/null
```

Then remove the two hook entries from `~/.claude/settings.json`.
