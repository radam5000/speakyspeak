#!/bin/bash
# Can the mini player still be dragged?
#
# macOS 27 stopped starting the AppKit background drag for the HUD panel, which
# froze the mini player in place (1.2.18). The drag is ours now, so this test
# pins it down the only way that survives the next OS: it lifts the REAL drag
# code out of main.swift (the block between the panel-drag sentinels), puts it
# on a panel with one marked control, dispatches synthetic mouse events through
# NSApp.sendEvent — the same path a real click takes — and checks where the
# panel ended up.
#
#   1. drag on the card background  -> panel moves by exactly the drag delta
#   2. drag on a .noWindowDrag() control -> panel does not move (that press
#      belongs to the button or the scrubber)
#   3. a 2pt shiver during a click  -> panel does not move
#
# No cursor is moved and no user app is touched: the events are synthesised and
# delivered to this test's own panel.
set -u
cd "$(dirname "$0")/.."
SRC=${DRAG_TEST_SRC:-main.swift}   # overridable so the test can be pointed at the pre-fix code
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

BLOCK=$(awk '/\/\/ <<<panel-drag/{f=1;next} /\/\/ panel-drag>>>/{f=0} f' "$SRC")
if [ -z "$BLOCK" ]; then
  echo "FAIL: could not find the panel-drag block in $SRC (sentinels moved?)"
  exit 1
fi

{
cat <<'HEAD'
import SwiftUI
import AppKit

// --- marker + card (mirrors the mini player's shape, not its looks) ---
final class NoWindowDragNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
}
struct NoWindowDrag: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NoWindowDragNSView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
extension View {
    func noWindowDrag() -> some View { background(NoWindowDrag()) }
}
struct Card: View {
    @State private var hovering = false
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)
        VStack(spacing: 8) {
            HStack { Text("session").font(.system(size: 12, weight: .semibold)); Spacer() }
            Button(action: {}) { Circle().frame(width: 32, height: 32) }
                .buttonStyle(.plain)
                .noWindowDrag()
            Color.gray.frame(height: 4).frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .frame(width: 264)
        .modifier(Surface(shape: shape))
        .padding(18)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
struct Surface: ViewModifier {
    let shape: RoundedRectangle
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.background(shape.fill(Color.white.opacity(0.34))).glassEffect(.clear, in: shape)
        } else {
            content.background(shape.fill(Color.white))
        }
    }
}

// --- the code under test, lifted verbatim from main.swift ---
HEAD
printf '%s\n' "$BLOCK"
cat <<'TAIL'

// --- harness ---
var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: String) {
    print((ok ? "  ok   " : "  FAIL ") + name + " — " + detail)
    if !ok { failures += 1 }
}

func markerCentreInWindow(_ view: NSView) -> NSPoint? {
    func find(_ v: NSView) -> NSView? {
        for sub in v.subviews {
            if sub is NoWindowDragNSView, sub.bounds.width > 0 { return sub }
            if let hit = find(sub) { return hit }
        }
        return nil
    }
    guard let m = find(view) else { return nil }
    return m.convert(NSPoint(x: m.bounds.midX, y: m.bounds.midY), to: nil)
}

// Drag the panel: press at `from` (window coords), then move the CURSOR by
// (dx,dy) in screen coords, as a real drag does — the window coords of each
// step are recomputed against wherever the panel has moved to.
func drag(_ p: NSPanel, from: NSPoint, dx: CGFloat, dy: CGFloat, steps: Int = 6) {
    let startScreen = p.convertPoint(toScreen: from)
    func send(_ type: NSEvent.EventType, _ screen: NSPoint) {
        let local = NSPoint(x: screen.x - p.frame.origin.x, y: screen.y - p.frame.origin.y)
        if let e = NSEvent.mouseEvent(with: type, location: local, modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: p.windowNumber, context: nil,
                                      eventNumber: Int.random(in: 1...999_999),
                                      clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) {
            NSApp.sendEvent(e)
        }
    }
    send(.leftMouseDown, startScreen)
    for i in 1...steps {
        let f = CGFloat(i) / CGFloat(steps)
        send(.leftMouseDragged, NSPoint(x: startScreen.x + dx * f, y: startScreen.y + dy * f))
    }
    send(.leftMouseUp, NSPoint(x: startScreen.x + dx, y: startScreen.y + dy))
}

final class Runner: NSObject, NSApplicationDelegate {
    var panel: NSPanel!
    func applicationDidFinishLaunching(_ n: Notification) {
        let h = ClickThroughHostingView(rootView: Card())
        let p = NSPanel(contentRect: NSRect(x: 500, y: 500, width: 300, height: 140),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.isMovableByWindowBackground = true
        p.contentView = h
        p.setFrame(NSRect(x: 500, y: 500, width: 300, height: max(120, h.fittingSize.height)), display: true)
        p.alphaValue = 0.01          // present and hit-testable, invisible on screen
        p.orderFrontRegardless()
        panel = p
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.run() }
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 20)
            print("  FAIL timeout — the harness hung (AppKit tracking loop?)")
            exit(1)
        }
    }
    func run() {
        guard let cv = panel.contentView else { exit(1) }
        let bg = NSPoint(x: 60, y: cv.bounds.maxY - 34)      // card background, title row
        let before = panel.frame.origin
        drag(panel, from: bg, dx: 70, dy: -45)
        let afterBG = panel.frame.origin
        check("background drag moves the panel",
              abs(afterBG.x - before.x - 70) < 0.5 && abs(afterBG.y - before.y + 45) < 0.5,
              "delta=(\(afterBG.x - before.x), \(afterBG.y - before.y)), wanted (70.0, -45.0)")

        if let ctrl = markerCentreInWindow(cv) {
            let b2 = panel.frame.origin
            drag(panel, from: ctrl, dx: 60, dy: 30)
            let a2 = panel.frame.origin
            check("drag on a .noWindowDrag() control leaves the panel put",
                  a2 == b2, "delta=(\(a2.x - b2.x), \(a2.y - b2.y)), wanted (0.0, 0.0)")
        } else {
            check("drag on a .noWindowDrag() control leaves the panel put", false,
                  "no marker view found in the hierarchy — the marker no longer reaches AppKit")
        }

        let b3 = panel.frame.origin
        drag(panel, from: bg, dx: 2, dy: 1, steps: 2)
        let a3 = panel.frame.origin
        check("a 2pt shiver stays a click", a3 == b3,
              "delta=(\(a3.x - b3.x), \(a3.y - b3.y)), wanted (0.0, 0.0)")

        exit(failures == 0 ? 0 : 1)
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let runner = Runner()
app.delegate = runner
app.run()
TAIL
} > "$TMP/dragtest.swift"

SDK=$(bash scripts/pick-sdk.sh) || exit 1
SDKFLAG=(); [ -n "$SDK" ] && SDKFLAG=(-sdk "$SDK")
echo "=== panel drag ==="
if ! swiftc ${SDKFLAG[@]+"${SDKFLAG[@]}"} -target "$(uname -m)-apple-macosx14.0" \
      "$TMP/dragtest.swift" -o "$TMP/dragtest" > "$TMP/build.log" 2>&1; then
  echo "FAIL: drag harness did not compile"
  tail -20 "$TMP/build.log"
  exit 1
fi
"$TMP/dragtest"
RC=$?
[ $RC -eq 0 ] && echo "PASS: mini player drags, controls still press" || echo "FAIL: mini player drag"
exit $RC
