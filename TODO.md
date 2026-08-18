# SpeakySpeak — TODO

## Inbox

## Now
- [ ] ss-loop-promote-draft — the feedback loop's first trust promotion (triage → draft): earliest ~2026-09-01 after two clean weeks of triage, and ONLY on Adam's explicit go. Check first: classifications right, dedupe real, ack replies ones Adam would have sent, digest reads well. Promote = LOOP_MODE in scripts/loop/*.plist + bootout/copy/bootstrap.
- [ ] ss-voiceover-audit — VoiceOver audit of the APP (not the site; the site passed 2026-08-17). Approved to happen before any launch post. 12 accessibilityLabel calls exist, no traits/values tested.

## Next
- [ ] ss-reddit-karma — Adam builds u/radamradam past 50 karma (genuine comments in r/ClaudeAI, r/macapps) so the week-3 r/ClaudeAI launch post clears the gate. Repo age gates clear ~2026-08-30.
- [ ] ss-github-release — cut a GitHub release with a zipped .app (~1h; unblocks MacUpdate, Homebrew tap, directories).
- [ ] ss-launch — execute PLAN-LAUNCH.md Part 1 (r/ClaudeAI first, PH Wed/Thu week 3-4, Show HN week 4+). Remaining decisions in the plan's decision list (PH date, skip list, notarization, privacy policy, plugin marketplace).
- [ ] ss-a11y-page — dedicated accessibility page idea (parked 2026-08-17 when the visible transcript expander was pulled; sr-only transcript remains in the page).

## Later

## Done
- [x] 2026-08-18 — 1.1.0 shipped: the whole update-UX arc from Adam's live testing (visible progress, reliable self-relaunch, uncached update checks, written + spoken confirmation), app-wide loudness/volume consistency audit (Kokoro + say, Homebrew + MacPorts ffmpeg), menu reorder (Mute above Settings, separator), report-button copy. CHANGELOG.md added + linked from the site footer.
- [x] 2026-08-18 — Air converted to a real end-user install (public-mirror clone, pinned one version back, self-updating); `speakyspeak-air` retired with its decisions preserved in the stub. First real feedback-loop run exercised on Adam's own Air-submitted report — correctly classified as a flow test, diagnostics filed, no false issue/reply.
- [x] 2026-08-18 — ss-updater-feedback-poll CLOSED by 1.0.10: updater rewritten after a real field failure (silent pkill no-op on the 1.0.8→1.0.9 hop) — marker-file completion, self-terminate + waiter relaunch, live progress/failure UI in Settings, every step logged.
- [x] 2026-08-18 — ss-verify-sh built (verify.sh: syntax + build + 4 hook-contract fixture tests + INSTALL.md json + launch smoke; wired as the loop's releasability gate).
- [x] 2026-08-18 — ss-feedback-email COMPLETE + the whole feedback loop LIVE: hi@speakyspeak.com + catch-all on Fastmail (identities "SpeakySpeak", round-trip verified: Gmail inbox outbound, external inbound past greylist), DNS via Cloudflare; address on site footer / README / INSTALL / in-app "Send Feedback…" (1.0.7 released); FEEDBACK.md ledger + mirror exclude; verify.sh (compile + 4 hook-contract fixture tests, all green) ; daily triage loop under launchd 07:45 (scripts/loop/, first real run clean same night); registered in AUTOMATION.md + mother-routine registry; fmmail.py gained fetch/--in-reply-to.
- [x] 2026-08-17 — 1.0.6: Sasha's install report actioned (voice-cache bug fixed at all 5 sync points + install.sh pre-cache, Settings voice mismatch, inverted step-7 verification + hook success logging, step 6.5 agent self-verify); README/site now own the "Claude installs it" story.
- [x] 2026-08-17 — speakyspeak.com wired (Cloudflare DNS, grey cloud) and live.
- [x] 2026-08-17 — neon sign removed (kept in site/stickers/neon-sign-snippet.html); mobile sideways-scroll fixed.
- [x] 2026-08-17 — fold/2x2/caption-jump fixes shipped; hero full-page on tall desktops; stack scaled up on mobile + desktop.
- [x] 2026-08-17 — SEO + og card + JSON-LD + favicon + robots/sitemap; "Why a voice?" + "Full Feature List" sections; coherence pass for non-iTerm users; em dashes purged.
- [x] 2026-08-17 — site accessibility audit passed (VoiceOver-clean page, AA contrast, transcripts, reduced motion).
- [x] 2026-08-17 — releases 1.0.2→1.0.5: updater proven end-to-end; version visible in menu/Settings/Get Info; Update button in menu + deck footer + Settings; ↑ icon hint.
- [x] 2026-08-17 — INSTALL.md adapt-to-your-setup section; desktop-app hook support PROVEN live (Adam's test); VS Code/Cursor claimed on mechanism, unobserved.
- [x] 2026-08-17 — PLAN-LAUNCH.md written (distribution + feedback loop, private).
- [x] 2026-08-17 — "Press play" annotations replaced with Adam's handwriting, both layouts.
