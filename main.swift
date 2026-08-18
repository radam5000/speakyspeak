// SpeakySpeak — one tiny floating panel that queues and plays Claude Code's
// spoken replies, one at a time, in arrival order.
//
// The speak-reply.sh Stop hook renders each reply to audio and drops
//   /tmp/claude-speech/queue/<epoch>-<sid>.m4a   (audio, written first)
//   /tmp/claude-speech/queue/<epoch>-<sid>.json  (manifest: session/project/title/preview/text/created)
// The session-end.sh SessionEnd hook drops <epoch>-<sid>.end to remove that
// session's items. SpeakySpeak watches the directory and owns all playback,
// so two sessions finishing together can never talk over each other.
// .done markers persist played state across app restarts.

import AppKit
import SwiftUI
import AVFoundation
import MediaPlayer   // Now Playing + AirPods stem clicks / media keys
import Network       // peer gate: two Macs taking turns on one pair of AirPods
import Combine
import CoreText
import CoreImage
import Carbon.HIToolbox   // global "quiet" hotkey (RegisterEventHotKey — no Accessibility prompt)

let queueDir = URL(fileURLWithPath: "/tmp/claude-speech/queue", isDirectory: true)
let logPath = "/tmp/claude-speech/deck.log"

func dlog(_ s: String) {
    let line = "\(Date()) \(s)\n"
    if let h = FileHandle(forWritingAtPath: logPath) {
        h.seekToEndOfFile()
        if let d = line.data(using: .utf8) { h.write(d) }
        h.closeFile()
    } else {
        try? line.write(toFile: logPath, atomically: false, encoding: .utf8)
    }
}

// MARK: - Anthropic-flavored palette

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}

struct Theme {
    let bg, card, cardStroke, text, secondary, track, hover: Color
    let swirlIntensity: Double

    static let accent = Color(hex: 0xD97757)      // Claude terracotta
    static let accentDeep = Color(hex: 0xBC5F3D)

    static func of(_ scheme: ColorScheme) -> Theme {
        scheme == .dark
            ? Theme(bg: Color(hex: 0x262624), card: Color(hex: 0x30302E),
                    cardStroke: Color.white.opacity(0.07), text: Color(hex: 0xECEAE4),
                    secondary: Color(hex: 0xA09B90), track: Color.white.opacity(0.13),
                    hover: Color.white.opacity(0.05), swirlIntensity: 0.34)
            : Theme(bg: Color(hex: 0xFAF9F5), card: Color(hex: 0xF0EEE6),
                    cardStroke: Color.black.opacity(0.06), text: Color(hex: 0x1F1E1D),
                    secondary: Color(hex: 0x87827A), track: Color.black.opacity(0.09),
                    hover: Color.black.opacity(0.04), swirlIntensity: 0.26)
    }
}

// MARK: - Model

struct SpeechItem: Identifiable, Equatable {
    enum State { case queued, playing, done }
    let id: String
    let sessionId: String
    let project: String
    let title: String      // session title (/rename); falls back to project
    let preview: String
    let text: String       // full cleaned reply — "" in pre-text manifests
    let created: Date
    let audioURL: URL
    var state: State = .queued
}

// MARK: - Playback + queue state

final class Deck: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = Deck()

    @Published var items: [SpeechItem] = []
    @Published var currentID: String?
    @Published var isPlaying = false
    @Published var progress: Double = 0
    @Published var duration: Double = 0
    @Published var level: Double = 0     // smoothed 0…1 speech loudness, drives the swirl
    // NEVER touch NowPlayingBridge (or anything reading Deck.shared) from a
    // didSet that fires during init — update() reads Deck.shared while its
    // dispatch_once lock is still held and traps (crashed at launch 2026-08-15,
    // same recursion class as the SettingsStore say-voices crash of 2026-07-20).
    private var initDone = false
    @Published var rate: Double = 1.0 {
        didSet {
            player?.rate = Float(rate)
            UserDefaults.standard.set(rate, forKey: "rate")
            if initDone { NowPlayingBridge.shared.update() }
        }
    }
    @Published var muted = false {
        didSet { UserDefaults.standard.set(muted, forKey: "muted") }
    }
    // AVAudioPlayer volume is attenuate-only (0…1); the hook loudness-normalizes
    // renders so 1.0 here matches normal speech level
    @Published var volume: Double = 1.0 {
        didSet { player?.volume = Float(volume); UserDefaults.standard.set(volume, forKey: "volume") }
    }
    // mirrors the absence of ~/.claude/speak-off — the same kill switch the
    // Stop hook honors, so one button turns the whole pipeline on and off
    @Published var enabled = true
    // .help() tooltips are flaky in a non-activating accessory panel, so
    // hovered controls also describe themselves in the footer hint line
    @Published var hint = ""
    // drives the "back one track" button's enabled state (published so the
    // transport updates); the ids themselves live in `history` below
    @Published private(set) var historyCount = 0
    // bumped on every flash-worthy event (a reply starts, skip, back, restart);
    // the mini HUD watches this to fire its bright white "here I am" flash
    @Published private(set) var flashTick = 0
    func triggerFlash() { flashTick &+= 1 }

    // A reply is queued but held behind a paused one — the HUD ripples rainbow
    // until any interaction (hover counts) or until playback resumes.
    @Published private(set) var attentionWanted = false
    func clearAttention() { if attentionWanted { attentionWanted = false } }
    var scrubbing = false

    private let speakOffURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/speak-off")
    private var claudeDirSource: DispatchSourceFileSystemObject?

    private override init() {
        super.init()
        muted = UserDefaults.standard.bool(forKey: "muted")
        let r = UserDefaults.standard.double(forKey: "rate")
        if rateSteps.contains(r) { rate = r }
        if UserDefaults.standard.object(forKey: "volume") != nil {
            volume = min(max(UserDefaults.standard.double(forKey: "volume"), 0), 1)
        }
        enabled = !FileManager.default.fileExists(atPath: speakOffURL.path)
        initDone = true
    }

    private func refreshEnabled() {
        let on = !FileManager.default.fileExists(atPath: speakOffURL.path)
        guard on != enabled else { return }
        enabled = on
        dlog(on ? "speech on" : "speech off")
        if !on {
            advanceGen += 1
            if isPlaying { player?.pause(); isPlaying = false; stopMeter(); dlog("paused (speech off)") }
        }
    }

    // speak-off can also be toggled from the shell; keep the button honest
    private func watchClaudeDir() {
        let fd = open(speakOffURL.deletingLastPathComponent().path, O_EVTONLY)
        guard fd >= 0 else { dlog("watch failed: cannot open ~/.claude"); return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in self?.refreshEnabled() }
        src.setCancelHandler { close(fd) }
        src.resume()
        claudeDirSource = src
    }

    private var player: AVAudioPlayer?
    private var meterTimer: Timer?
    private var fsSource: DispatchSourceFileSystemObject?
    private var advanceGen = 0   // invalidates a pending chime-gap advance if anything else happens
    // ids in the order they started playing, most recent last, excluding the
    // current one — the "back one track" stack. Grows on each new play, pops on
    // playPrevious. Small and pruned when items are removed.
    private var history: [String] = [] { didSet { historyCount = history.count } }

    var current: SpeechItem? { items.first { $0.id == currentID } }
    var hasQueued: Bool { items.contains { $0.state == .queued } }
    // paused partway through a reply — autoplay must not steal playback
    var isPausedMidItem: Bool {
        player != nil && !isPlaying && currentID != nil && progress < max(duration - 0.3, 0)
    }

    func start() {
        try? FileManager.default.createDirectory(at: queueDir, withIntermediateDirectories: true)
        dlog("deck started (muted: \(muted), rate: \(rate), enabled: \(enabled))")
        rescan(initial: true)
        watch()
        watchClaudeDir()
    }

    private func watch() {
        let fd = open(queueDir.path, O_EVTONLY)
        guard fd >= 0 else { dlog("watch failed: cannot open queue dir"); return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in self?.rescan() }
        src.setCancelHandler { close(fd) }
        src.resume()
        fsSource = src
    }

    func rescan(initial: Bool = false) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: queueDir.path) else { return }

        for name in names where name.hasSuffix(".end") && !name.hasPrefix(".") {
            let stem = String(name.dropLast(4))
            let sid = stem.split(separator: "-").dropFirst().joined(separator: "-")
            if !sid.isEmpty { removeAll(sessionId: String(sid)) }
            try? fm.removeItem(at: queueDir.appendingPathComponent(name))
        }

        // drop items whose files were cleaned up externally (2-day sweep, manual rm)
        let nameSet = Set(names)
        items.removeAll { item in
            guard item.id != currentID, !nameSet.contains(item.id + ".json") else { return false }
            dlog("pruned \(item.id) (files removed externally)")
            return true
        }

        let known = Set(items.map(\.id))
        var added = false
        for name in names.sorted() where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let id = String(name.dropLast(5))
            guard !known.contains(id) else { continue }
            let audioURL = queueDir.appendingPathComponent(id + ".m4a")
            guard fm.fileExists(atPath: audioURL.path),
                  let data = try? Data(contentsOf: queueDir.appendingPathComponent(name)),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            var item = SpeechItem(
                id: id,
                sessionId: obj["session"] as? String ?? "",
                project: obj["project"] as? String ?? "?",
                title: { let t = obj["title"] as? String ?? ""
                         return t.isEmpty ? (obj["project"] as? String ?? "?") : t }(),
                preview: obj["preview"] as? String ?? "",
                text: obj["text"] as? String ?? "",
                created: Date(timeIntervalSince1970: (obj["created"] as? Double) ?? 0),
                audioURL: audioURL)
            // played state survives app restarts via a .done marker
            if fm.fileExists(atPath: queueDir.appendingPathComponent(id + ".done").path) {
                item.state = .done
            }
            // newest reply plays next: a fresh arrival slots in at the top
            // of Up Next (right under whatever is speaking) and stale
            // backlog sinks. (ids start with the stop epoch, so descending
            // id = newest first; a fast-rendering reply still can't jump
            // an even newer one.) done items and manual moves are left alone.
            if let at = items.firstIndex(where: { $0.state == .queued && $0.id < item.id }) {
                items.insert(item, at: at)
            } else {
                items.append(item)
            }
            dlog("queued \(id)")
            added = true
        }
        if added {
            // No window is forced forward on arrival — the menu-bar icon's
            // badge and pulse signal the new reply instead.
            if !enabled {
                dlog("arrival while speech off — queued silently")
            } else if initial {
                // relaunching must not blast a stale backlog — on the first
                // scan, only a reply that just arrived (the hook may have
                // cold-started us to play it) starts playback by itself
                if !muted, !isPlaying,
                   let fresh = items.first(where: { $0.state == .queued && Date().timeIntervalSince($0.created) < 120 }) {
                    autoplayGated(fresh)   // cold-start autoplay also yields to the peer
                } else {
                    dlog("initial scan: \(items.count) item(s) restored, autoplay held")
                }
            } else {
                maybeAutoplay()
            }
        }
    }

    private var peerWaitPending = false   // one re-poll in flight at a time

    // One flash per waiting reply, not per poll — the held branch runs again on
    // every queue event while the same reply is still waiting.
    private var flashedHoldID: String?

    private func maybeAutoplay() {
        guard !muted, !isPlaying else { return }
        if isPausedMidItem {
            dlog("autoplay held: \(currentID ?? "?") paused mid-reply")
            // Adam chose a visual cue over auto-resume (2026-08-16): a reply
            // waiting behind a paused one ripples the HUD instead of playing.
            if let waiting = items.first(where: { $0.state == .queued }), waiting.id != flashedHoldID {
                flashedHoldID = waiting.id
                attentionWanted = true
                MiniHUDController.shared.summonForAttention()
            }
            return
        }
        if let next = items.first(where: { $0.state == .queued }) { autoplayGated(next) }
    }

    // Automatic starts wait for the peer Mac's deck to go quiet (PeerGate);
    // manual plays call play() directly and never wait. The peer check is
    // async, so every deck condition is re-checked when the answer lands.
    private func autoplayGated(_ item: SpeechItem) {
        PeerGate.shared.peerBusy { [weak self] busy in
            guard let self else { return }
            guard !self.muted, !self.isPlaying, !self.isPausedMidItem else { return }
            guard self.items.contains(where: { $0.id == item.id && $0.state == .queued }) else {
                self.maybeAutoplay()   // that item was played/removed meanwhile — re-pick
                return
            }
            guard busy else { self.play(item); return }
            dlog("peer deck speaking — holding autoplay")
            guard !self.peerWaitPending else { return }
            self.peerWaitPending = true
            // jittered re-poll so two decks released together don't collide
            DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: 1.5...2.5)) {
                self.peerWaitPending = false
                self.maybeAutoplay()
            }
        }
    }

    func toggleMute() {
        muted.toggle()
        if muted {
            advanceGen += 1 // cancel any pending chime-gap advance
            if isPlaying { player?.pause(); isPlaying = false; stopMeter() }
            dlog("muted")
        } else {
            dlog("unmuted")
            if let p = player, currentID != nil, !isPlaying, progress < max(duration - 0.3, 0) {
                resumeCurrent(p)
                dlog("resumed after unmute")
            } else {
                maybeAutoplay()
            }
        }
    }

    func play(_ item: SpeechItem, recordHistory: Bool = true) {
        clearAttention()   // audio is flowing again — stop the ripple
        muted = false   // explicitly playing something means "I want sound"
        advanceGen += 1 // cancel any pending chime-gap advance
        // remember what we're leaving so "back one track" can return to it
        // (playPrevious replays with recordHistory:false so it doesn't re-push)
        if recordHistory, let cid = currentID, cid != item.id { history.append(cid) }
        // an interrupted reply goes back to the queue instead of getting stuck
        // in .playing limbo (where neither list section would show it)
        if let cid = currentID, cid != item.id,
           let i = items.firstIndex(where: { $0.id == cid }), items[i].state == .playing {
            items[i].state = .queued
            dlog("requeued interrupted \(cid)")
        }
        stopPlayer()
        guard let p = try? AVAudioPlayer(contentsOf: item.audioURL) else {
            dlog("cannot open \(item.id), skipping")
            setState(item.id, .done)
            maybeAutoplay()
            return
        }
        p.delegate = self
        p.enableRate = true
        p.isMeteringEnabled = true
        p.rate = Float(rate)
        p.volume = Float(volume)
        p.prepareToPlay()
        player = p
        currentID = item.id
        setState(item.id, .playing)
        duration = p.duration
        progress = 0
        p.play()
        isPlaying = true
        startMeter()
        triggerFlash()   // new reply / skip / back all land here → flash
        dlog("playing \(item.id) (\(item.project))")
    }

    private func startMeter() {
        meterTimer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        meterTimer = t
    }

    private func stopMeter() {
        meterTimer?.invalidate()
        meterTimer = nil
        level = 0
    }

    private func tick() {
        guard let p = player else { return }
        if !scrubbing { progress = p.currentTime }
        p.updateMeters()
        let db = Double(p.averagePower(forChannel: 0))
        let norm = min(1, max(0, (db + 50) / 50))
        // fast attack, slow release — reads as the voice "breathing"
        level = norm > level ? norm : level * 0.90 + norm * 0.10
    }

    func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            // a replaced player finishing late must not mark the NEW current
            // item done (and then advance over it while it's still speaking)
            guard p === self.player else { dlog("ignored finish from replaced player"); return }
            if let id = self.currentID { self.setState(id, .done); dlog("finished \(id)") }
            self.isPlaying = false
            self.progress = self.duration
            self.stopMeter()
            // moving on to a queued reply: soft chime, a breath, then the next voice
            if !self.muted, self.hasQueued {
                self.advanceGen += 1
                let gen = self.advanceGen
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    guard gen == self.advanceGen, !self.isPlaying else { return }
                    let chime = NSSound(named: "Tink")
                    chime?.volume = Float(0.45 * self.volume)
                    chime?.play()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    guard gen == self.advanceGen, !self.isPlaying else { return }
                    self.maybeAutoplay()
                }
            } else {
                self.maybeAutoplay()
            }
        }
    }

    func togglePlay() {
        clearAttention()   // any transport touch counts as "seen"
        if isPlaying {
            player?.pause()
            isPlaying = false
            stopMeter()
            dlog("paused \(currentID ?? "?")")
            return
        }
        muted = false
        if let p = player, currentID != nil {
            if progress >= max(duration - 0.3, 0) { p.currentTime = 0; progress = 0 }
            resumeCurrent(p)
            dlog("resume/replay \(currentID ?? "?")")
        } else if let cur = current {
            play(cur)   // player gone (playNext into empty queue, load failure) — reload it
        } else if let next = items.first(where: { $0.state == .queued }) {
            play(next)
        }
    }

    func seek(to t: Double) {
        progress = max(0, min(t, duration))
        player?.currentTime = progress
        NowPlayingBridge.shared.update()   // keep Control Center's elapsed honest
    }

    func skip(_ delta: Double) { seek(to: progress + delta) }

    // The global "quiet" hotkey routes here: only skip when something is
    // actually sounding (or paused mid-reply), so the key can never cold-start
    // audio from a silent, idle deck — it's "make this stop," never "start."
    func quietSkip() {
        guard isPlaying || isPausedMidItem else { dlog("quiet hotkey: idle, ignored"); return }
        playNext()
    }

    // "Skip" = stop hearing the current reply. If something's queued it plays
    // next (the deck is serial); if nothing is, it goes quiet and resets to
    // idle. Works even with an empty queue, so the skip button / global hotkey
    // double as a "make this stop" with no pause/mute side effects.
    func playNext() {
        if let id = currentID { setState(id, .done) }
        if let next = items.first(where: { $0.state == .queued }) {
            play(next)
        } else {
            stopPlayer()
            currentID = nil
            progress = 0
            duration = 0
            dlog("skip into empty queue — quiet")
        }
    }

    // "Back one track" = replay the reply that played before this one. Pops the
    // history stack and replays without re-recording (so pressing it repeatedly
    // walks back through the played replies). The current reply is requeued by
    // play(), so letting the earlier one finish resumes forward through the queue.
    @discardableResult
    func playPrevious() -> Bool {
        while let prevID = history.popLast() {
            if let item = items.first(where: { $0.id == prevID }) {
                dlog("back one track → \(prevID)")
                play(item, recordHistory: false)
                return true
            }
            // that reply was cleared; keep popping to the next real one
        }
        dlog("back one track: no history")
        return false
    }

    // The ⏮ button, music-player style: more than a few seconds into the current
    // reply → restart it; only when already near the start does it jump to the
    // previously-played reply (and if there's none earlier, it just restarts).
    func backTrack() {
        if currentID != nil, progress > 3 { seek(to: 0); triggerFlash(); return }
        if !playPrevious(), currentID != nil { seek(to: 0); triggerFlash() }
    }

    // Swap a queued item with its neighbor in play order (delta -1 = earlier, +1 = later).
    func moveQueued(_ item: SpeechItem, by delta: Int) {
        let q = items.enumerated().filter { $0.element.state == .queued }
        guard let pos = q.firstIndex(where: { $0.element.id == item.id }) else { return }
        let target = pos + delta
        guard target >= 0, target < q.count else { return }
        items.swapAt(q[pos].offset, q[target].offset)
        dlog("moved \(item.id) \(delta > 0 ? "later" : "earlier")")
    }

    private let rateSteps: [Double] = [1.0, 1.25, 1.5, 2.0, 0.8]

    func cycleRate() {
        let i = rateSteps.firstIndex(of: rate) ?? 0
        rate = rateSteps[(i + 1) % rateSteps.count]
    }

    func remove(_ item: SpeechItem) {
        let wasCurrentlyPlaying = item.id == currentID && isPlaying
        if item.id == currentID {
            stopPlayer()
            currentID = nil
            progress = 0
            duration = 0
        }
        items.removeAll { $0.id == item.id }
        history.removeAll { $0 == item.id }
        try? FileManager.default.removeItem(at: item.audioURL)
        try? FileManager.default.removeItem(at: queueDir.appendingPathComponent(item.id + ".json"))
        try? FileManager.default.removeItem(at: queueDir.appendingPathComponent(item.id + ".done"))
        // only removing the reply that was speaking advances the queue —
        // deleting an old played row must never start playback
        if wasCurrentlyPlaying { maybeAutoplay() }
    }

    func removeAll(sessionId: String) {
        // a session ending clears its already-played replies; queued ones
        // stay — they're content the user hasn't heard yet (muted/away),
        // and deleting them was how replies silently vanished
        let victims = items.filter { $0.sessionId == sessionId && $0.state == .done }
        guard !victims.isEmpty else { return }
        dlog("session \(sessionId) ended, clearing \(victims.count) played item(s)")
        for item in victims { remove(item) }
    }

    func clearDone() {
        for item in items.filter({ $0.state == .done }) { remove(item) }
    }

    func clearAll() {
        dlog("clear all (\(items.count) item(s))")
        stopPlayer()
        currentID = nil
        progress = 0
        duration = 0
        history.removeAll()
        for item in Array(items) { remove(item) }
    }

    // Re-speak the not-yet-played queue in a newly chosen voice. Warm daemon
    // ONLY — if it's down, items just keep their old audio (never a ~3s-per-item
    // cold render). Items keep their ids and queue slots; only the audio file is
    // swapped, atomically, so losing a race with play() merely means that one
    // reply speaks in the old voice.
    func reRenderQueued(voice: String) {
        let victims = items.filter { $0.state == .queued && $0.id != currentID && !$0.text.isEmpty }
        guard !victims.isEmpty else { return }
        dlog("re-rendering \(victims.count) queued item(s) in \(voice)")
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            for item in victims {
                let wav = queueDir.appendingPathComponent(".rerender-\(item.id).wav")
                let m4a = queueDir.appendingPathComponent(".rerender-\(item.id).m4a")
                defer { try? fm.removeItem(at: wav); try? fm.removeItem(at: m4a) }
                guard kokoroDaemonRender(text: item.text, voice: voice, out: wav),
                      convertWavToM4a(wav, out: m4a) else {
                    dlog("re-render failed for \(item.id) — keeping old audio")
                    continue
                }
                _ = try? fm.replaceItemAt(item.audioURL, withItemAt: m4a)
                dlog("re-rendered \(item.id) in \(voice)")
            }
        }
    }

    // Resume (or replay) the existing player for the current item — the shared
    // tail of "unpause" from toggleMute and togglePlay.
    private func resumeCurrent(_ p: AVAudioPlayer) {
        if let id = currentID { setState(id, .playing) }
        p.rate = Float(rate)
        p.play()
        isPlaying = true
        startMeter()
    }

    private func stopPlayer() {
        stopMeter()
        player?.stop()
        player = nil
        isPlaying = false
    }

    private func setState(_ id: String, _ s: SpeechItem.State) {
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].state = s }
        if s == .done {
            FileManager.default.createFile(atPath: queueDir.appendingPathComponent(id + ".done").path, contents: nil)
        }
    }
}

