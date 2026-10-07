#!/usr/bin/env python3
# Prints one line per thing GUIDE.md fails to explain: a Settings control, or a
# ~/.claude knob the hook or the app reads. Nothing printed = the guide covers
# the app. Run from the repo root (verify.sh step 6); tests/guide-gate-test.sh
# proves it catches a planted gap. Why it exists: Adam, 2026-10-04, "always
# make sure it's up to date".
import re
src = open("main.swift").read()
guide = open("GUIDE.md").read().lower()
start = src.index("struct SettingsView: View {")
end = re.compile(r"^(final class|struct|enum|class) ", re.M).search(src, start + 1).start()
view = src[start:end]
labels = set(re.findall(r'(?:Toggle|Picker|Section|LabeledContent)\("([^"\\]+)"', view))
labels |= set(re.findall(r'\}\s*label:\s*\{\s*Text\("([^"\\]+)"\)', view))
# a label that is not something a user sets (a status line, say) goes here,
# with why; empty means every label is a real control
EXEMPT = set()
for l in sorted(labels - EXEMPT):
    if l.lower() not in guide:
        print("Settings control '%s'" % l)
knobs = set()
for f in ["hooks/speak-reply.sh", "hooks/session-end.sh", "hooks/tts-daemon.py", "main.swift"]:
    try:
        t = open(f).read()
    except OSError:
        continue
    knobs |= set(re.findall(r'\.claude/(speak-[a-z0-9-]+)', t))
    knobs |= set(re.findall(r'(?:setFlag|writeOrRemove|path|read)\("(speak-[a-z0-9-]+)"', t))
for k in sorted(knobs):
    if not re.search(re.escape(k) + r'(?![a-z0-9-])', guide):
        print("knob ~/.claude/%s" % k)
