# SpeakySpeak — install

This file is written for an agent (Claude Code) to run top to bottom, unattended. A person can follow it just as well: it is a check and three commands. If a step's result doesn't match, stop and say which step failed.

SpeakySpeak is a macOS menu-bar app. A Claude Code Stop hook renders each reply to audio with a local neural voice (Kokoro) and queues it; the app plays queued replies one at a time.

Repo: `https://github.com/radam5000/speakyspeak` — clone this URL exactly.

---

## Adapt this to how the user actually uses Claude

This doc is written as if Claude Code were running in a terminal, because that's the shortest way to describe shell commands. If the person you're installing for uses Claude Code differently, adapt instead of stopping:

- **Claude Code inside the desktop app, VS Code, or Cursor** — everything here works unchanged, including the shell commands (you run them in your own tool, not in a terminal the user has to open). Hooks and settings live in `~/.claude/` no matter which surface Claude Code runs in, so the hook fires the same way. "Start a new session" in step 3 means a new conversation, a new chat tab, or a new window — whatever counts as starting over in their setup.
- **Claude Code somewhere other than a Mac** (a Linux box, a remote machine, a web surface) — the app is macOS-only and the hook has to run on the same Mac as the app. Stop and say so rather than half-installing.
- **Claude replies in a language other than English** — the Kokoro neural voice is English only for now (it installs only the English phoneme pack), so a German or Japanese reply would be read as English sounds. Say so before step 2 and let the user choose: run `./setup.sh --no-neural` and set `~/.claude/speak-engine` to `say` with a matching macOS voice in `~/.claude/speak-voice` (`say -v ?` lists what is installed), or install the neural voice anyway for English work.
- **Questions.** Ask the user as little as possible: the language check before step 2 when it applies, and the one terminal question in step 4. Nothing else in this doc needs their answer; check results yourself.
- **Preferences the user mentions** (a different voice, faster speech, two Macs sharing AirPods) — set the matching knob from the Knobs section at the bottom as part of the install, don't make them come back for it.
- **Claude Code run through `claude -p` or the Agent SDK** — SpeakySpeak does not read these runs aloud by default, so scripts and scheduled jobs stay quiet. Check how YOU are running right now: `echo "$CLAUDE_CODE_ENTRYPOINT"`. `cli`, `claude-desktop`, `claude-vscode` or `local-agent` (or empty) is an ordinary chat surface and needs nothing. `sdk-cli`, `sdk-ts` or `sdk-py` means the user is chatting with you through an app that drives Claude that way: run `touch ~/.claude/speak-headless` before step 3, or its test stays silent. If the user mentions scripts or cron jobs that run `claude -p`, tell them those stay quiet on purpose.
- **A setup that can't run Claude Code hooks at all** — the app itself doesn't care where audio comes from. It plays anything dropped into `/tmp/claude-speech/queue/` as `<epoch>-<sid>.m4a` plus a matching `.json` (the queue contract, documented in [README.md](README.md)). You can write a small producer for whatever tool the user has.

When the install is done, tell the user this: the whole thing is a few plain shell scripts and one Swift file, and asking Claude to change it — the voice, the speed, when it speaks, which sessions it reads — is the intended way to customize it. Whenever you (now or later) change it for them:

- **Prefer a knob.** Most wishes are a file in the Knobs section below or a Settings row, and those survive every update.
- **Edit the clone, commit, reinstall.** Change files in the clone from step 1, `git commit` there with a plain message, then run `./install.sh`. Never edit the installed copies in `~/.claude/hooks/` or `~/Applications/`: every update overwrites them (install.sh keeps an edited hook aside as `<name>.mine-<date>`, but it stops running).
- **Updates keep committed and uncommitted changes.** The in-app updater replays them on top of each new version. If one clashes, the update changes nothing and Settings ▸ About offers the user a prompt for you: rebase their commits onto `@{u}`, keep what their change was for, take the update everywhere else, run `./install.sh`.

---

## 0. Say what it needs, and check it

Before downloading anything, tell the user in a sentence or two what you are about to do and what it needs, then check it yourself. Something like:

> I'll install SpeakySpeak. It needs macOS 15.6 or newer, Apple's free command line tools, and about 1.5 GB for the voice. It adds an app in your Applications folder, a voice helper, and four hooks in Claude Code's settings, and it can all be removed with one command. I'm checking your Mac now.