// MARK: - Now Playing / remote controls (AirPods stem clicks, media keys)
//
// Publishes the current reply to MPNowPlayingInfoCenter and handles
// MPRemoteCommandCenter commands, which is how headphone controls route on
// macOS: single stem click = play/pause, double = next reply, triple =
// previous reply. The deck only claims Now Playing while a reply is speaking,
// paused mid-reply, or more are queued — when idle it releases the claim
// (clears the info + .stopped) so the clicks go back to Music/Spotify/etc.
// skipForward/Backward stay disabled: if they're enabled, macOS prefers them
// over next/previousTrack and double/triple clicks turn into ±15s hops.
final class NowPlayingBridge {
    static let shared = NowPlayingBridge()
    private init() {}

    func setup() {
        let c = MPRemoteCommandCenter.shared()
        c.togglePlayPauseCommand.addTarget { _ in
            dlog("remote: toggle play/pause")
            Deck.shared.togglePlay()
            return .success
        }
        c.playCommand.addTarget { _ in
            if !Deck.shared.isPlaying { dlog("remote: play"); Deck.shared.togglePlay() }
            return .success
        }
        c.pauseCommand.addTarget { _ in
            if Deck.shared.isPlaying { dlog("remote: pause"); Deck.shared.togglePlay() }
            return .success
        }
        c.nextTrackCommand.addTarget { _ in
            dlog("remote: next reply")
            Deck.shared.playNext()
            return .success
        }
        c.previousTrackCommand.addTarget { _ in
            dlog("remote: previous reply")
            Deck.shared.backTrack()
            return .success
        }
        // Control Center's scrubber
        c.changePlaybackPositionCommand.addTarget { event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Deck.shared.seek(to: e.positionTime)
            return .success
        }
        c.skipForwardCommand.isEnabled = false
        c.skipBackwardCommand.isEnabled = false
        update()
    }

    // Discrete-state updates only (play/pause/seek/rate/track change) — the
    // system extrapolates elapsed time from elapsed + rate, so no per-tick calls.
    func update() {
        let d = Deck.shared
        let center = MPNowPlayingInfoCenter.default()
        // hasQueued keeps the claim alive across the 2s chime gap between
        // replies, so a stem click there doesn't fall through to Music
        guard let cur = d.current, d.isPlaying || d.isPausedMidItem || d.hasQueued else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: cur.title,
            MPMediaItemPropertyArtist: "Claude · SpeakySpeak",
            MPMediaItemPropertyPlaybackDuration: d.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: d.progress,
            MPNowPlayingInfoPropertyPlaybackRate: d.isPlaying ? d.rate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: d.rate,
        ]
        center.playbackState = d.isPlaying ? .playing : .paused
    }
}

// MARK: - Peer gate (two Macs, one pair of AirPods)
//
// When two machines both run SpeakySpeak and the user wears one pair of
// AirPods, macOS automatic switching yanks the AirPods to whichever Mac just
// started playing — simultaneous replies turn into a tug-of-war. The gate
// makes automatic starts polite: before AUTOplaying, a deck asks the peer
// deck (over Tailscale) whether it's speaking, and if so holds and re-polls
// until the peer goes quiet. Manual plays never wait — user intent wins.
//
// Wire-up: ~/.claude/speak-peer holds the peer Mac's IP (Tailscale IP; no
// file = no gating). Each deck also listens on TCP 48765 and answers any
// connection with "playing\n" or "idle\n", then hangs up. Every check FAILS
// OPEN — peer off, unreachable, or slow (>0.5s) counts as idle, so a solo or
// offline machine never silences its own deck.
final class PeerGate {
    static let shared = PeerGate()
    private let port: NWEndpoint.Port = 48765
    private let peerPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/speak-peer").path
    private var listener: NWListener?
    private init() {}

    // re-read per check so editing the dotfile needs no app restart
    private var peerHost: String? {
        guard let s = try? String(contentsOfFile: peerPath, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    func start() {
        guard let l = try? NWListener(using: .tcp, on: port) else {
            dlog("peer gate: listener failed to start"); return
        }
        // everything runs on main so reading Deck state is race-free; the
        // exchange is a handful of bytes, nothing here blocks
        l.newConnectionHandler = { conn in
            conn.start(queue: .main)
            let state = (Deck.shared.isPlaying ? "playing" : "idle") + "\n"
            conn.send(content: state.data(using: .utf8),
                      completion: .contentProcessed { _ in conn.cancel() })
        }
        l.start(queue: .main)
        dlog("peer gate: listening on \(port), peer \(peerHost ?? "none configured")")
    }

    // Is the peer deck speaking right now? Completion always fires, on main.
    func peerBusy(_ completion: @escaping (Bool) -> Void) {
        guard let host = peerHost else { completion(false); return }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        var finished = false   // main-queue only — connection + timeout both land there
        func finish(_ busy: Bool) {
            guard !finished else { return }
            finished = true
            conn.cancel()
            completion(busy)
        }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16) { data, _, _, _ in
            let s = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            finish(s.hasPrefix("playing"))
        }
        conn.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { finish(false) }
    }
}

// MARK: - Hover hints

struct HoverHint: ViewModifier {
    let text: String
    func body(content: Content) -> some View {
        content.onHover { inside in
            if inside { Deck.shared.hint = text }
            else if Deck.shared.hint == text { Deck.shared.hint = "" }
        }
    }
}

extension View {
    func hoverHint(_ text: String) -> some View { modifier(HoverHint(text: text)) }
}

// MARK: - SpeakySpeak mark (speech bubble, waveform bars cut out of the fill)

struct BubbleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var p = Path(roundedRect: CGRect(x: 0, y: 0, width: w, height: h * 0.80),
                     cornerRadius: h * 0.28)
        p.move(to: CGPoint(x: w * 0.20, y: h * 0.72))
        p.addLine(to: CGPoint(x: w * 0.14, y: h))
        p.addLine(to: CGPoint(x: w * 0.46, y: h * 0.78))
        p.closeSubpath()
        return p
    }
}

struct Spark: View {
    var size: CGFloat
    var color: Color = Theme.accent
    var pulse: Double = 0   // 0…1, the waveform bars dance with the voice
    private let base: [Double] = [0.20, 0.36, 0.26]
    private let gain: [Double] = [0.14, 0.20, 0.22]
    var body: some View {
        ZStack {
            BubbleShape().fill(color)
            HStack(spacing: size * 0.10) {
                ForEach(0..<3, id: \.self) { i in
                    Capsule()
                        .frame(width: size * 0.11,
                               height: size * (base[i] + gain[i] * pulse))
                }
            }
            .offset(y: -size * 0.10)
            .blendMode(.destinationOut)
        }
        .compositingGroup()
        .frame(width: size, height: size)
        .scaleEffect(1 + 0.12 * pulse)
    }
}

// MARK: - Speech-reactive swirl

struct SpeechSwirl: View {
    var level: Double
    var active: Bool
    var intensity: Double
    private static let hues: [Color] = [Color(hex: 0xD97757), Color(hex: 0xE2A171), Color(hex: 0xC97E66)]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !active)) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate
                ctx.addFilter(.blur(radius: 20))
                for i in 0..<Self.hues.count {
                    let fi = Double(i)
                    let phase = t * (0.10 + fi * 0.045) * 2 * .pi + fi * 2.094
                    // slow orbit + a faint tremble that rides the voice
                    let wobble = 1 + 0.07 * level * sin(t * 9 + fi * 1.7)
                    let cx = size.width * (0.5 + 0.36 * cos(phase))
                    let cy = size.height * (0.55 + 0.38 * sin(phase * 1.31 + fi))
                    let r = size.height * (0.45 + 0.30 * level) * (0.85 + 0.15 * sin(t * 0.6 + fi * 2)) * wobble
                    let op = intensity * (0.45 + 0.55 * level) + 0.10
                    let grad = Gradient(colors: [Self.hues[i].opacity(op), Self.hues[i].opacity(0)])
                    ctx.fill(
                        Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)),
                        with: .radialGradient(grad, center: CGPoint(x: cx, y: cy), startRadius: 0, endRadius: r))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Scrubber

// The panel sets isMovableByWindowBackground, and in a non-activating panel
// AppKit wins the drag — the window moves instead of the knob. A leaf AppKit
// view under a draggable control vetoes window movement so the SwiftUI
// gesture gets the events.
final class NoWindowDragNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
}
struct NoWindowDrag: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NoWindowDragNSView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct Scrubber: View {
    @ObservedObject var deck = Deck.shared
    let theme: Theme
    @State private var dragging = false
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let frac = deck.duration > 0 ? min(1, max(0, deck.progress / deck.duration)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(theme.track).frame(height: 4)
                Capsule()
                    .fill(LinearGradient(colors: [Theme.accent, Theme.accentDeep],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(4, w * frac), height: 4)
                Circle()
                    .fill(Theme.accent)
                    .frame(width: dragging || hovering ? 13 : 9, height: dragging || hovering ? 13 : 9)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .offset(x: w * frac - (dragging || hovering ? 6.5 : 4.5))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        dragging = true
                        deck.scrubbing = true
                        deck.progress = Double(min(max(0, v.location.x / w), 1)) * deck.duration
                    }
                    .onEnded { _ in
                        deck.seek(to: deck.progress)
                        deck.scrubbing = false
                        dragging = false
                    })
            .onHover { hovering = $0 }
        }
        .frame(height: 16)
        .background(NoWindowDrag())
        .animation(.easeOut(duration: 0.12), value: dragging || hovering)
    }
}

