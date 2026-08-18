#!/usr/bin/env python3
# SpeakySpeak warm TTS daemon.
#
# The Stop hook used to spawn the Kokoro CLI cold on every reply, paying a ~3s
# model-load tax each time. This daemon loads Kokoro ONCE at login, warms the
# MLX graph, and then renders each reply in well under a second. It's launched
# by launchd (com.adamraabe.speakyspeak-tts) with KeepAlive so a crash restarts
# it; if it's down or unresponsive the hook falls back to the cold CLI, so this
# is a pure speedup with no new failure mode.
#
# Protocol (a filesystem queue, mirroring the deck's own design):
#   hook  → writes  <RENDER>/<id>.req   (json: {text, voice, speed, out})
#   daemon → writes <out> (wav, atomic) then <RENDER>/<id>.done  ("ok" | "err:*")
#   daemon touches  <RENDER>/daemon.alive every ~2s — the hook only uses the
#                   daemon when that heartbeat is fresh, else it goes cold.

import contextlib
import glob
import json
import os
import sys
import threading
import time
import traceback

RENDER = "/tmp/claude-speech/render"
ALIVE = os.path.join(RENDER, "daemon.alive")
LOG = "/tmp/claude-speech/tts-daemon.log"
MODEL_ID = "mlx-community/Kokoro-82M-bf16"
# The project default voice. It appears in FIVE places that must stay in sync
# (grep the id when changing): speak-reply.sh KOKORO_VOICE fallback, this file,
# main.swift SettingsStore (x2), install.sh's pre-cache, and the docs.
# 2026-08-17: was af_heart here while the hook asked for bf_lily — the offline
# daemon could never fetch it and every fresh install's first reply fell to the
# cold CLI (Sasha's install report, Defect 1).
DEFAULT_VOICE = "bf_lily"
STALE_SECS = 90          # a request older than this: the hook already gave up
IDLE_SLEEP = 0.02        # poll cadence when no work is pending
ALIVE_EVERY = 2.0        # heartbeat interval


def log(msg):
    try:
        with open(LOG, "a") as f:
            f.write("%s %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg))
    except Exception:
        pass


def touch_alive():
    try:
        with open(ALIVE, "w") as f:
            f.write(str(int(time.time())))
    except Exception:
        pass


def write_status(path, status):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(status)
    os.replace(tmp, path)


def main():
    os.makedirs(RENDER, exist_ok=True)
    # A fresh daemon owns a clean queue — any leftover reqs/dones predate us and
    # no live hook is waiting on them.
    for p in glob.glob(os.path.join(RENDER, "*.req")) + glob.glob(os.path.join(RENDER, "*.done")):
        try:
            os.remove(p)
        except Exception:
            pass

    log("loading %s ..." % MODEL_ID)
    t0 = time.time()
    from mlx_audio.tts.generate import generate_audio
    from mlx_audio.tts.utils import load_model
    model = load_model(model_path=MODEL_ID)

    # Warm the MLX graph with a throwaway render so the FIRST real reply is fast
    # too (the initial compile is ~1.5s; pay it here, not on Adam's first reply).
    try:
        warm = os.path.join(RENDER, ".warmup")
        # warm on the voice the hook will actually request, not just the default
        try:
            with open(os.path.expanduser("~/.claude/speak-voice-kokoro")) as vf:
                warm_voice = vf.read().strip() or DEFAULT_VOICE
        except OSError:
            warm_voice = DEFAULT_VOICE
        with open(LOG, "a") as lf, contextlib.redirect_stdout(lf), contextlib.redirect_stderr(lf):
            generate_audio(text="Ready.", model=model, voice=warm_voice,
                           join_audio=True, file_prefix=warm,
                           audio_format="wav", verbose=False)
        for f in glob.glob(warm + "*"):
            try:
                os.remove(f)
            except Exception:
                pass
    except Exception as e:
        log("warmup failed (non-fatal): %r" % e)

    log("ready in %.1fs — watching %s" % (time.time() - t0, RENDER))
    touch_alive()
    # heartbeat on its own thread so a long render can't starve it (the hook
    # only trusts the daemon while this file is fresh)
    def heartbeat():
        while True:
            touch_alive()
            time.sleep(ALIVE_EVERY)
    threading.Thread(target=heartbeat, daemon=True).start()

    while True:
        now = time.time()
        try:
            pending = sorted(n for n in os.listdir(RENDER)
                             if n.endswith(".req") and not n.startswith("."))
        except FileNotFoundError:
            os.makedirs(RENDER, exist_ok=True)
            pending = []

        if not pending:
            time.sleep(IDLE_SLEEP)
            continue

        for name in pending:
            path = os.path.join(RENDER, name)
            rid = name[:-4]
            done = os.path.join(RENDER, rid + ".done")
            try:
                if now - os.path.getmtime(path) > STALE_SECS:
                    os.remove(path)
                    continue
                with open(path) as f:
                    req = json.load(f)
                os.remove(path)

                text = (req.get("text") or "").strip()
                voice = req.get("voice") or DEFAULT_VOICE
                out = req["out"]
                speed = float(req.get("speed", 1.0))
                if not text:
                    write_status(done, "err:empty")
                    continue

                scratch = os.path.join(RENDER, ".render-" + rid)
                rt = time.time()
                with open(LOG, "a") as lf, contextlib.redirect_stdout(lf), contextlib.redirect_stderr(lf):
                    generate_audio(text=text, model=model, voice=voice, speed=speed,
                                   join_audio=True, file_prefix=scratch,
                                   audio_format="wav", verbose=False)
                src = scratch + ".wav"
                if os.path.exists(src) and os.path.getsize(src) > 0:
                    os.replace(src, out)
                    write_status(done, "ok")
                    log("rendered %s in %.2fs (voice=%s, %d chars)"
                        % (rid, time.time() - rt, voice, len(text)))
                else:
                    write_status(done, "err:no-output")
                    log("no output for %s" % rid)
            except Exception:
                log("error on %s: %s" % (name, traceback.format_exc().replace("\n", " | ")))
                try:
                    write_status(done, "err:exception")
                except Exception:
                    pass
                try:
                    os.remove(path)
                except Exception:
                    pass


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
    except Exception:
        log("fatal: " + traceback.format_exc().replace("\n", " | "))
        try:
            os.remove(ALIVE)   # so the hook falls back immediately
        except Exception:
            pass
        sys.exit(1)