| You need | Why | If you don't have it |
|---|---|---|
| **A Mac on macOS 15.6 or newer** | The tools that build the app need it | System Settings ▸ General ▸ Software Update |
| **Claude Code**, signed in, on this Mac: terminal, desktop app, VS Code or Cursor | Its replies are what you hear. Claude Code on the web, or over SSH on another machine, can't reach this Mac's speakers | [Get Claude Code](https://code.claude.com/docs) |
| **Apple's command line tools**, free | They build the app on your Mac. Full Xcode works too, but you don't need it | Your Mac offers them: click Install. About 1.3 GB, and macOS may ask for your Mac password |
| **Internet, and about 1.5 GB free** (3 GB with Apple's tools) | The voice is downloaded once, then works offline | `./setup.sh --no-neural` skips it and uses the macOS voice |

Optional: **Apple silicon** (M1 or newer) gets the neural voice; an Intel Mac uses the macOS voice. The neural voice speaks **English** only.

Not needed: Homebrew, an API key, another account or subscription, Xcode, or permission to use your microphone.

This check needs nothing but macOS:
```sh
echo "macOS $(sw_vers -productVersion), $(uname -m)"; xcode-select -p 2>/dev/null || echo "command line tools: MISSING"; ls -d "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" 2>/dev/null || echo "Claude Code folder: MISSING"; df -g ~ | awk 'NR==2{print $4 " GB free"}'
```
Expected: macOS 15.6 or higher, a path for the tools, a path for Claude Code, and enough free space. Show the user the result as a short checklist. Then:

- **All there:** say so and go on. Don't ask for permission again; they asked you to install it.
- **The tools are missing:** run `xcode-select --install`, tell them a window is open on their screen and to click Install, and wait. Check again with `xcode-select -p`.
- **macOS is too old:** stop, and tell them the exact version they have, that 15.6 is the minimum, and where to update. Nothing has been changed on their Mac.
- **Too little space:** offer `./setup.sh --no-neural`, and say what they would give up.

---

## 1. Get the code

```sh
git clone https://github.com/radam5000/speakyspeak.git ~/speakyspeak
cd ~/speakyspeak
```
Expected: the folder `~/speakyspeak` exists and contains `setup.sh`. The location is free-form; a projects folder works the same.

**Keep this folder after installing.** Updates come through it.

---

## 2. Run the setup

```sh
./setup.sh
```
It takes one to ten minutes, depending on the download (about 1.5 GB for the neural voice). Give the command a long timeout, or run it in the background and wait. It asks no questions, needs no Homebrew, and is safe to run again.

What it does, in order:

1. **Checks this Mac** (`scripts/doctor.sh --before`) and stops with a line starting `FIX` if something is in the way. Do what the arrow under it says, then run `./setup.sh` again. If the fix needs the user's hands (a window to click, a system update), tell them exactly what to click.
2. **Installs the neural voice** on Apple silicon: [uv](https://docs.astral.sh/uv/) into `~/.local/bin` if it is missing, then mlx-audio in its own folder, then the Kokoro model. If this fails, the macOS voice reads replies and everything else still installs. `./setup.sh --no-neural` skips it on purpose.
3. **Builds the app** from source into `~/Applications/SpeakySpeak.app`, copies three scripts to `~/.claude/hooks/`, and adds four hooks to Claude Code's `settings.json`. It only adds: everything already in the file stays, and a backup is written next to it.
4. **Opens the app and says hello out loud**, through the same queue replies use.
5. **Checks the result.** The last lines should be `All good.` and `SpeakySpeak is installed.`

Expected: exit code 0, and the user hears "Hi, I'm SpeakySpeak". A "Sy" icon is in the menu bar. If the exit code is 1, act on the `FIX` lines; `scripts/doctor.sh` runs the same check any time.

---

## 3. Hear a real reply

On current Claude Code, new hooks are picked up without restarting, so this session's next reply may already be spoken. Send a short reply and ask the user whether they heard it. On an older Claude Code, ask them to start a **new** session (a new terminal window, a new chat in the desktop app, a new panel in VS Code or Cursor) and send it any short message.

Check it yourself:
```sh
tail -3 /tmp/claude-speech/hook.log
```
Expected: a line with `spoke` and `engine=` for the reply. If there is none, run `scripts/doctor.sh` and see Troubleshooting below.

---

## 4. One question about the terminal, then stop

SpeakySpeak works with any terminal and you have not touched the user's. Adam, who built it, runs one iTerm2 window per project with the whole title bar in that project's colour, so a spoken reply tells you which window to look at. Offer that exactly once, in one plain sentence, and treat silence or a shrug as "keep":

> SpeakySpeak is installed and working. One optional thing: keep your terminal exactly as it is, or set up iTerm2 the way Adam uses it, one coloured window per project? Keeping it as is is fine.

- **Keep:** say nothing more about it. Done.
- **Set it up:** follow "A window per project, each its own colour" in [GUIDE.md](GUIDE.md): the four `defaults write` lines with iTerm2 quit (skip the optional fourth unless they want the + button gone), then tell them how to colour a window: right-click its title bar, pick a colour dot. If iTerm2 is not installed, they can get it from https://iterm2.com first. If you are running inside iTerm2 yourself (`$TERM_PROGRAM` is `iTerm.app`), never quit it: that ends this session. Walk the user through the four Settings steps in that section instead; they work with iTerm2 running.

Do not attach other questions to this one. The whole install asks the user two things at most (the language check before step 2, and this).

## Logs

- `/tmp/claude-speech/hook.log` — the Stop hook (per-reply render)
- `/tmp/claude-speech/deck.log` — the app
- `/tmp/claude-speech/tts-daemon.log` — the warm Kokoro renderer (also `~/Library/Logs/speakyspeak-tts.out.log` / `.err.log` from the LaunchAgent)

---

## Troubleshooting

Run `scripts/doctor.sh` first: it checks everything below that a machine can check and prints the fix.

| Symptom | Cause | Fix |
|---|---|---|
| Audio plays but is much quieter than normal speech | The app was moved out of `~/Applications`, so the hook can't reach its encoder | Move it back to `~/Applications` |
| ~3 second delay before every reply starts speaking | Warm TTS daemon isn't running, OR the daemon is fine but the **active voice isn't cached** — the daemon runs offline (`HF_HUB_OFFLINE=1`) and can't fetch a missing voice, so every render falls to the cold CLI. `tts-daemon.log` showing `IncompleteSnapshotError` with a `voices/*.safetensors` file confirms it | Cache the voice the hook actually uses: `V=$(cat ~/.claude/speak-voice-kokoro 2>/dev/null \|\| echo bf_lily); ~/.local/bin/mlx_audio.tts.generate --model mlx-community/Kokoro-82M-bf16 --voice "$V" --text ok --file_prefix /tmp/vfix --join_audio; rm -f /tmp/vfix*.wav`, then `launchctl kickstart -k gui/$(id -u)/com.adamraabe.speakyspeak-tts`; check `~/Library/Logs/speakyspeak-tts.err.log` for other crash detail |
| No speech at all, and `/tmp/claude-speech/hook.log` has no new lines after a turn | Hook not registered in `~/.claude/settings.json`, or the session predates the registration on an older Claude Code | Run `bash scripts/wire-hooks.sh` from the repo and run `scripts/doctor.sh`; if still silent, start a **new** Claude Code session |
| No speech at all, but `hook.log` shows the hook ran | `~/.claude/speak-off` exists (hard kill), or the app is muted | `rm -f ~/.claude/speak-off`; right-click the menu-bar icon and check Mute is off |
| No speech and no menu-bar icon | The user quit SpeakySpeak, which leaves `~/.claude/speak-quit` so replies stay silent until they open it again | `open ~/Applications/SpeakySpeak.app` (opening it deletes the file) |
| Voice sounds robotic / like the built-in macOS voice | The neural voice isn't installed, or the active voice isn't cached (see the delay row above) | `./setup.sh` again; or, for a better macOS voice, System Settings → Accessibility → Spoken Content → System Voice (e.g. Ava Premium), which the hook finds automatically |
| No menu-bar icon | App isn't running | `open ~/Applications/SpeakySpeak.app` |
| Silent, and `hook.log` says `scripted run (sdk-cli) not read aloud` | The session runs through `claude -p` or the Agent SDK, which SpeakySpeak keeps quiet by default | `touch ~/.claude/speak-headless` (or Settings ▸ Speech ▸ Read scripted runs too) |
| Replies queue up (orange dot on the icon) but none plays, or one pauses by itself | Another app has the microphone on, and SpeakySpeak waits for it. `deck.log` says `microphone on: <app>` | Press play once to hear replies anyway, close the app that holds the microphone, or turn off Settings ▸ Speech ▸ "Pause while you dictate" |
| "Update to X…" fails, or Settings says your copy has changes that clash | The clone has edits that touch the same lines as the update; the updater left it exactly as it was | Settings ▸ About ▸ "Copy the prompt for Claude", or by hand: in the clone, commit the edits, `git fetch && git rebase @{u}`, resolve, `./install.sh`. `/tmp/claude-speech/update.log` has the detail |

Still stuck after the table? Email **hi@speakyspeak.com** with the step that failed and the last lines of `/tmp/claude-speech/hook.log` — a human reads it and replies.

---

## By hand: the hooks

`install.sh` adds these for you. Only if it printed `Could not edit ~/.claude/settings.json`: fix the file, run `bash scripts/wire-hooks.sh`, or merge this into the top-level `"hooks"` object. Merge, don't replace.

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
  "Notification": [{ "matcher": "permission_prompt|elicitation_dialog|agent_needs_input", "hooks": [
    { "type": "command", "command": "bash ~/.claude/hooks/speak-reply.sh",
      "timeout": 120, "async": true }
  ]}],
  "SessionEnd": [{ "matcher": "*", "hooks": [
    { "type": "command", "command": "bash ~/.claude/hooks/session-end.sh" }
  ]}]
}
```

`Stop` reads the reply when a turn ends. `PostToolUse` reads a long run as it happens, if the user turns that on (Settings ▸ Speech ▸ Read replies); otherwise it exits in milliseconds. `Notification` makes permission prompts audible. `SessionEnd` clears a finished session's played items.

---

## Knobs (plain files, read by the hook and app)

All under `~/.claude/`, created by touching/writing the file — no file means default behavior.

- `speak-off` — hard kill; touch this file to stop rendering entirely (`rm -f` to re-enable)
- `speak-rate` — words per minute, `say` engine only
- `speak-voice` — `say` voice name (e.g. `Ava (Premium)`); absent = best installed voice is auto-probed
- `speak-voice-kokoro` — Kokoro voice id (default `bf_lily`; ~54 voices in the model card). New voices must be cached online once (the warm daemon runs offline) — `install.sh` handles the active voice, and auditioning a voice in Settings caches it too
- `speak-engine` — force `say` or `kokoro`; absent = kokoro when installed, else say
- `speak-headless` — exists = `claude -p` and Agent SDK runs are read aloud too (quiet by default); for users who chat through an app that drives `claude -p`
- `speak-name-first` — exists = every reply opens with its session name

### Optional: two Macs sharing one pair of AirPods

If this Mac and another Mac both run SpeakySpeak and share AirPods, they can take turns instead of fighting over playback. On each Mac, write the *other* Mac's IP address to the file below. Any address the two Macs can reach each other on works — a Tailscale IP if they use Tailscale, otherwise the local network address (System Settings → Network → Wi-Fi → Details).

```sh
echo "<other-mac-ip>" > ~/.claude/speak-peer
```

Before auto-playing, each Mac asks the peer (TCP port 48765) and waits if the peer is currently speaking, so macOS's AirPods auto-switching hands off cleanly instead of overlapping. Manual plays (clicking a queued item) never wait. If the file is absent, the peer is off, or it's unreachable, the app just plays — this fails open and is skippable if only one Mac is in use. The listener stays off the local network: without the file it is on 127.0.0.1 only, and with it on the address that reaches the peer (the Tailscale one), answering only the peer.

---

Full architecture, controls reference, and settings-window documentation: [README.md](README.md).

## Next: hand them the guide

Installation done (step 4 asked and answered). Tell the user three things about the player: click the Sy in the menu bar to show or hide it, the two arrows at its top right switch between the small and the big one, and replies pause by themselves while another app uses the microphone (dictation, a call). Then point them at [GUIDE.md](GUIDE.md) and say what it covers: the suggested setup for running several sessions at once, and what every setting does. If they run more than one Claude Code session, the sort menu's "Group by: Session" plus "Order by: Oldest first" is the single most useful thing in it.

## Uninstall

```sh
./uninstall.sh          # shows what it would remove
./uninstall.sh --yes    # removes it
```
It takes out the app, its scripts, its four entries in `settings.json` (other hooks stay; a backup is kept), its settings and the neural voice. Then delete the clone.