struct VolumeSlider: View {
    @ObservedObject var deck = Deck.shared
    let theme: Theme
    @State private var dragging = false
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let frac = min(1, max(0, deck.volume))
            ZStack(alignment: .leading) {
                Capsule().fill(theme.track).frame(height: 3)
                Capsule()
                    .fill(LinearGradient(colors: [Theme.accent, Theme.accentDeep],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(3, w * frac), height: 3)
                Circle()
                    .fill(Theme.accent)
                    .frame(width: dragging || hovering ? 11 : 7, height: dragging || hovering ? 11 : 7)
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                    .offset(x: w * frac - (dragging || hovering ? 5.5 : 3.5))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        dragging = true
                        deck.volume = Double(min(max(0, v.location.x / w), 1))
                        deck.hint = "Volume — \(Int((deck.volume * 100).rounded()))%"
                    }
                    .onEnded { _ in dragging = false })
            .onHover { hovering = $0 }
        }
        .frame(width: 52, height: 16)
        .background(NoWindowDrag())
        .help("Volume")
        .accessibilityLabel("Volume")
        .hoverHint("Volume — drag to adjust")
        .animation(.easeOut(duration: 0.12), value: dragging || hovering)
    }
}

// MARK: - Main view

func fmtTime(_ s: Double) -> String {
    guard s.isFinite, s >= 0 else { return "0:00" }
    let t = Int(s.rounded())
    return String(format: "%d:%02d", t / 60, t % 60)
}

func fmtRate(_ r: Double) -> String {
    r == 1.0 ? "1×" : String(format: "%g×", r)
}

struct DeckView: View {
    @ObservedObject var deck = Deck.shared
    @ObservedObject private var updater = Updater.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Theme.of(scheme)
        VStack(spacing: 10) {
            header(theme)
            nowPlaying(theme)
            if !deck.items.isEmpty {
                list(theme)
            }
            footer(theme)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .padding(.top, 13)
        .frame(minWidth: 340, idealWidth: 360, maxWidth: 500)
        .background(theme.bg.ignoresSafeArea())
        .contextMenu { Button("Quit SpeakySpeak") { NSApp.terminate(nil) } }
        .animation(.spring(duration: 0.35), value: deck.items)
        .animation(.easeOut(duration: 0.25), value: deck.currentID)
    }

    private func header(_ theme: Theme) -> some View {
        HStack(spacing: 9) {
            Spark(size: 15, pulse: deck.isPlaying ? deck.level : 0)
            Text("SpeakySpeak")
                .font(.system(size: 15, weight: .semibold, design: .serif))
                .foregroundStyle(theme.text)
            Spacer()
            Button(action: { deck.toggleMute() }) {
                Image(systemName: deck.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(deck.muted ? Theme.accent : theme.secondary)
                    .frame(width: 24, height: 20)
            }
            .buttonStyle(.plain)
            .help(deck.muted ? "Muted — new replies queue silently. Click to resume." : "Mute — pauses speech, new replies queue silently")
            .accessibilityLabel(deck.muted ? "Unmute" : "Mute")
            .hoverHint(deck.muted ? "Unmute" : "Mute — replies still queue")
            VolumeSlider(theme: theme)
            Button(action: { deck.cycleRate() }) {
                Text(fmtRate(deck.rate))
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(deck.rate == 1.0 ? theme.secondary : Theme.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(theme.track))
            }
            .buttonStyle(.plain)
            .help("Playback speed — click to cycle")
            .accessibilityLabel("Playback speed")
            .hoverHint("Speed — click to cycle")
        }
    }

    private func footer(_ theme: Theme) -> some View {
        let hasDone = deck.items.contains { $0.state == .done }
        return HStack(spacing: 12) {
            // Update cue lives bottom-left (Adam's expected spot). It sits
            // BEFORE the hint text so hovering other controls never hides it —
            // and it must not use hoverHint itself (hint + conditional slot
            // would flicker). Plain .help tooltip only.
            //
            // It opens Settings rather than updating on the spot: since
            // 2026-08-17 the update button lives in Settings ▸ About & support,
            // so there is exactly one place that starts an update. Sitting
            // inside the existing footer row also means no vertical layout
            // shift when an update appears or goes away.
            if let v = updater.availableVersion {
                let busy: Bool = {
                    switch updater.phase {
                    case .running, .relaunching: return true
                    default: return false
                    }
                }()
                Button(action: { SettingsWindowController.shared.show() }) {
                    Label(busy ? "Updating…" : "Update \(v) available",
                          systemImage: "arrow.up.circle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .help(busy ? "Update in progress. Progress is in Settings."
                           : "Update \(v) is available. Click to open Settings and install it.")
                .accessibilityLabel(busy ? "Update in progress" : "Update \(v) available, open Settings")
            }
            Text(deck.hint)
                .font(.system(size: 10, design: .serif).italic())
                .foregroundStyle(theme.secondary)
                .lineLimit(1)
            Spacer()
            Button(action: { SettingsWindowController.shared.show() }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.secondary)
                    .frame(width: 24, height: 20)
            }
            .buttonStyle(.plain)
            .help("Settings — engine, voice, playback")
            .accessibilityLabel("Settings")
            .hoverHint("Settings")
            Button(action: { deck.clearDone() }) {
                Image(systemName: "wind")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.secondary)
                    .frame(width: 24, height: 20)
            }
            .buttonStyle(.plain)
            .help("Clear played — sweep away all played replies")
            .accessibilityLabel("Clear played")
            .hoverHint("Clear played")
            .disabled(!hasDone)
            .opacity(hasDone ? 1 : 0.35)
            Button(action: { deck.clearAll() }) {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.secondary)
                    .frame(width: 24, height: 20)
            }
            .buttonStyle(.plain)
            .help("Delete all — remove every reply, played and queued")
            .accessibilityLabel("Delete all")
            .hoverHint("Delete all — played and queued")
            .disabled(deck.items.isEmpty)
            .opacity(deck.items.isEmpty ? 0.35 : 1)
        }
        .frame(height: 18)
    }

    @ViewBuilder private func nowPlaying(_ theme: Theme) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.card)
            SpeechSwirl(level: deck.level, active: deck.isPlaying, intensity: theme.swirlIntensity)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(theme.cardStroke)

            if let cur = deck.current {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(cur.title)
                            .font(.system(size: 14, weight: .semibold, design: .serif))
                            .foregroundStyle(theme.text)
                            .lineLimit(1)
                        Text(cur.created, style: .time)
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(theme.secondary)
                        Spacer()
                    }
                    Text(cur.preview)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Scrubber(theme: theme)
                    HStack(spacing: 16) {
                        Text(fmtTime(deck.progress))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(theme.secondary)
                        Spacer()
                        transportButton("gobackward.10", theme) { deck.skip(-10) }
                            .help("Back 10 seconds")
                            .accessibilityLabel("Back 10 seconds")
                            .hoverHint("Back 10 seconds")
                        playButton
                        transportButton("goforward.10", theme) { deck.skip(10) }
                            .help("Forward 10 seconds")
                            .accessibilityLabel("Forward 10 seconds")
                            .hoverHint("Forward 10 seconds")
                        transportButton("forward.end.fill", theme) { deck.playNext() }
                            .help(deck.hasQueued ? "Skip to the next reply" : "Skip — stop this reply")
                            .accessibilityLabel(deck.hasQueued ? "Play next" : "Skip")
                            .hoverHint(deck.hasQueued ? "Skip to the next reply" : "Skip — stop this reply")
                            .disabled(!deck.isPlaying && !deck.hasQueued)
                            .opacity(!deck.isPlaying && !deck.hasQueued ? 0.35 : 1)
                        Spacer()
                        Text(fmtTime(deck.duration))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(theme.secondary)
                    }
                }
                .padding(12)
            } else {
                VStack(spacing: 8) {
                    Spark(size: 26, color: deck.enabled ? Theme.accent.opacity(0.55) : theme.secondary.opacity(0.5))
                    Text(!deck.enabled ? "Speech is off — new replies won't be spoken"
                         : deck.items.isEmpty ? "Waiting for replies…" : "Click a reply to play it")
                        .font(.system(size: 11, design: .serif).italic())
                        .foregroundStyle(theme.secondary)
                }
                .padding(.vertical, 22)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var playButton: some View {
        Button(action: { deck.togglePlay() }) {
            ZStack {
                Circle().fill(LinearGradient(colors: [Theme.accent, Theme.accentDeep],
                                             startPoint: .top, endPoint: .bottom))
                Image(systemName: deck.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .offset(x: deck.isPlaying ? 0 : 1)
            }
            .frame(width: 34, height: 34)
            .scaleEffect(1 + 0.06 * deck.level)
            .shadow(color: Theme.accent.opacity(0.35), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
        .help(deck.isPlaying ? "Pause" : "Play")
        .accessibilityLabel(deck.isPlaying ? "Pause" : "Play")
        .hoverHint(deck.isPlaying ? "Pause" : "Play")
    }

    private func transportButton(_ symbol: String, _ theme: Theme, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.text.opacity(0.75))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func list(_ theme: Theme) -> some View {
        // Up Next in true play order (top = next); Played grayed below, newest first
        let queued = deck.items.filter { $0.state == .queued }
        let played = deck.items.filter { $0.state == .done }.sorted { $0.created > $1.created }
        return ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if !queued.isEmpty {
                    sectionHeader("Up Next", count: queued.count, theme)
                    ForEach(Array(queued.enumerated()), id: \.element.id) { i, item in
                        DeckRow(item: item, isCurrent: false,
                                queuePos: i + 1, queueCount: queued.count, theme: theme)
                    }
                }
                if !played.isEmpty {
                    sectionHeader("Played", count: played.count, theme)
                        .padding(.top, queued.isEmpty ? 0 : 8)
                    ForEach(played) { item in
                        DeckRow(item: item, isCurrent: item.id == deck.currentID,
                                queuePos: nil, queueCount: 0, theme: theme)
                    }
                }
            }
            .padding(.top, 2)
        }
        .frame(minHeight: 80, maxHeight: 280)
    }

    private func sectionHeader(_ title: String, count: Int, _ theme: Theme) -> some View {
        Text("\(title.uppercased()) · \(count)")
            .font(.system(size: 9, weight: .bold))
            .kerning(0.8)
            .foregroundStyle(theme.secondary)
            .padding(.horizontal, 7)
            .padding(.bottom, 1)
    }
}

struct DeckRow: View {
    @ObservedObject var deck = Deck.shared
    let item: SpeechItem
    let isCurrent: Bool
    let queuePos: Int?
    let queueCount: Int
    let theme: Theme
    @State private var hover = false

    var body: some View {
        HStack(spacing: 2) {
            // the row itself is inert — status reads on the left, actions
            // (play / remove / reorder) live on the right
            HStack(spacing: 8) {
                statusIcon.frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(item.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.text)
                        Text(item.created, style: .time)
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(theme.secondary)
                    }
                    Text(item.preview)
                        .font(.system(size: 10))
                        .foregroundStyle(theme.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
            }
            .padding(.vertical, 4)
            .padding(.leading, 7)

            if hover {
                Button(action: { deck.play(item) }) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .help("Play now")
                .hoverHint("Play now")
                Button(action: { deck.remove(item) }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove")
                .hoverHint("Remove")
            }
            if item.state == .queued {
                Button(action: { deck.moveQueued(item, by: -1) }) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(queuePos == 1 ? theme.secondary.opacity(0.3) : theme.secondary)
                        .frame(width: 15, height: 15)
                }
                .buttonStyle(.plain)
                .disabled(queuePos == 1)
                .help("Play earlier")
                .hoverHint("Play earlier")
                Button(action: { deck.moveQueued(item, by: 1) }) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(queuePos == queueCount ? theme.secondary.opacity(0.3) : theme.secondary)
                        .frame(width: 15, height: 15)
                }
                .buttonStyle(.plain)
                .disabled(queuePos == queueCount)
                .help("Play later")
                .hoverHint("Play later")
            }
        }
        .padding(.trailing, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isCurrent ? Theme.accent.opacity(0.13) : hover ? theme.hover : .clear))
        .onHover { inside in
            hover = inside
            // the hover buttons vanish with the row highlight, so their
            // hint can be left stranded — clear it on the way out
            if !inside, ["Play now", "Remove", "Play earlier", "Play later"].contains(deck.hint) {
                deck.hint = ""
            }
        }
        .opacity(item.state == .done && !isCurrent ? 0.42 : 1)
    }

    @ViewBuilder private var statusIcon: some View {
        switch item.state {
        case .playing:
            Spark(size: 12, pulse: deck.level)
        case .queued:
            Circle()
                .fill(queuePos == 1 ? Theme.accent : Theme.accent.opacity(0.45))
                .frame(width: 7, height: 7)
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(theme.secondary)
        }
    }
}

// MARK: - Shimmer glow (a bright white flash on every track change / skip)
//
// The HUD can be dragged anywhere, so when a reply starts — or you skip/back —
// it flashes bright glowing white: a hot white rim + white bloom that pops
// immediately and settles through a couple of soft pulses (~1.4s). A "here I
// am!" the eye can't miss. Driven by a TimelineView off a start Date; startedAt
// == nil pauses it (and renders clear).
struct ShimmerGlow: View {
    var startedAt: Date?
    var corner: CGFloat = 15
    private let duration = 1.4

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: startedAt == nil)) { tl in
            let e = envelope(at: tl.date)
            let flash = e.flash   // bright immediate pop, quick fade
            let glow = e.glow     // softer pulses trailing it
            let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
            ZStack {
                // a brief bright white wash lighting the whole panel
                shape.fill(Color.white.opacity(0.30 * flash))
                // hot white rim + big white bloom — the flash
                shape.strokeBorder(Color.white.opacity(0.98 * flash), lineWidth: 2 + 3 * flash)
                    .shadow(color: Color.white.opacity(0.95 * flash), radius: 7 + 16 * flash)
                    .shadow(color: Color.white.opacity(0.65 * flash), radius: 26 * flash)
                // trailing white pulses that settle it out
                shape.strokeBorder(Color.white.opacity(0.7 * glow), lineWidth: 1 + 2 * glow)
                    .shadow(color: Color.white.opacity(0.7 * glow), radius: 12 * glow)
            }
            .opacity(max(flash, glow))
        }
        .allowsHitTesting(false)
    }

    // flash: immediate bright pop that decays fast. glow: two soft pulses that
    // trail behind and fade out. Both live inside [0, duration].
    private func envelope(at now: Date) -> (flash: Double, glow: Double) {
        guard let start = startedAt else { return (0, 0) }
        let p = now.timeIntervalSince(start) / duration
        guard p >= 0, p < 1 else { return (0, 0) }
        let flash = pow(1 - p, 1.8)                 // 1 → 0, front-loaded, lingers a touch
        let glow = abs(sin(p * .pi * 2)) * (1 - p)  // 0→1→0→1→0, decaying
        return (flash, glow)
    }
}

// MARK: - Updater (public-mirror release channel)
//
// Same model as MarkeMark: a version file the app polls, an "Update to X"
// menu item when it's newer. Here the channel is the public GitHub mirror
// (radam5000/speakyspeak): raw VERSION on main is the truth, the local
// version is a VERSION file build.sh copies into Resources, and updating =
// `git pull --ff-only && ./install.sh` in the clone install.sh recorded via
// the srcPath default. No clone recorded (or gone) → open the repo page
// instead of failing silently.
final class Updater: ObservableObject {
    static let shared = Updater()
    @Published private(set) var availableVersion: String?
    // Set when this launch is the first run of a new version (the previous
    // run's version is remembered in UserDefaults). Drives the menu's
    // "just updated ✓" line — the update itself is otherwise invisible.
    private(set) var justUpdatedFrom: String?

