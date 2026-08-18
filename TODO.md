# SpeakySpeak — TODO

## Inbox

## Now
- [~] ss-feedback-email — repo side DONE 2026-08-17 (site footer + README + INSTALL + in-app "Send Feedback…" mailto with version/engine/log context; FEEDBACK.md created + excluded from the mirror in the same commit; weekly-sweep rule in CLAUDE.md). BLOCKED on two permission-classifier denials Adam must clear: (1) Fastmail add-domain form (Claude's tab is parked at the Add domain page) — or Adam adds speakyspeak.com + hi@ + catch-all + identity name "SpeakySpeak" himself, ~2 min; (2) the Cloudflare DNS-write curl (records are scripted and ready). Then: round-trip verify, deploy site, bump VERSION, release-public.sh. Do NOT publish the address (site deploy / release) before the round-trip passes.
- [ ] ss-voiceover-audit — VoiceOver audit of the APP (not the site; the site passed 2026-08-17). Approved to happen before any launch post. 12 accessibilityLabel calls exist, no traits/values tested.

## Next
- [ ] ss-reddit-karma — Adam builds u/radamradam past 50 karma (genuine comments in r/ClaudeAI, r/macapps) so the week-3 r/ClaudeAI launch post clears the gate. Repo age gates clear ~2026-08-30.
- [ ] ss-github-release — cut a GitHub release with a zipped .app (~1h; unblocks MacUpdate, Homebrew tap, directories).
- [ ] ss-verify-sh — verify.sh test harness (prerequisite for the Phase 2 autonomous fix loop; retro-covers the extract/gather regression class).
- [ ] ss-launch — execute PLAN-LAUNCH.md Part 1 (r/ClaudeAI first, PH Wed/Thu week 3-4, Show HN week 4+). Remaining decisions in the plan's decision list (PH date, skip list, notarization, privacy policy, plugin marketplace).
- [ ] ss-a11y-page — dedicated accessibility page idea (parked 2026-08-17 when the visible transcript expander was pulled; sr-only transcript remains in the page).

## Later
- [ ] ss-updater-feedback-poll — consider surfacing update progress (update.log tail) in the UI; today success is silent until relaunch.

## Done
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