    static let repoPage = "https://github.com/radam5000/speakyspeak"
    private let versionURL = URL(string: "https://raw.githubusercontent.com/radam5000/speakyspeak/main/VERSION")!

    var localVersion: String {
        guard let u = Bundle.main.url(forResource: "VERSION", withExtension: nil),
              let s = try? String(contentsOf: u, encoding: .utf8) else { return "0" }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func start() {
        let d = UserDefaults.standard
        if let prev = d.string(forKey: "lastRunVersion"), prev != localVersion {
            justUpdatedFrom = prev
            // Explicit post-update confirmation: without this, the first
            // Settings visit after a relaunch showed only the idle "Checked
            // automatically once a day" caption and the update read as
            // unconfirmed (Adam, 2026-08-18). The silent startup check below
            // leaves checkResult alone unless it finds something newer.
            checkResult = "Updated from \(prev) ✓ You're on the latest version."
            // Spoken confirmation, once, on the first launch after an update —
            // the app's own voice IS the "it worked" signal (and proof the
            // pipeline survived the update). Never on normal launches; silent
            // when speech is off, muted, or something is already playing
            // (Settings keeps the visual record either way). Delayed a beat so
            // launch work settles and the deck's state is real.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [self] in
                let deck = Deck.shared
                guard deck.enabled, !deck.muted, !deck.isPlaying,
                      VoicePreviewer.shared.state == .idle else { return }
                let spoken = localVersion.replacingOccurrences(of: ".", with: " point ")
                VoicePreviewer.shared.announce("SpeakySpeak updated to \(spoken).")
            }
        }
        d.set(localVersion, forKey: "lastRunVersion")
        check()
        Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in self?.check() }
    }

    // Manual checks (the Settings button) also report "up to date" / failure;
    // the silent daily check leaves checkResult alone unless it finds one.
    @Published private(set) var checking = false
    @Published private(set) var checkResult: String?

    func checkNow() {
        guard !checking else { return }
        checking = true
        checkResult = nil
        check(manual: true)
    }

    // API first: raw.githubusercontent.com sits behind a ~5-minute CDN cache,
    // which told a user "You're on the latest version" one minute after a
    // release shipped (2026-08-18). The contents API is uncached; the
    // unauthenticated rate limit (60/hour/IP) is ample for a daily poll plus
    // manual clicks. The raw URL stays as the fallback for rate-limit or API
    // outage — a slightly stale answer beats no answer.
    private let apiVersionURL = URL(string: "https://api.github.com/repos/radam5000/speakyspeak/contents/VERSION?ref=main")!

    private func check(manual: Bool = false) {
        var req = URLRequest(url: apiVersionURL)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("application/vnd.github.raw", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            guard let self else { return }
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            let remote = ok ? data.flatMap { String(data: $0, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines) : nil
            if let remote, !remote.isEmpty, remote.count < 32 {
                self.applyCheck(remote: remote, manual: manual)
            } else {
                self.checkRawFallback(manual: manual)
            }
        }.resume()
    }

    private func checkRawFallback(manual: Bool) {
        var req = URLRequest(url: versionURL)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self else { return }
            let remote = data.flatMap { String(data: $0, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let remote, !remote.isEmpty, remote.count < 32 {
                self.applyCheck(remote: remote, manual: manual)
            } else {
                DispatchQueue.main.async {
                    self.checking = false
                    if manual { self.checkResult = "Couldn't reach the update server." }
                }
            }
        }.resume()
    }

    private func applyCheck(remote: String, manual: Bool) {
        DispatchQueue.main.async {
            self.checking = false
            self.availableVersion = Self.newer(remote, than: self.localVersion) ? remote : nil
            if self.availableVersion != nil {
                dlog("update available: \(remote) (local \(self.localVersion))")
            } else if manual {
                self.checkResult = "You're on the latest version."
            }
        }
    }

    private static func newer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // Update progress, surfaced in Settings. Rewritten 2026-08-18 after a
    // real field failure: the old one-shot chain ended in
    // `... && pkill -x SpeakySpeak; open -g ...`, and on the 1.0.8->1.0.9
    // update the pkill silently did nothing from the app-spawned shell (the
    // same command worked instantly from a terminal; cause never isolated).
    // install.sh had already succeeded, so the user saw a working button,
    // no feedback, and no relaunch — the worst combination. The redesign
    // removes the external kill entirely: the child script only pulls,
    // builds, and writes a marker; the APP notices the marker, shows state,
    // and terminates itself while a waiter process relaunches it.
    enum UpdatePhase {
        case idle
        case running
        case relaunching
        case failed(String)
    }
    @Published var phase: UpdatePhase = .idle

    private static let installedMarker = "/tmp/claude-speech/.update-installed"
    private static let failedMarker = "/tmp/claude-speech/.update-failed"

    func performUpdate() {
        if case .running = phase { return }
        if case .relaunching = phase { return }
        let src = UserDefaults.standard.string(forKey: "srcPath") ?? ""
        guard !src.isEmpty, FileManager.default.isExecutableFile(atPath: src + "/install.sh") else {
            NSWorkspace.shared.open(URL(string: Self.repoPage)!)
            return
        }
        dlog("updating from \(src)")
        phase = .running

        // Every step's output lands in update.log — the old chain logged only
        // install.sh, which made its one field failure undiagnosable from logs.
        let script = """
        LOG=/tmp/claude-speech/update.log
        mkdir -p /tmp/claude-speech
        rm -f \(Self.installedMarker) \(Self.failedMarker)
        {
          echo "=== update started $(date) ==="
          cd \"\(src)\" && git pull --ff-only && ./install.sh
        } >> "$LOG" 2>&1
        rc=$?
        if [ $rc -eq 0 ]; then
          echo "=== update install ok $(date) ===" >> "$LOG"
          touch \(Self.installedMarker)
        else
          echo "=== update FAILED rc=$rc $(date) ===" >> "$LOG"
          echo "a step failed (rc=$rc); log: /tmp/claude-speech/update.log" > \(Self.failedMarker)
        fi
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", script]
        do { try p.run() } catch {
            phase = .failed("could not start the updater: \(error.localizedDescription)")
            return
        }

        let deadline = Date().addingTimeInterval(300)
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let fm = FileManager.default
            if fm.fileExists(atPath: Self.installedMarker) {
                t.invalidate()
                dlog("update installed; relaunching")
                self.phase = .relaunching
                self.relaunch()
            } else if let msg = try? String(contentsOfFile: Self.failedMarker, encoding: .utf8) {
                t.invalidate()
                let reason = msg.trimmingCharacters(in: .whitespacesAndNewlines)
                dlog("update failed: \(reason)")
                self.phase = .failed(reason)
            } else if Date() > deadline {
                t.invalidate()
                dlog("update timed out")
                self.phase = .failed("timed out after 5 minutes; log: /tmp/claude-speech/update.log")
            }
        }
    }

    // Quit ourselves and let a detached waiter reopen the new bundle. The
    // waiter keys off our pid actually exiting, so there is no kill race and
    // no reliance on signalling a GUI app from a child shell.
    private func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c",
            "while /bin/kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; " +
            "open -g \"$HOME/Applications/SpeakySpeak.app\""]
        try? p.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
    }
}

// MARK: - Feedback
//
// Two ways to report a problem, both reachable from Settings ▸ About & support
// (they used to live in the status-item menu; that menu got too tall to fit on
// short screens, 2026-08-17). openMailReport() is the one-click path; the
// clipboard prompt is for people who'd rather have their own Claude Code
// gather the logs and write the mail for them.
enum Feedback {
    static let address = "hi@speakyspeak.com"

    // Opens the user's mail client addressed to hi@speakyspeak.com with the
    // diagnostic context pre-filled (version, macOS, resolved engine, hook.log
    // tail), so a report arrives debuggable without a follow-up round trip.
    // The reporter never has to know the address or what to include.
    static func openMailReport() {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var engine = SettingsStore.shared.engine.rawValue
        if engine.isEmpty {   // .auto — resolve the same way the hook does
            let kokoro = NSHomeDirectory() + "/.local/bin/mlx_audio.tts.generate"
            engine = FileManager.default.isExecutableFile(atPath: kokoro) ? "kokoro" : "say"
        }
        var logTail = ""
        if let log = try? String(contentsOfFile: "/tmp/claude-speech/hook.log", encoding: .utf8) {
            logTail = log.split(separator: "\n").suffix(6).joined(separator: "\n")
        }
        let body = """


        ---
        SpeakySpeak \(Updater.shared.localVersion) · macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) · engine: \(engine)
        hook.log tail:
        \(logTail)
        """
        var comps = URLComponents()
        comps.scheme = "mailto"
        comps.path = address
        comps.queryItems = [URLQueryItem(name: "subject", value: "SpeakySpeak feedback"),
                            URLQueryItem(name: "body", value: body)]
        if let url = comps.url { NSWorkspace.shared.open(url) }
    }

    // Pasted into the user's own Claude Code session. The VERSION path is the
    // one build.sh installs (Contents/Resources/VERSION) — keep them in step.
    static let claudePrompt = """
    SpeakySpeak, the macOS menu-bar app that reads Claude Code replies aloud, is misbehaving and I want to send a bug report.

    1. Read the last 40 lines of /tmp/claude-speech/hook.log.
    2. Read ~/Library/Logs/speakyspeak-tts.err.log if it exists.
    3. Read the installed version in ~/Applications/SpeakySpeak.app/Contents/Resources/VERSION.
    4. Ask me to describe the problem in a sentence or two, then write a short plain report: my description, the version, my macOS version, and the log lines that look relevant.
    5. Open a pre-filled draft with: open "mailto:hi@speakyspeak.com?subject=SpeakySpeak%20report&body=<the url-encoded report>"

    Do not send anything yourself. I will read the draft and send it.
    """

    static func copyClaudePrompt() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(claudePrompt, forType: .string)
    }
}

// MARK: - Rainbow ripple (audio is waiting behind a paused reply)
//
// Adam's design (2026-08-16, after a 3-pulse white flash proved too easy to
// miss): while a queued reply is held because the current one is paused, the
// HUD washes rainbow, continuously, until any interaction — a hover counts —
// or until playback resumes. Persistent beats bright: you can't walk past it.
//
// Revised 2026-08-16 (aurora pass): six drifting blobs over a turning conic
// ground. Revised again 2026-08-16 after a live screenshot — three faults, all
// fixed here:
//   1. flat salmon tint. The conic ground plus solid single-hue blobs meant a
//      frozen frame showed whatever hues had drifted together. Now the ground
//      is a LINEAR spectrum tiling a full 12-hue wheel across ~1.15 card
//      widths, so every instant shows the whole rainbow across the card. This
//      is guaranteed geometrically, not statistically.
//   2. ugly orange rim. The angular rainbow rim is gone. The outline is white:
//      a crisp hairline plus a soft double white bloom, breathing.
//   3. vertical line artifact on the left. That was the conic gradient's seam,
//      where its first and last stop met at 180°. No conic remains, so there
//      is no seam to hide.
// The blobs survive, as rainbow patches rather than colour blobs: each fills
// with the same spectrum at its own phase / angle / wavelength, masked by a
// radial falloff (.destinationIn inside a nested layer), so they displace hue
// locally for swirl without ever being one colour and without a hard edge.
//
// Motion is derived ENTIRELY from tl.date.timeIntervalSinceReferenceDate with
// fixed per-blob constants: no per-frame randomness, deterministic, and the
// incommensurate frequencies mean the composite takes many minutes to repeat.
//
// Two clocks, deliberately separate:
//   • motion  — absolute time, so it never opens on the same frame twice
//   • opacity — a fade envelope off `onAt`/`offAt` (2.0s in, 0.5s out)
// `running` (not `active`) gates the TimelineView: it stays true through the
// fade-out and only then flips false, at which point nothing is drawn and the
// timeline is paused — zero CPU while idle.
struct RainbowRipple: View {
    var active: Bool
    var corner: CGFloat = 15
    @Environment(\.colorScheme) private var scheme

    @State private var onAt: Date?      // activation — fade-in origin
    @State private var offAt: Date?     // dismissal — fade-out origin
    @State private var running = false  // the only thing that unpauses the timeline
    @State private var stopToken = 0    // cancels a pending stop if we re-activate

    private let fadeIn = 2.0
    private let fadeOut = 0.5

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !running)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let env = envelope(at: tl.date)
            let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
            ZStack {
                if env > 0.002 {
                    // a barely-there breath on top of the envelope so a
                    // long-held ripple never sits perfectly still
                    let breath = 0.90 + 0.10 * sin(t * 1.1)
                    aurora(t: t)
                        .clipShape(shape)
                        .opacity(washOpacity * env * breath)

                    // Outline: white only. A crisp hairline for definition over
                    // any desktop, then the same edge again wider and dimmer
                    // with two stacked white shadows — tight halo plus wide
                    // bloom into the panel's transparent margin. The glow
                    // breathes on a slower sine than the wash, so the border
                    // and the interior never pulse in lockstep.
                    let glow = 0.80 + 0.20 * sin(t * 1.3)
                    shape.strokeBorder(Color.white.opacity(0.92 * env), lineWidth: 1.2)
                    shape.strokeBorder(Color.white.opacity(0.45 * env * glow), lineWidth: 2.4)
                        .shadow(color: Color.white.opacity(0.42 * env * glow), radius: 4)
                        .shadow(color: Color.white.opacity(0.26 * env * glow), radius: 11)
                }
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            // the HUD can be built with attention already wanted
            if active { onAt = Date(); offAt = nil; running = true }
        }
        .onChange(of: active) { _, now in
            stopToken &+= 1
            if now {
                // Re-activation, possibly mid-fade-out: instead of snapping
                // back to full (the "jerk at the very end" Adam saw), back-date
                // the rise so the envelope CONTINUES from its current value —
                // the end fades into the beginning.
                let cur = envelope(at: Date())
                offAt = nil
                onAt = Date().addingTimeInterval(-unsmooth(cur) * fadeIn)
                running = true
            } else if running {
                let token = stopToken
                offAt = Date()
                DispatchQueue.main.asyncAfter(deadline: .now() + fadeOut + 0.05) {
                    guard stopToken == token else { return }   // re-activated
                    running = false; onAt = nil; offAt = nil
                }
            }
        }
    }

    // MARK: fade envelope

    // 0 → 1 over fadeIn, then 1 → 0 over fadeOut once dismissed. The rise is
    // frozen at the dismissal instant so a ripple killed early fades from
    // wherever it got to, instead of still climbing while it leaves.
    private func envelope(at now: Date) -> Double {
        guard running, let on = onAt else { return 0 }
        let cut = min(now, offAt ?? now)
        let rise = smooth(cut.timeIntervalSince(on) / fadeIn)
        guard let off = offAt else { return rise }
        return rise * (1 - smooth(now.timeIntervalSince(off) / fadeOut))
    }

    private func smooth(_ x: Double) -> Double {
        let c = min(max(x, 0), 1)
        return c * c * (3 - 2 * c)   // smoothstep — no hard corners at either end
    }

    // inverse of smooth(): what rise-progress produces this envelope value —
    // used to restart a fade-in from mid-air without a brightness jump
    private func unsmooth(_ e: Double) -> Double {
        var lo = 0.0, hi = 1.0
        for _ in 0..<24 {
            let m = (lo + hi) / 2
            if smooth(m) < e { lo = m } else { hi = m }
        }
        return (lo + hi) / 2
    }

    // MARK: palette (light needs more saturation and less brightness — a pale
    // card washes out long before a dark one does)

    private var sat: Double { scheme == .dark ? 0.88 : 0.95 }
    private var bright: Double { scheme == .dark ? 1.00 : 0.82 }
    private var washOpacity: Double { scheme == .dark ? 0.62 : 0.55 }

    // 12 steps, not 6: SwiftUI interpolates gradients in RGB, and a 6-step
    // wheel interpolated that way muddies the cyan/magenta halves. 12 keeps
    // every band recognisably its own colour.
    private static let steps = 12
    private var spectrum: [Color] {
        (0..<Self.steps).map {
            Color(hue: Double($0) / Double(Self.steps), saturation: sat, brightness: bright)
        }
    }

    // MARK: the spectrum shading
    //
    // A linear gradient along `angle`, carrying `cycles` complete hue wheels
    // across the box's extent along that axis — cycles ≈ 1 means the whole
    // rainbow is visible across the card AT EVERY INSTANT, which is the whole
    // point of this rewrite. Extra wheels are tiled past both ends so the
    // gradient never runs out and clamps to a flat end colour.
    //
    // `phase` slides the whole thing along the axis by exactly one wheel per
    // unit, so it loops seamlessly: there is no start/end meeting point on
    // screen at any time. (That meeting point, in the old conic ground, was
    // the vertical line on the left.)
    private func spectrumShading(size: CGSize, phase: Double,
                                 angle: Double, cycles: Double) -> GraphicsContext.Shading {
        let w = size.width, h = size.height
        let dx = cos(angle), dy = sin(angle)
        let extent = abs(dx) * w + abs(dy) * h        // box extent along the axis
        let wheelLen = max(extent / max(cycles, 0.05), 1)
        let reps = Int(cycles.rounded(.up)) + 3       // margin at both ends
        let total = wheelLen * Double(reps)
        let shift = (phase - phase.rounded(.down)) * wheelLen
        let cx = w / 2, cy = h / 2
        let start = CGPoint(x: cx - dx * (total / 2 + shift),
                            y: cy - dy * (total / 2 + shift))
        let end = CGPoint(x: start.x + dx * total, y: start.y + dy * total)
        var colors: [Color] = []
        colors.reserveCapacity(reps * Self.steps + 1)
        let wheel = spectrum
        for _ in 0..<reps { colors.append(contentsOf: wheel) }
        colors.append(wheel[0])                       // close the last wheel
        return .linearGradient(Gradient(colors: colors), startPoint: start, endPoint: end)
    }

    // MARK: the aurora

    private func aurora(t: Double) -> some View {
        // plusLighter glows on a dark card; on a light one it clips to white
        // almost immediately, so light mode screens instead
        let blend: GraphicsContext.BlendMode = scheme == .dark ? .plusLighter : .screen
        return Canvas(opaque: false, rendersAsynchronously: false) { ctx, size in
            let w = size.width, h = size.height
            let base = min(w, h)
            let full = Path(CGRect(origin: .zero, size: size))

            // GROUND — the guaranteed rainbow. Slides left-to-right at roughly
            // one card width every 12s (brisk enough to read as alive without
            // strobing), on an axis that rocks a few degrees either side of
            // horizontal so the bands lean and sway rather than marching.
            ctx.opacity = 0.80
            ctx.fill(full, with: spectrumShading(size: size,
                                                 phase: t * 0.085,
                                                 angle: 0.30 * sin(t * 0.13),
                                                 cycles: 1.15))
            ctx.opacity = 1

            // BLOBS — organic swirl. Each is the same spectrum at its own
            // phase offset, angle and wavelength, so it displaces hue locally
            // instead of tinting; masked by a radial falloff so it has no edge.
            for blob in Self.blobs {
                let cx = w * (0.5 + blob.ax * sin(t * blob.fx * Self.speed + blob.px))
                let cy = h * (0.5 + blob.ay * cos(t * blob.fy * Self.speed + blob.py))
                let r = base * blob.r * (1 + 0.20 * sin(t * blob.fr * Self.speed + blob.pr))

                ctx.drawLayer { layer in
                    layer.blendMode = blend
                    layer.opacity = blob.alpha
                    layer.addFilter(.blur(radius: base * 0.06))
                    // scale the context rather than the rect, so the radial
                    // falloff stretches with the ellipse instead of leaving
                    // transparent caps on the long axis
                    layer.translateBy(x: cx, y: cy)
                    layer.scaleBy(x: blob.aspect, y: 1)
                    layer.translateBy(x: -cx / blob.aspect, y: -cy)

                    let rect = CGRect(x: cx / blob.aspect - r, y: cy - r,
                                      width: r * 2, height: r * 2)
                    layer.drawLayer { patch in
                        // the patch's own rainbow: offset by at most ±0.16 of a
                        // wheel from the ground, so where it lands additively
                        // it lands on a NEIGHBOURING hue. Bigger offsets sum to
                        // complementaries, which is exactly how an additive
                        // rainbow turns into grey.
                        let ph = t * 0.085 + blob.hueOffset + 0.05 * sin(t * blob.fh + blob.ph)
                        let ang = blob.angle + 0.45 * sin(t * blob.fa + blob.pa)
                        patch.fill(Path(rect.insetBy(dx: -r, dy: -r)),
                                   with: spectrumShading(size: size, phase: ph,
                                                         angle: ang, cycles: blob.cycles))
                        patch.blendMode = .destinationIn
                        patch.fill(Path(ellipseIn: rect),
                                   with: .radialGradient(
                                       Gradient(stops: [
                                           .init(color: .white, location: 0),
                                           .init(color: Color.white.opacity(0.80), location: 0.38),
                                           .init(color: Color.white.opacity(0.34), location: 0.68),
                                           .init(color: Color.white.opacity(0), location: 1)]),
                                       center: CGPoint(x: rect.midX, y: rect.midY),
                                       startRadius: 0, endRadius: max(r, 1)))
                    }
                }
            }
        }
        // a slow global hue drift on top of everything — a rotation preserves
        // full-spectrum coverage (it just relabels which band is where), so the
        // cast keeps changing without any frame losing hues. Two incommensurate
        // rates mean it never settles into a loop.
        .hueRotation(.degrees(t * 9 + sin(t * 0.037) * 34))
    }

    // MARK: blob constants (fixed — this is the whole "randomness")

    private static let speed = 1.1   // radians/sec base — brisk enough that the swirl visibly never stops

    private struct Blob {
        let hueOffset, ax, ay, fx, fy, px, py, r, fr, pr: Double
        let aspect, alpha, cycles, angle, fh, ph, fa, pa: Double
    }

    // Frequencies are drawn from an incommensurate set (1, 0.61803, 0.35867,
    // 0.24219, 0.78615, 0.47128) and paired differently per axis per blob, so
    // no two blobs share a period and the composite doesn't visibly cycle.
    // hueOffset stays inside ±0.16 of a wheel — see the note in aurora().
    private static let blobs: [Blob] = [
        Blob(hueOffset:  0.14, ax: 0.34, ay: 0.30, fx: 1.00000, fy: 0.61803,
             px: 0.00, py: 1.10, r: 0.62, fr: 0.35867, pr: 0.40,
             aspect: 1.5, alpha: 0.30, cycles: 0.85, angle:  0.35,
             fh: 0.211, ph: 0.00, fa: 0.127, pa: 1.30),
        Blob(hueOffset: -0.11, ax: 0.30, ay: 0.34, fx: 0.61803, fy: 0.35867,
             px: 2.10, py: 0.30, r: 0.55, fr: 0.78615, pr: 1.90,
             aspect: 1.3, alpha: 0.28, cycles: 1.20, angle: -0.42,
             fh: 0.163, ph: 2.40, fa: 0.191, pa: 4.10),
        Blob(hueOffset:  0.08, ax: 0.38, ay: 0.26, fx: 0.35867, fy: 0.78615,
             px: 4.05, py: 3.30, r: 0.58, fr: 0.47128, pr: 3.10,
             aspect: 1.7, alpha: 0.27, cycles: 0.95, angle:  0.78,
             fh: 0.239, ph: 5.00, fa: 0.109, pa: 2.20),
        Blob(hueOffset: -0.16, ax: 0.28, ay: 0.36, fx: 0.78615, fy: 0.24219,
             px: 1.55, py: 5.05, r: 0.50, fr: 0.61803, pr: 0.90,
             aspect: 1.2, alpha: 0.29, cycles: 1.35, angle: -0.90,
             fh: 0.148, ph: 1.15, fa: 0.223, pa: 0.55),
        Blob(hueOffset:  0.05, ax: 0.36, ay: 0.28, fx: 0.24219, fy: 1.00000,
             px: 3.60, py: 2.45, r: 0.60, fr: 0.35867, pr: 5.20,
             aspect: 1.6, alpha: 0.26, cycles: 0.75, angle:  0.12,
             fh: 0.197, ph: 3.75, fa: 0.151, pa: 5.60),
    ]
}
extension View {
    // The mini HUD's surface. In Liquid Glass mode (macOS 26+) it's the clear
    // glass variant — translucent, sampling whatever's behind the panel. In
    // Frosted mode (or below macOS 26) it's the classic material card with a
    // hairline edge. The transport controls carry their own glass in glass mode,
    // so here the base stays a single subtle tray (no heavy glass-on-glass).
    @ViewBuilder
    func hudSurface(_ style: HUDStyle, cornerRadius r: CGFloat, stroke: Color) -> some View {
        let shape = RoundedRectangle(cornerRadius: r, style: .continuous)
        if #available(macOS 26, *), style == .liquidGlass {
            self.glassEffect(.clear, in: shape)
        } else {
            self.background(shape.fill(.regularMaterial)
                                .overlay(shape.strokeBorder(stroke)))
        }
    }
}

// MARK: - Compact HUD (auto-shows under the menu-bar icon while speaking)
//
// A tiny floating panel that drops under the icon whenever a reply starts and
// fades out shortly after it goes quiet. It can be dragged anywhere and carries
// a full transport — back-track / back-10 / play-pause / forward-10 / skip — so
// a single click controls what you're hearing without opening the full deck and
// without the mute/pause "stop everything" side effects. Its surface is Liquid
// Glass (clear) on macOS 26+.

struct MiniDeckView: View {
    @ObservedObject var deck = Deck.shared
    @ObservedObject var settings = SettingsStore.shared
    @Environment(\.colorScheme) private var scheme
    var onHover: (Bool) -> Void = { _ in }
    @State private var shimmerStart: Date?   // set when a new reply starts → glow pulse
    @State private var scrubHover = false     // pointer over the progress line
    @State private var scrubbing = false      // drag in progress
    @State private var scrubFrac: Double = 0  // local 0…1 during a drag, for instant feedback

    var body: some View {
        let theme = Theme.of(scheme)
        let glass = settings.hudStyle == .liquidGlass && HUDStyle.glassAvailable
        // glass keys need a touch more room than the flat icons
        let cardW: CGFloat = glass ? 296 : 264
        VStack(spacing: 8) {
            HStack(spacing: 7) {
                Spark(size: 12, pulse: deck.isPlaying ? deck.level : 0)
                Text(deck.current?.title ?? "SpeakySpeak")
                    .font(.system(size: 12, weight: .semibold, design: .serif))
                    .foregroundStyle(glass ? AnyShapeStyle(.primary) : AnyShapeStyle(theme.text))
                    .lineLimit(1)
                Spacer(minLength: 0)
                // no per-reply dismiss when the panel is pinned "always visible"
                if settings.hudVisibility != .always {
                    Button(action: { MiniHUDController.shared.dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(theme.secondary)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss — pops back up with the next reply")
                }
            }
            HStack(spacing: 0) {
                // far left: restart this reply, then step back to the previous one
                let noBack = deck.currentID == nil && deck.historyCount == 0
                miniButton("backward.end.fill", theme, glass: glass) { deck.backTrack() }
                    .disabled(noBack)
                    .opacity(noBack ? 0.3 : 1)
                Spacer(minLength: 4)
                // center cluster: nudge back / play-pause / nudge forward
                HStack(spacing: glass ? 8 : 14) {
                    miniButton("gobackward.10", theme, glass: glass) { deck.skip(-10) }
                    Button(action: { deck.togglePlay() }) {
                        ZStack {
                            Circle().fill(LinearGradient(colors: [Theme.accent, Theme.accentDeep],
                                                         startPoint: .top, endPoint: .bottom))
                            Image(systemName: deck.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                                .offset(x: deck.isPlaying ? 0 : 1)
                        }
                        .frame(width: 32, height: 32)
                        .scaleEffect(1 + 0.06 * deck.level)
                        .shadow(color: Theme.accent.opacity(0.35), radius: 4, y: 1)
                    }
                    .buttonStyle(.plain)
                    .help(deck.isPlaying ? "Pause" : "Play")
                    miniButton("goforward.10", theme, glass: glass) { deck.skip(10) }
                }
                Spacer(minLength: 4)
                // far right: skip to the next reply (stop this one)
                miniButton("forward.end.fill", theme, glass: glass) { deck.playNext() }
                    .disabled(!deck.isPlaying && !deck.hasQueued)
                    .opacity(!deck.isPlaying && !deck.hasQueued ? 0.35 : 1)
            }
            .padding(.horizontal, 2)
            miniProgress(theme)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(width: cardW)
        .hudSurface(settings.hudStyle, cornerRadius: 15, stroke: theme.cardStroke)
        .overlay(RainbowRipple(active: deck.attentionWanted))
        .overlay(ShimmerGlow(startedAt: shimmerStart))
        // transparent margin so the white flash can bloom past the card edge
        // instead of being hard-clipped at the panel's rectangular bounds
        .padding(18)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { deck.clearAttention() }   // a simple touch ends the ripple
            onHover(inside)
        }
        // a fresh reply fires the locate-me glow. onAppear covers the first
        // reply after launch (the view is built with currentID already set, so
        // onChange wouldn't catch it); onChange covers every reply after.
        .onAppear { fireShimmer() }
        .onChange(of: deck.flashTick) { _, _ in fireShimmer() }
    }

    // flash bright for ~1.5s, then clear so the TimelineView pauses
    private func fireShimmer() {
        guard deck.currentID != nil else { return }
        let now = Date()
        shimmerStart = now
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if shimmerStart == now { shimmerStart = nil }
        }
    }

    // A thin glowing progress line at the bottom — how far into the reply you
    // are, and a scrubber: drag anywhere along it to seek. Three details make
    // it work in a floating panel:
    //   • NoWindowDrag() vetoes the panel's isMovableByWindowBackground, which
    //     otherwise wins the drag and moves the window instead of the playhead
    //     (same fix as the full deck's Scrubber)
    //   • the hit target is 14pt tall against a 3–4pt line, pulled back to the
    //     original layout height with negative padding so the card doesn't grow
    //   • seek() fires on END, not per frame — writing AVAudioPlayer.currentTime
    //     every frame stutters the audio. During the drag we push deck.progress
    //     (with deck.scrubbing suppressing the meter's writeback) so the line
    //     tracks the pointer, then commit once on release.
    private func miniProgress(_ theme: Theme) -> some View {
        let live = scrubHover || scrubbing
        return GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let base = deck.duration > 0 ? min(1, max(0, deck.progress / deck.duration)) : 0
            let frac = scrubbing ? scrubFrac : base
            let lineH: CGFloat = live ? 4 : 3
            let thumb: CGFloat = scrubbing ? 11 : 8
            ZStack(alignment: .leading) {
                Capsule().fill(theme.track).frame(height: lineH)
                Capsule()
                    .fill(LinearGradient(colors: [Theme.accent, Theme.accentDeep],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(0, w * CGFloat(frac)), height: lineH)
                    .shadow(color: Theme.accent.opacity(0.8), radius: 3)
                    .shadow(color: Theme.accent.opacity(0.5), radius: 6)
                Circle()
                    .fill(Theme.accent)
                    .frame(width: thumb, height: thumb)
                    .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
                    .offset(x: min(max(0, w * CGFloat(frac) - thumb / 2), w - thumb))
                    .opacity(live ? 1 : 0)
            }
            .frame(maxHeight: .infinity)          // 3–4pt line, 14pt grab area
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if !scrubbing { scrubbing = true; deck.scrubbing = true }
                        scrubFrac = Double(min(max(0, v.location.x / w), 1))
                        deck.progress = scrubFrac * deck.duration
                    }
                    .onEnded { v in
                        let f = Double(min(max(0, v.location.x / w), 1))
                        deck.seek(to: f * deck.duration)
                        deck.scrubbing = false
                        scrubbing = false
                    })
            .onHover { scrubHover = $0 }
        }
        .frame(height: 14)
        // the row still DRAWS and HIT-TESTS 14pt tall; negative padding reports
        // 4pt to the VStack so the panel's fittingSize (and the ~84pt card)
        // is unchanged. Drop this line if the card should just get taller.
        .padding(.vertical, -5)
        .background(NoWindowDrag())
        .animation(.easeOut(duration: 0.12), value: live)
    }

    // Glass mode → a real Liquid Glass circular control whose symbol contrast the
    // system adapts to whatever's behind the panel. Frosted mode → the flat icon.
    @ViewBuilder
    private func miniButton(_ symbol: String, _ theme: Theme, glass: Bool, action: @escaping () -> Void) -> some View {
        let icon = Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
        if #available(macOS 26, *), glass {
            Button(action: action) {
                icon.frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.small)
            .help(Self.hint(for: symbol))
        } else {
            Button(action: action) {
                icon.foregroundStyle(theme.text.opacity(0.75))
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Self.hint(for: symbol))
        }
    }

    private static func hint(for symbol: String) -> String {
        switch symbol {
        case "backward.end.fill": return "Restart · back one reply"
        case "gobackward.10":     return "Back 10 seconds"
        case "goforward.10":      return "Forward 10 seconds"
        case "forward.end.fill":  return "Skip — stop this reply"
        default:                  return ""
        }
    }
}

// A nonactivating panel won't make its buttons clickable on first hit unless the
// hosting view accepts the first mouse — without this you'd have to click twice.
final class ClickThroughHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    required init(rootView: V) { super.init(rootView: rootView) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

// Owns the floating HUD panel: positions it under the status button, fades it in
// while speaking and out when quiet. It never activates the app or steals focus
// (.nonactivatingPanel + becomesKeyOnlyIfNeeded), so it can't interrupt typing.
final class MiniHUDController {
    static let shared = MiniHUDController()

    private var panel: NSPanel?
    private var host: ClickThroughHostingView<MiniDeckView>?
    private(set) var isVisible = false
    private var hovering = false
    private var lastDesired = false
    private var hideWork: DispatchWorkItem?
    private var userDismissed = false   // X clicked — suppress until the next reply
    private var dismissedID: String?    // which currentID the dismiss applies to
    // once dragged, the HUD stays where the user put it (persisted across
    // launches) instead of snapping back under the menu-bar icon
    private var userOrigin: CGPoint?
    private var programmaticMove = false   // ignore our own setFrame in windowMoved
    private var moveObserver: NSObjectProtocol?
    // last anchor seen from the refresh loop, so flashAttention() can position
    // the panel when the Deck (which has no status-item reference) triggers it
    private weak var lastAnchor: NSStatusBarButton?

    private init() {
        if let s = UserDefaults.standard.string(forKey: "hudUserOrigin") {
            let p = NSPointFromString(s)
            if p != .zero { userOrigin = p }   // (0,0) == never saved
        }
    }

    private func build() {
        let view = MiniDeckView(onHover: { [weak self] inside in self?.handleHover(inside) })
        let h = ClickThroughHostingView(rootView: view)
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 264, height: 84),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        // draggable anywhere: grab the background (the transport buttons are
        // discrete taps, so they still click — only a click-and-move on empty
        // space moves the panel). No SwiftUI drag gestures live here to fight it.
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.contentView = h
        p.alphaValue = 0
        panel = p
        host = h
        // remember where the user drags it (ignoring our own repositioning)
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: p, queue: .main) { [weak self] _ in
            self?.windowMoved()
        }
    }

    private func windowMoved() {
        guard !programmaticMove, let p = panel, isVisible else { return }
        let o = p.frame.origin
        userOrigin = o
        UserDefaults.standard.set(NSStringFromPoint(o), forKey: "hudUserOrigin")
    }

    func setDesiredVisible(_ visible: Bool, always: Bool = false, currentID: String?, anchor: NSStatusBarButton?) {
        // a new reply starting clears a manual dismiss — the HUD pops back up
        if let id = currentID, id != dismissedID { userDismissed = false }
        // in "always visible" mode there's no per-reply dismiss to honor
        if always { userDismissed = false }
        if let a = anchor { lastAnchor = a }
        lastDesired = visible
        if visible && !userDismissed {
            cancelHide()
            show(anchor: anchor)
        } else if !hovering {
            scheduleHide()
        }
    }

    // A new reply is queued but held behind a paused one. Make sure the panel
    // is on screen (overriding a per-reply X dismiss) — the rainbow ripple
    // itself is SwiftUI, driven by Deck.attentionWanted inside MiniDeckView.
    func summonForAttention() {
        userDismissed = false
        cancelHide()
        show(anchor: lastAnchor)
    }

    // X button: hide for the current reply only. The next reply to start playing
    // clears this (see setDesiredVisible), so the HUD comes back on its own.
    func dismiss() {
        userDismissed = true
        dismissedID = Deck.shared.currentID
        lastDesired = false
        hovering = false
        fadeOut(force: true)
    }

    private func handleHover(_ inside: Bool) {
        hovering = inside
        if inside { cancelHide() }
        else if !lastDesired { scheduleHide() }
    }

    private func show(anchor: NSStatusBarButton?) {
        if panel == nil { build() }
        guard let p = panel, let h = host else { return }
        // Only (re)position when appearing from hidden — once shown, leave it put
        // so a drag isn't undone by the next reply (and the 30fps refresh while
        // playing doesn't fight the user's chosen spot).
        if !isVisible {
            let fit = h.fittingSize
            let size = NSSize(width: max(240, fit.width), height: max(60, fit.height))
            position(p, size: size, anchor: anchor)
            p.alphaValue = 0
        }
        p.orderFrontRegardless()
        isVisible = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            p.animator().alphaValue = 1
        }
    }

    private func position(_ p: NSPanel, size: NSSize, anchor: NSStatusBarButton?) {
        programmaticMove = true
        defer { DispatchQueue.main.async { [weak self] in self?.programmaticMove = false } }

        // dragged before → restore that spot, clamped onto a visible screen
        if let o = userOrigin {
            let screen = NSScreen.screens.first { $0.frame.contains(o) } ?? NSScreen.main
            let vf = screen?.visibleFrame ?? NSRect(origin: o, size: size)
            let x = min(max(vf.minX + 6, o.x), vf.maxX - size.width - 6)
            let y = min(max(vf.minY + 6, o.y), vf.maxY - size.height - 6)
            p.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
            return
        }
        // default: centered under the menu-bar icon
        guard let button = anchor, let bwin = button.window else {
            p.setContentSize(size); return
        }
        let bf = bwin.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = bwin.screen ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(origin: .zero, size: size)
        var x = bf.midX - size.width / 2
        x = min(max(vf.minX + 6, x), vf.maxX - size.width - 6)
        let y = bf.minY - size.height - 4   // just under the menu bar
        p.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    private func scheduleHide() {
        cancelHide()
        let w = DispatchWorkItem { [weak self] in self?.fadeOut() }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: w)
    }

    private func cancelHide() { hideWork?.cancel(); hideWork = nil }

    private func fadeOut(force: Bool = false) {
        guard let p = panel, isVisible else { return }
        if !force, hovering || lastDesired { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = force ? 0.14 : 0.25
            p.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            if force || (!self.hovering && !self.lastDesired) {
                p.orderOut(nil)
                self.isVisible = false
            }
        })
    }
}

// MARK: - Settings (mirrors the dotfiles speak-reply.sh reads, plus app prefs)

let playbackRates: [Double] = [0.8, 1.0, 1.25, 1.5, 2.0]

// Curated English Kokoro-82M voices (the model card lists ~54; any id still
// works if typed into ~/.claude/speak-voice-kokoro by hand).
let kokoroVoiceChoices: [(id: String, label: String)] = [
    ("af_heart", "Heart · US ♀"), ("af_bella", "Bella · US ♀"), ("af_nicole", "Nicole · US ♀"),
    ("af_sarah", "Sarah · US ♀"), ("af_sky", "Sky · US ♀"), ("af_nova", "Nova · US ♀"),
    ("af_aoede", "Aoede · US ♀"), ("af_kore", "Kore · US ♀"), ("af_river", "River · US ♀"),
    ("af_alloy", "Alloy · US ♀"), ("af_jessica", "Jessica · US ♀"),
    ("am_adam", "Adam · US ♂"), ("am_michael", "Michael · US ♂"), ("am_echo", "Echo · US ♂"),
    ("am_eric", "Eric · US ♂"), ("am_fenrir", "Fenrir · US ♂"), ("am_liam", "Liam · US ♂"),
    ("am_onyx", "Onyx · US ♂"), ("am_puck", "Puck · US ♂"),
    ("bf_emma", "Emma · UK ♀"), ("bf_alice", "Alice · UK ♀"), ("bf_isabella", "Isabella · UK ♀"),
    ("bf_lily", "Lily · UK ♀"),
    ("bm_george", "George · UK ♂"), ("bm_daniel", "Daniel · UK ♂"), ("bm_fable", "Fable · UK ♂"),
    ("bm_lewis", "Lewis · UK ♂"),
]

// "Heart · US ♀" → "Heart"; a hand-typed id falls back to its name part.
func kokoroDisplayName(_ id: String) -> String {
    if let label = kokoroVoiceChoices.first(where: { $0.id == id })?.label,
       let name = label.split(separator: "·").first {
        return name.trimmingCharacters(in: .whitespaces)
    }
    return id.split(separator: "_").last.map { String($0).capitalized } ?? id
}

enum SpeechEngine: String, CaseIterable, Identifiable {
    case auto = "", kokoro = "kokoro", say = "say"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Automatic"
        case .kokoro: return "Kokoro (neural)"
        case .say: return "System voice"
        }
    }
}

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case sy, speaker
    var id: String { rawValue }
    var label: String { self == .sy ? "Sy mark" : "Speaker (status)" }
}

// Mini-HUD surface: Apple Liquid Glass (macOS 26+) or the classic frosted card.
// Liquid Glass is gorgeous but its contrast is backdrop-dependent, so the frosted
// card stays available as a reliably-legible fallback the user can switch to.
enum HUDStyle: String, CaseIterable, Identifiable {
    case liquidGlass, frosted
    var id: String { rawValue }
    var label: String { self == .liquidGlass ? "Liquid Glass" : "Frosted (classic)" }
    // Liquid Glass only exists on macOS 26+; below that we always render frosted.
    static var glassAvailable: Bool { if #available(macOS 26, *) { true } else { false } }
    static var defaultStyle: HUDStyle { glassAvailable ? .liquidGlass : .frosted }
}

// When the mini HUD appears: only while a reply is speaking (auto-hide after,
// the default), or always on screen as a persistent little controller.
enum HUDVisibility: String, CaseIterable, Identifiable {
    case whileSpeaking, always
    var id: String { rawValue }
    var label: String { self == .whileSpeaking ? "Only while speaking" : "Always visible" }
}

// Writes the same ~/.claude knobs the Stop hook honors, so the settings panel
// drives rendering without the user editing dotfiles. Re-read from disk each
// time the window opens (the shell may have changed them out from under us).
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    private var loading = false

    @Published var enabled: Bool = true            { didSet { guard !loading else { return }; setFlag("speak-off", present: !enabled) } }
    @Published var engine: SpeechEngine = .auto    { didSet { guard !loading else { return }; writeOrRemove("speak-engine", engine.rawValue) } }
    // bf_lily = the project default voice; must match speak-reply.sh's fallback
    // (five sync points — grep bf_lily). Was af_heart: Settings showed Heart
    // while the hook rendered Lily (Sasha's install report, Defect 2).
    @Published var kokoroVoice: String = "bf_lily"{ didSet { guard !loading else { return }; writeOrRemove("speak-voice-kokoro", kokoroVoice) } }
    @Published var sayVoice: String = ""           { didSet { guard !loading else { return }; writeOrRemove("speak-voice", sayVoice) } }
    @Published var sayRate: String = ""            { didSet { guard !loading else { return }; writeOrRemove("speak-rate", sayRate) } }
    @Published var menuBarStyle: MenuBarStyle = .sy { didSet { guard !loading else { return }; UserDefaults.standard.set(menuBarStyle.rawValue, forKey: "menuBarStyle") } }
    @Published var hudStyle: HUDStyle = .liquidGlass { didSet { guard !loading else { return }; UserDefaults.standard.set(hudStyle.rawValue, forKey: "hudStyle") } }
    @Published var hudVisibility: HUDVisibility = .whileSpeaking { didSet { guard !loading else { return }; UserDefaults.standard.set(hudVisibility.rawValue, forKey: "hudVisibility") } }

    let kokoroInstalled: Bool
    @Published private(set) var sayVoices: [String] = []

    var usingKokoro: Bool {
        switch engine {
        case .kokoro: return true
        case .say:    return false
        case .auto:   return kokoroInstalled
        }
    }

    private init() {
        kokoroInstalled = FileManager.default.isExecutableFile(
            atPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/mlx_audio.tts.generate").path)
        // NEVER run `say -v ?` synchronously here: Process.waitUntilExit() on
        // the main thread pumps the run loop, which drains queued main-queue
        // blocks into code that reads SettingsStore.shared — while this init
        // still holds its dispatch_once lock. That recursion crashed the app
        // at launch whenever a fresh reply was autoplaying (2026-07-20).
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let v = SettingsStore.loadSayVoices()
            DispatchQueue.main.async { self?.sayVoices = v }
        }
        menuBarStyle = MenuBarStyle(rawValue: UserDefaults.standard.string(forKey: "menuBarStyle") ?? "") ?? .sy
        hudStyle = UserDefaults.standard.string(forKey: "hudStyle").flatMap(HUDStyle.init) ?? HUDStyle.defaultStyle
        hudVisibility = UserDefaults.standard.string(forKey: "hudVisibility").flatMap(HUDVisibility.init) ?? .whileSpeaking
        reload()
    }

    func reload() {
        loading = true
        enabled = !FileManager.default.fileExists(atPath: path("speak-off"))
        engine = SpeechEngine(rawValue: read("speak-engine")) ?? .auto
        let kv = read("speak-voice-kokoro"); kokoroVoice = kv.isEmpty ? "bf_lily" : kv
        sayVoice = read("speak-voice")
        sayRate = read("speak-rate")
        loading = false
    }

    private func path(_ n: String) -> String { dir.appendingPathComponent(n).path }
    private func read(_ n: String) -> String {
        (try? String(contentsOfFile: path(n), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    private func writeOrRemove(_ n: String, _ v: String) {
        if v.isEmpty { try? FileManager.default.removeItem(atPath: path(n)) }
        else { try? v.write(toFile: path(n), atomically: true, encoding: .utf8) }
    }
    private func setFlag(_ n: String, present: Bool) {
        if present { FileManager.default.createFile(atPath: path(n), contents: nil) }
        else { try? FileManager.default.removeItem(atPath: path(n)) }
    }

    // Parse `say -v '?'` → English voice names (e.g. "Ava (Premium)").
    private static func loadSayVoices() -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", "?"]
        let pipe = Pipe(); p.standardOutput = pipe
        guard (try? p.run()) != nil else { return [] }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let s = String(data: data, encoding: .utf8) else { return [] }
        var names: [String] = []
        for line in s.split(separator: "\n") {
            let str = String(line)
            guard let r = str.range(of: #"\s+[a-z]{2}_[A-Z]{2}"#, options: .regularExpression) else { continue }
            guard str[r].trimmingCharacters(in: .whitespaces).hasPrefix("en") else { continue }
            let name = String(str[str.startIndex..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { names.append(name) }
        }
        return Array(Set(names)).sorted()
    }
}

// MARK: - Kokoro rendering (shared by voice preview and queue re-render)

let kokoroRenderDir = URL(fileURLWithPath: "/tmp/claude-speech/render", isDirectory: true)

// Same request-file protocol as the hook's render_via_daemon (see tts-daemon.py):
// write <id>.req, wait for <id>.done, trust the daemon only while its heartbeat
// is fresh. Blocking — call from a background queue, never the main thread.
// Returns false fast when the daemon is down (no cold fallback here; callers
// that need one, like the previewer, bring their own).
func kokoroDaemonRender(text: String, voice: String, out: URL) -> Bool {
    let fm = FileManager.default
    let alive = kokoroRenderDir.appendingPathComponent("daemon.alive").path
    func aliveFresh() -> Bool {
        guard let m = (try? fm.attributesOfItem(atPath: alive))?[.modificationDate] as? Date
        else { return false }
        return Date().timeIntervalSince(m) <= 8
    }
    guard aliveFresh() else { return false }
    let id = "app-\(Int(Date().timeIntervalSince1970 * 1000))"
    let req = kokoroRenderDir.appendingPathComponent(id + ".req")
    let mark = kokoroRenderDir.appendingPathComponent(id + ".done")
    try? fm.removeItem(at: mark)
    guard let data = try? JSONSerialization.data(
        withJSONObject: ["text": text, "voice": voice, "out": out.path]) else { return false }
    let tmp = kokoroRenderDir.appendingPathComponent(".tmp-" + id + ".req")
    do {
        try data.write(to: tmp)
        try fm.moveItem(at: tmp, to: req)
    } catch { return false }
    var done = false
    // Length-scaled ceiling, mirroring the hook: 15s slack + 1s per 80 chars, in
    // 0.05s ticks. A flat 20s made every long item fall back to the CLI on a
    // voice change. The liveness check below still bounds a dead daemon to ~8s.
    for i in 1...(300 + text.count / 4) {
        usleep(50_000)
        if fm.fileExists(atPath: mark.path) { done = true; break }
        if i % 40 == 0, !aliveFresh() { break }   // daemon died mid-render
    }
    guard done else { try? fm.removeItem(at: req); return false }
    let status = (try? String(contentsOf: mark, encoding: .utf8)) ?? ""
    try? fm.removeItem(at: mark)
    return status == "ok" && fm.fileExists(atPath: out.path)
}

// Matches the hook's convert_wav: loudness-normalize to -16 LUFS while encoding
// AAC (Kokoro renders ~12dB quiet); afconvert (no gain stage) if ffmpeg is missing.
func convertWavToM4a(_ wav: URL, out: URL) -> Bool {
    let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
    let p = Process()
    if let f = ffmpeg {
        p.executableURL = URL(fileURLWithPath: f)
        p.arguments = ["-hide_banner", "-loglevel", "error", "-y", "-i", wav.path,
                       "-af", "loudnorm=I=-16:TP=-1.5:LRA=11", "-c:a", "aac", "-b:a", "96k", out.path]
    } else {
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        p.arguments = ["-f", "m4af", "-d", "aac", wav.path, out.path]
    }
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0 && FileManager.default.fileExists(atPath: out.path)
}

// MARK: - Voice preview

// Speaks a short sample in the currently selected voice so voices can be
// auditioned from Settings without waiting for a real reply. Kokoro renders
// through the same warm-daemon request-file protocol the Stop hook uses
// (cold CLI as a fallback) and caches each voice's sample under
// /tmp/claude-speech/preview/, so hearing a voice again is instant.
// `say` voices speak live through the speakers — no file, no wait.
final class VoicePreviewer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = VoicePreviewer()

    enum State { case idle, rendering, playing }
    @Published var state: State = .idle

    private let previewDir = URL(fileURLWithPath: "/tmp/claude-speech/preview", isDirectory: true)
    private let kokoroBin = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/bin/mlx_audio.tts.generate")
    private var player: AVAudioPlayer?
    private var sayProcess: Process?
    private var generation = 0   // invalidates an in-flight render on stop/change

    func toggle() { state == .idle ? start() : stop() }

    // A different voice picked mid-audition: keep talking, in the new voice.
    func voiceChanged() {
        guard state != .idle else { return }
        stop()
        start()
    }

    func stop() {
        generation += 1
        player?.stop()
        player = nil
        if let p = sayProcess { p.terminationHandler = nil; p.terminate() }
        sayProcess = nil
        state = .idle
    }

    private func start() {
        let s = SettingsStore.shared
        if Deck.shared.isPlaying { Deck.shared.togglePlay() }   // don't talk over a reply
        if s.usingKokoro && s.kokoroInstalled {
            previewKokoro(voice: s.kokoroVoice)
        } else {
            previewSay(s)   // also the fallback when Kokoro is forced but missing
        }
    }

    private func sample(_ name: String?) -> String {
        name.map { "Hi, I'm \($0). This is how Claude's replies will sound." }
            ?? "Hi. This is how Claude's replies will sound."
    }

    // Mirrors the hook's say path: explicit voice if set, else the same probe
    // order pick_say_voice uses, else the system default voice (no -v).
    private func previewSay(_ s: SettingsStore) {
        var voice = s.sayVoice
        if voice.isEmpty {
            voice = ["Ava (Premium)", "Ava (Enhanced)", "Zoe (Premium)", "Samantha (Enhanced)", "Samantha"]
                .first { s.sayVoices.contains($0) } ?? ""
        }
        let name = voice.isEmpty ? nil
            : String(voice.prefix { $0 != "(" }).trimmingCharacters(in: .whitespaces)
        runSay(s, voice: voice, text: sample(name))
    }

    // Rendered to a file and played through AVAudioPlayer rather than spoken
    // live: live `say` output can't be volume-scaled, so it ignored the app's
    // Volume slider while every other sound honored it (2026-08-18 loudness
    // audit). No loudnorm here on purpose — say's native level is the -16
    // reference the hook normalizes Kokoro TO, and the hook plays say renders
    // unnormalized too.
    private func runSay(_ s: SettingsStore, voice: String, text: String) {
        state = .rendering
        generation += 1
        let gen = generation
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let fm = FileManager.default
            try? fm.createDirectory(at: previewDir, withIntermediateDirectories: true)
            let out = previewDir.appendingPathComponent("say-render.aiff")
            try? fm.removeItem(at: out)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            var args: [String] = []
            if !voice.isEmpty { args += ["-v", voice] }
            if !s.sayRate.isEmpty { args += ["-r", s.sayRate] }
            args += ["-o", out.path, text]
            p.arguments = args
            try? p.run()
            p.waitUntilExit()
            DispatchQueue.main.async {
                guard gen == self.generation, self.state == .rendering else { return }
                guard p.terminationStatus == 0, let ap = try? AVAudioPlayer(contentsOf: out) else {
                    dlog("voice preview: say render failed")
                    self.state = .idle
                    return
                }
                ap.delegate = self
                ap.volume = Float(Deck.shared.volume)
                ap.play()
                self.player = ap
                self.state = .playing
            }
        }
    }

    // The hook loudness-normalizes every queued reply to -16 LUFS (Kokoro's
    // raw output is ~12dB quieter than say). Anything the APP renders must go
    // through the same gain stage or it plays noticeably quieter than replies
    // — Adam heard exactly that on the first spoken update confirmation
    // (2026-08-18). Same ffmpeg filter as the hook's convert_wav; no ffmpeg
    // (Intel without brew) = raw audio, same as the hook's afconvert branch.
    // The normalized file is cached next to the raw one; callers that must
    // re-render (announce) delete both first.
    private func normalized(_ raw: URL) -> URL {
        let out = raw.deletingPathExtension().appendingPathExtension("norm.wav")
        let fm = FileManager.default
        if fm.fileExists(atPath: out.path) { return out }
        guard let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg"]
            .first(where: { fm.isExecutableFile(atPath: $0) }) else { return raw }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-hide_banner", "-loglevel", "error", "-y", "-i", raw.path,
                       "-af", "loudnorm=I=-16:TP=-1.5:LRA=11", out.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return (p.terminationStatus == 0 && fm.fileExists(atPath: out.path)) ? out : raw
    }

    // One-line spoken announcements from the app itself — today only the
    // post-update confirmation (Adam's pick, 2026-08-18: the talking app
    // announces its own update; no modal, no notification). Same engine and
    // voice as replies. Callers gate on mute/enabled/busy; this only guards
    // against double-starting the previewer.
    func announce(_ text: String) {
        guard state == .idle else { return }
        let s = SettingsStore.shared
        if s.usingKokoro && s.kokoroInstalled {
            state = .rendering
            generation += 1
            let gen = generation
            let out = previewDir.appendingPathComponent("announce.wav")
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let fm = FileManager.default
                try? fm.createDirectory(at: previewDir, withIntermediateDirectories: true)
                // never cache: the text carries a version (raw AND normalized)
                try? fm.removeItem(at: out)
                try? fm.removeItem(at: out.deletingPathExtension().appendingPathExtension("norm.wav"))
                var ok = kokoroDaemonRender(text: text, voice: s.kokoroVoice, out: out)
                if !ok { ok = renderViaCLI(text: text, voice: s.kokoroVoice, out: out) }
                let playURL = ok ? self.normalized(out) : out
                DispatchQueue.main.async {
                    guard gen == self.generation, self.state == .rendering else { return }
                    guard ok, let p = try? AVAudioPlayer(contentsOf: playURL) else {
                        dlog("announce: kokoro render failed")
                        self.state = .idle
                        return
                    }
                    p.delegate = self
                    p.volume = Float(Deck.shared.volume)
                    p.play()
                    self.player = p
                    self.state = .playing
                }
            }
        } else {
            var voice = s.sayVoice
            if voice.isEmpty {
                voice = ["Ava (Premium)", "Ava (Enhanced)", "Zoe (Premium)", "Samantha (Enhanced)", "Samantha"]
                    .first { s.sayVoices.contains($0) } ?? ""
            }
            runSay(s, voice: voice, text: text)
        }
    }

    private func previewKokoro(voice: String) {
        state = .rendering
        generation += 1
        let gen = generation
        let out = previewDir.appendingPathComponent("\(voice).wav")
        let text = sample(kokoroDisplayName(voice))
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let fm = FileManager.default
            try? fm.createDirectory(at: previewDir, withIntermediateDirectories: true)
            var ok = fm.fileExists(atPath: out.path)
            if !ok { ok = kokoroDaemonRender(text: text, voice: voice, out: out) }
            if !ok { ok = renderViaCLI(text: text, voice: voice, out: out) }
            // Previews advertise "how Claude's replies will sound" — so they
            // must match reply loudness, not Kokoro's quiet raw output.
            let playURL = ok ? self.normalized(out) : out
            DispatchQueue.main.async {
                guard gen == self.generation, self.state == .rendering else { return }
                guard ok, let p = try? AVAudioPlayer(contentsOf: playURL) else {
                    dlog("voice preview: kokoro render failed (\(voice))")
                    self.state = .idle
                    return
                }
                p.delegate = self
                p.volume = Float(Deck.shared.volume)
                p.play()
                self.player = p
                self.state = .playing
            }
        }
    }

    private func renderViaCLI(text: String, voice: String, out: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: kokoroBin.path) else { return false }
        let p = Process()
        p.executableURL = kokoroBin
        // mlx-audio writes "<file_prefix>.wav", which is exactly `out`
        p.arguments = ["--model", "mlx-community/Kokoro-82M-bf16", "--voice", voice,
                       "--join_audio", "--file_prefix", out.deletingPathExtension().path,
                       "--text", text]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0 && FileManager.default.fileExists(atPath: out.path)
    }

    func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            guard p === self.player else { return }
            self.player = nil
            self.state = .idle
        }
    }
}

// MARK: - Settings window

struct SettingsView: View {
    @ObservedObject var settings = SettingsStore.shared
    @ObservedObject var deck = Deck.shared
    @ObservedObject var previewer = VoicePreviewer.shared
    @ObservedObject var updater = Updater.shared
    // Inline "Copied." confirmation on the Claude-prompt button; clears itself.
    @State private var promptCopied = false

    var body: some View {
        Form {
            Section("Speech") {
                Toggle("Speak Claude's replies", isOn: $settings.enabled)
                // No Engine row: Kokoro when installed, system voice otherwise
                // (~/.claude/speak-engine still overrides for the shell-inclined).
                if settings.usingKokoro {
                    HStack(spacing: 10) {
                        Picker("Voice", selection: $settings.kokoroVoice) {
                            if !kokoroVoiceChoices.contains(where: { $0.id == settings.kokoroVoice }) {
                                Text(settings.kokoroVoice).tag(settings.kokoroVoice)
                            }
                            ForEach(kokoroVoiceChoices, id: \.id) { Text($0.label).tag($0.id) }
                        }
                        previewButton
                    }
                } else {
                    HStack(spacing: 10) {
                        Picker("Voice", selection: $settings.sayVoice) {
                            Text("Automatic (best installed)").tag("")
                            if !settings.sayVoice.isEmpty, !settings.sayVoices.contains(settings.sayVoice) {
                                Text(settings.sayVoice).tag(settings.sayVoice)
                            }
                            ForEach(settings.sayVoices, id: \.self) { Text($0).tag($0) }
                        }
                        previewButton
                    }
                    Picker("Rate", selection: $settings.sayRate) {
                        Text("Natural").tag("")
                        ForEach(["150", "175", "200", "225", "250"], id: \.self) { Text("\($0) wpm").tag($0) }
                    }
                }
            }
            Section("Playback") {
                Picker("Speed", selection: $deck.rate) {
                    ForEach(playbackRates, id: \.self) { Text(fmtRate($0)).tag($0) }
                }
                LabeledContent("Volume") {
                    HStack {
                        Slider(value: $deck.volume, in: 0...1)
                        Text("\(Int((deck.volume * 100).rounded()))%")
                            .monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                    }
                }
                Toggle("Mute — keep queuing, don't play aloud", isOn: $deck.muted)
            }
            Section("Appearance") {
                Picker("Menu bar icon", selection: $settings.menuBarStyle) {
                    ForEach(MenuBarStyle.allCases) { Text($0.label).tag($0) }
                }
                Picker("Reading panel", selection: $settings.hudStyle) {
                    ForEach(HUDStyle.allCases) { Text($0.label).tag($0) }
                }
                .disabled(!HUDStyle.glassAvailable)
                if !HUDStyle.glassAvailable {
                    Text("Liquid Glass needs macOS 26 or later.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Liquid Glass is translucent and adapts to what's behind it; Frosted is a solid, always-legible card.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("Show reading panel", selection: $settings.hudVisibility) {
                    ForEach(HUDVisibility.allCases) { Text($0.label).tag($0) }
                }
                Text("“Always visible” keeps the mini panel on screen as a persistent controller; otherwise it appears only while a reply is being spoken.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            // Version, updating and reporting a problem all live here: the
            // status-item menu used to carry them and grew too tall to fit on
            // short screens (2026-08-17). This is the only place an update is
            // started; the popover and the menu bar just point at it.
            Section("About & support") {
                LabeledContent("Version") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("SpeakySpeak \(updater.localVersion)")
                        if let from = updater.justUpdatedFrom {
                            Text("updated from \(from) ✓")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let v = updater.availableVersion {
                    // The update runs for ~a minute; every state is visible
                    // here (2026-08-18: a silent updater cost a real user a
                    // stalled update with a working-looking button).
                    switch updater.phase {
                    case .running:
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Updating to \(v)… pulling and rebuilding, about a minute.")
                        }
                    case .relaunching:
                        Text("Update installed ✓ Relaunching…")
                    case .failed(let reason):
                        Button("Update to \(v)…") { Updater.shared.performUpdate() }
                            .buttonStyle(.borderedProminent)
                        Text("The last try failed: \(reason)")
                            .font(.caption).foregroundStyle(.red)
                    case .idle:
                        Button("Update to \(v)…") { Updater.shared.performUpdate() }
                            .buttonStyle(.borderedProminent)
                        Text("Pulls the latest, rebuilds, and relaunches in about a minute.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    LabeledContent {
                        Button(updater.checking ? "Checking…" : "Check for updates") {
                            Updater.shared.checkNow()
                        }
                        .disabled(updater.checking)
                    } label: {
                        Text(updater.checkResult ?? "Checked automatically once a day.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button("Email a report…") { Feedback.openMailReport() }
                Text("Opens a mail draft to \(Feedback.address) with your version, engine and the last few log lines filled in. Add what went wrong and send it.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Have Claude write a report") {
                    Feedback.copyClaudePrompt()
                    promptCopied = true
                    // Self-clearing: the Settings window is reused for the
                    // app's whole life, so onAppear can't be relied on to
                    // reset this the next time it opens.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { promptCopied = false }
                }
                Text(promptCopied ? "Copied. Paste it into Claude Code."
                                  : "Copies a prompt that tells your Claude Code to gather the logs and draft the mail.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .onAppear { settings.reload() }
        // picking a different voice mid-audition hops the sample to it;
        // switching engines just stops (the voice list changes wholesale)
        .onChange(of: settings.kokoroVoice) { _, _ in previewer.voiceChanged() }
        .onChange(of: settings.sayVoice) { _, _ in previewer.voiceChanged() }
        .onChange(of: settings.sayRate) { _, _ in previewer.voiceChanged() }
        .onChange(of: settings.engine) { _, _ in previewer.stop() }
        .onDisappear { previewer.stop() }
    }

    // Compact preview control beside the voice picker: play → spinner → stop.
    // Fixed frame so the row doesn't shift as the state changes.
    private var previewButton: some View {
        Button(action: { previewer.toggle() }) {
            Group {
                switch previewer.state {
                case .idle:      Image(systemName: "play.circle.fill")
                case .rendering: ProgressView().controlSize(.small)
                case .playing:   Image(systemName: "stop.circle.fill")
                }
            }
            .font(.system(size: 18))
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("Preview this voice — switch voices while it plays to hop between them")
        .accessibilityLabel(previewer.state == .idle ? "Preview voice" : "Stop preview")
    }
}

final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    // Kokoro voice as of the last time the window opened. If it's different
    // when the window closes, the queued replies get re-spoken in the new
    // voice — on close (not per change) so auditioning voices costs nothing.
    private var voiceAtOpen = ""
    private var closeObserver: NSObjectProtocol?

    private init() {
        let host = NSHostingController(rootView: SettingsView())
        host.sizingOptions = [.preferredContentSize]
        let win = NSWindow(contentViewController: host)
        win.styleMask = [.titled, .closable, .miniaturizable]
        win.title = "SpeakySpeak Settings"
        win.isReleasedWhenClosed = false
        super.init(window: win)
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: win, queue: .main) { [weak self] _ in
            self?.windowClosed()
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func windowClosed() {
        let s = SettingsStore.shared
        if s.usingKokoro, s.kokoroVoice != voiceAtOpen {
            Deck.shared.reRenderQueued(voice: s.kokoroVoice)
        }
    }

    func show() {
        SettingsStore.shared.reload()
        if !(window?.isVisible ?? false) {
            window?.center()
            voiceAtOpen = SettingsStore.shared.kokoroVoice
        }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

// The menu-bar "Sy" is the same hand-made mark as the app icon: SyGlyph.png is
// the exact white-on-transparent "Sy" (Optima, extracted from SyLogo.png by
// Icon/render-icon.swift), flagged as a template so the system tints it for
// light/dark bars. Two tweaks for the menu bar: Optima Regular reads thin at
// this size, so the strokes get a clean morphological dilation (~0.75% of
// glyph height); and the glyph is centered in a full-bar-height canvas at 64%
// so there's padding top and bottom (it was clipping at the top before).
func makeSyGlyph() -> NSImage {
    let barH = NSStatusBar.system.thickness
    let glyphH = barH * 0.64
    guard let url = Bundle.main.url(forResource: "SyGlyph", withExtension: "png"),
          let ci = CIImage(contentsOf: url) else { return fallbackSyGlyph(barH) }
    let thick: CIImage = {
        guard let f = CIFilter(name: "CIMorphologyMaximum",
                               parameters: [kCIInputImageKey: ci,
                                            kCIInputRadiusKey: ci.extent.height * 0.0075]),
              let out = f.outputImage else { return ci }
        return out.cropped(to: ci.extent)
    }()
    guard let cg = CIContext().createCGImage(thick, from: ci.extent) else { return fallbackSyGlyph(barH) }
    let glyph = NSImage(cgImage: cg, size: ci.extent.size)

    let glyphW = glyphH * (ci.extent.width / ci.extent.height)
    let img = NSImage(size: NSSize(width: ceil(glyphW + 3), height: ceil(barH)))
    img.lockFocus()
    glyph.draw(in: NSRect(x: (img.size.width - glyphW) / 2, y: (barH - glyphH) / 2,
                          width: glyphW, height: glyphH))
    img.unlockFocus()
    img.isTemplate = true
    return img
}

// Fallback if SyGlyph.png is missing: live Didot render, sized by true ink
// bounds so the y descender isn't clipped (NSAttributedString.size() undercounts it).
func fallbackSyGlyph(_ barH: CGFloat) -> NSImage {
    let pt: CGFloat = 16
    let font = NSFont(name: "Optima-Bold", size: pt) ?? NSFont.systemFont(ofSize: pt, weight: .bold)
    let line = CTLineCreateWithAttributedString(
        NSAttributedString(string: "Sy", attributes: [.font: font, .kern: -pt * 0.06]) as CFAttributedString)
    let ink = CTLineGetImageBounds(line, nil)
    let img = NSImage(size: NSSize(width: ceil(ink.width + 2), height: ceil(barH)))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.textPosition = CGPoint(x: 1 - ink.minX, y: (barH - ink.height) / 2 - ink.minY)
    CTLineDraw(line, ctx)
    img.unlockFocus()
    img.isTemplate = true
    return img
}

// MARK: - App shell (accessory app, menu-bar deck)
//
// The deck lives behind a menu-bar icon instead of floating over everything:
// left-click drops the panel down as a transient popover (dismisses when you
// click away), right-click (or ctrl-click) shows a small Mute/Quit menu. The
// icon itself reflects state — symbol for off/muted/playing/idle, a queue-count
// badge, and an alpha pulse driven by speech loudness while a reply plays.

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var pulseTimer: Timer?
    private var pulsePhase: CGFloat = 0
    private var bag = Set<AnyCancellable>()
    private lazy var syGlyph = makeSyGlyph()
    private var quietHotKey: EventHotKeyRef?

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self   // hide the compact HUD while the full deck is open
        let host = NSHostingController(rootView: DeckView())
        host.sizingOptions = [.preferredContentSize]   // popover tracks the deck's size
        popover.contentViewController = host

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageLeft
            button.font = .systemFont(ofSize: 11, weight: .semibold)
            button.target = self
            button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "SpeakySpeak"
        }

        Deck.shared.start()
        refreshStatus()
        Updater.shared.start()

        // Rebuild the icon only on discrete state changes — not on every
        // progress/level tick (the pulse handles loudness separately).
        let deck = Deck.shared
        Publishers.Merge4(
            deck.$isPlaying.removeDuplicates().map { _ in () },
            deck.$muted.removeDuplicates().map { _ in () },
            deck.$enabled.removeDuplicates().map { _ in () },
            deck.$items.map { $0.lazy.filter { $0.state == .queued }.count }
                .removeDuplicates().map { _ in () }
        )
        // currentID: a skip while already playing changes the reply without
        // toggling isPlaying — Now Playing needs the new title/duration
        .merge(with: deck.$currentID.removeDuplicates().map { _ in () })
        // …and the ↑ update hint the moment the daily check finds one
        .merge(with: Updater.shared.$availableVersion.removeDuplicates().map { _ in () })
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in
            self?.refreshStatus()
            self?.updateHUD()
            NowPlayingBridge.shared.update()
        }
        .store(in: &bag)

        // Switching the menu-bar icon style (Sy mark ↔ speaker) repaints it.
        SettingsStore.shared.$menuBarStyle
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshStatus() }
            .store(in: &bag)

        // Toggling "Always visible" ↔ "Only while speaking" shows/hides the HUD now.
        SettingsStore.shared.$hudVisibility
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateHUD() }
            .store(in: &bag)

        registerQuietHotKey()
        NowPlayingBridge.shared.setup()
        PeerGate.shared.start()
        updateHUD()
    }

    // ⌃⌥⌘Space, registered system-wide via Carbon so it works from any app and
    // needs no Accessibility/Input-Monitoring permission. Skips (stops) whatever
    // is speaking — the "make it quiet now" key, distinct from mute/pause.
    private func registerQuietHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        // We register exactly one hotkey, so any hot-key-pressed event reaching
        // this handler is ours — skip the event-param decode and just act.
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async {
                dlog("quiet hotkey — skip current")
                Deck.shared.quietSkip()
            }
            return noErr
        }, 1, &spec, nil, nil)

        let id = EventHotKeyID(signature: OSType(0x53504B59 /* "SPKY" */), id: 1)
        let mods = UInt32(controlKey | optionKey | cmdKey)
        let status = RegisterEventHotKey(UInt32(kVK_Space), mods, id,
                                         GetApplicationEventTarget(), 0, &quietHotKey)
        dlog(status == noErr ? "quiet hotkey registered (⌃⌥⌘Space)"
                             : "quiet hotkey registration failed (\(status))")
    }

    // Drives the compact HUD: show it while a reply is actually speaking (or
    // paused mid-reply), keep it up across the inter-track gap if it's already
    // showing and more is queued, and hide it otherwise. Suppressed while the
    // full deck popover is open so the two don't stack on the same anchor.
    private func updateHUD() {
        let d = Deck.shared
        // "Always visible" keeps the panel up as a persistent controller; either
        // way the full-deck popover suppresses it so they don't stack.
        let always = SettingsStore.shared.hudVisibility == .always && !popover.isShown
        let desired = !popover.isShown &&
            (always || d.isPlaying || d.isPausedMidItem || (MiniHUDController.shared.isVisible && d.hasQueued))
        MiniHUDController.shared.setDesiredVisible(desired, always: always, currentID: d.currentID, anchor: statusItem?.button)
    }

    func popoverDidShow(_ notification: Notification) { updateHUD() }
    func popoverDidClose(_ notification: Notification) { updateHUD() }

    // Left-click toggles the deck; right- or ctrl-click shows the menu.
    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        let e = NSApp.currentEvent
        if e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true {
            showMenu(sender)
        } else {
            togglePopover(sender)
        }
    }

    private func togglePopover(_ button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)   // so sliders/scrubber take clicks
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // Kept to 3 rows (4 with the update cue). A taller menu scrolled off the
    // top of short screens for one user, 2026-08-17 — so version, update and
    // feedback all moved into Settings ▸ About & support, and the menu's job
    // is now just Settings / Mute / Quit.
    private func showMenu(_ button: NSStatusBarButton) {
        let menu = NSMenu()
        // Mute first: it's the item reached for most often (Adam, 2026-08-18).
        let mute = NSMenuItem(title: Deck.shared.muted ? "Unmute" : "Mute",
                              action: #selector(toggleMute), keyEquivalent: "")
        mute.target = self
        menu.addItem(mute)
        menu.addItem(.separator())   // even spacing: Mute / Settings / Quit each get their own band
        let updBusy: Bool = {
            switch Updater.shared.phase {
            case .running, .relaunching: return true
            default: return false
            }
        }()
        let settingsTitle = Updater.shared.availableVersion == nil
            ? "Settings…" : (updBusy ? "Settings… (updating…)" : "Settings… (update available)")
        let settings = NSMenuItem(title: settingsTitle, action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit SpeakySpeak",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
    }

    @objc private func toggleMute() { Deck.shared.muted.toggle() }
    @objc private func openSettings() { SettingsWindowController.shared.show() }

    // The icon is the brand "Sy" mark (default) or the speaker status glyph.
    // Either way: a queue-count badge, an alpha pulse while playing, and a
    // resting opacity that codes muted/off (the tooltip states it exactly).
    private func refreshStatus() {
        guard let button = statusItem?.button else { return }
        let deck = Deck.shared

        // While playing, the pulse timer animates the icon (EQ bars) — leave the
        // image alone here so we don't fight it. Otherwise show the resting glyph.
        if !deck.isPlaying {
            if SettingsStore.shared.menuBarStyle == .sy {
                button.image = syGlyph
            } else {
                let symbol: String
                if !deck.enabled   { symbol = "speaker.slash.fill" }
                else if deck.muted { symbol = "speaker.fill" }
                else               { symbol = "speaker.wave.1.fill" }
                let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
                let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "SpeakySpeak")?
                    .withSymbolConfiguration(cfg)
                img?.isTemplate = true
                button.image = img
            }
        }

        let queued = deck.items.filter { $0.state == .queued }.count
        var title = queued > 0 ? " \(queued)" : ""
        var tip = stateTooltip(deck, queued: queued)
        // A waiting update gets a persistent ↑ next to the icon, so it's
        // visible without opening the menu; the tooltip says what to do.
        if let v = Updater.shared.availableVersion {
            title += " ↑"
            tip += "\nUpdate to \(v) available. Open Settings to install it."
        }
        button.title = title
        button.toolTip = tip

        if deck.isPlaying {
            startPulse()
        } else {
            stopPulse()
            button.alphaValue = !deck.enabled ? 0.35 : (deck.muted ? 0.55 : 1.0)
        }
    }

    private func stateTooltip(_ deck: Deck, queued: Int) -> String {
        let base: String
        if !deck.enabled      { base = "SpeakySpeak — speech off" }
        else if deck.isPlaying { base = "SpeakySpeak — playing" }
        else if deck.muted    { base = "SpeakySpeak — muted (queuing silently)" }
        else                  { base = "SpeakySpeak" }
        return queued > 0 ? "\(base) · \(queued) queued" : base
    }

    // Animated equalizer bars shown while a reply is playing, so the menu bar
    // visibly signals "talking now." Bars bounce on speech loudness (Deck.level)
    // with a per-bar phase offset so they keep moving through quiet passages.
    // Solid bars (full alpha) template-tint bright — unlike the thin Sy strokes.
    private func eqGlyph(level: Double, phase: CGFloat) -> NSImage {
        let barH = NSStatusBar.system.thickness
        let bars = 3
        let bw: CGFloat = 2.5, gap: CGFloat = 2.0
        let maxH = barH * 0.62
        let w = CGFloat(bars) * bw + CGFloat(bars - 1) * gap
        let img = NSImage(size: NSSize(width: ceil(w + 4), height: ceil(barH)))
        img.lockFocus()
        NSColor.black.setFill()   // template image → system tints to the bar's label color
        let drive = CGFloat(min(max(level, 0), 1))
        let x0 = (img.size.width - w) / 2
        for i in 0..<bars {
            let osc = 0.5 + 0.5 * sin(phase + CGFloat(i) * 2.1)        // 0…1, always moving
            let frac = 0.28 + 0.72 * osc * max(drive, 0.22)           // floor keeps motion alive
            let h = maxH * frac
            let x = x0 + CGFloat(i) * (bw + gap)
            let rect = NSRect(x: x, y: (barH - h) / 2, width: bw, height: h)
            NSBezierPath(roundedRect: rect, xRadius: bw / 2, yRadius: bw / 2).fill()
        }
        img.unlockFocus()
        img.isTemplate = true
        return img
    }

    private func startPulse() {
        guard pulseTimer == nil else { return }
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            guard let self, let button = self.statusItem?.button else { return }
            self.pulsePhase += 0.5
            button.alphaValue = 1.0
            button.image = self.eqGlyph(level: Deck.shared.level, phase: self.pulsePhase)
        }
    }

    private func stopPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
    }

    // The hook cold-starts the app with `open -g`; don't pop anything on reopen.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        return true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
