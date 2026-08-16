// Builds the SpeakySpeak icon assets from the exact hand-made mark in
// SyLogo.png (black tile + white Optima "Sy"). It lifts the white "Sy" into a
// transparent, tintable shape and emits two things:
//   • SyGlyph.png       — trimmed white-on-transparent "Sy" (menu-bar template)
//   • <out> 1024 master — that "Sy" centered on a black continuous-corner
//                         squircle (sliced into AppIcon.icns by make-icon.sh)
// Same letterforms in the menu bar and the Dock; no font dependency.
//
//   swift render-icon.swift [masterOut]
import AppKit

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let masterOut = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/SpeakyIcon-1024.png"
let glyphOut = here.appendingPathComponent("SyGlyph.png").path

// Load SyLogo.png into a known RGBA8 bitmap.
func loadRGBA(_ url: URL) -> NSBitmapImageRep {
    let img = NSImage(contentsOf: url)!
    let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    let w = cg.width, h = cg.height
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
    ctx.cgContext.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let src = loadRGBA(URL(fileURLWithPath: here.appendingPathComponent("SyLogo.png").path))
let W = src.pixelsWide, H = src.pixelsHigh
let srcData = src.bitmapData!
let bpr = src.bytesPerRow

// White "Sy" → opaque; black tile → transparent. Alpha = luminance, so the
// letters' antialiased edges stay smooth. Track the ink bounding box to trim.
let glyph = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: W * 4, bitsPerPixel: 32)!
let dst = glyph.bitmapData!
var minX = W, minY = H, maxX = 0, maxY = 0
for y in 0..<H {
    for x in 0..<W {
        let s = y * bpr + x * 4
        let lum = (Int(srcData[s]) + Int(srcData[s + 1]) + Int(srcData[s + 2])) / 3
        let d = y * (W * 4) + x * 4
        dst[d] = 255; dst[d + 1] = 255; dst[d + 2] = 255; dst[d + 3] = UInt8(lum)
        if lum > 24 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
    }
}
let cropW = maxX - minX + 1, cropH = maxY - minY + 1
let glyphImg = NSImage(size: NSSize(width: W, height: H))
glyphImg.addRepresentation(glyph)
let trimmed = NSImage(size: NSSize(width: cropW, height: cropH))
trimmed.lockFocus()
glyphImg.draw(at: .zero,
              from: NSRect(x: minX, y: H - maxY - 1, width: cropW, height: cropH),
              operation: .copy, fraction: 1)
trimmed.unlockFocus()

// Save the trimmed glyph (menu-bar template source).
if let tiff = trimmed.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
   let png = rep.representation(using: .png, properties: [:]) {
    try? png.write(to: URL(fileURLWithPath: glyphOut)); print("wrote \(glyphOut) (\(cropW)x\(cropH))")
}

// Compose the 1024 icon: black squircle + the white "Sy" centered, sized to
// ~56% of the canvas width (matching the source composition).
let S: CGFloat = 1024
let icon = NSImage(size: NSSize(width: S, height: S))
icon.lockFocus()
let rect = CGRect(x: 1, y: 1, width: S - 2, height: S - 2)
NSColor.black.setFill()
NSBezierPath(roundedRect: rect, xRadius: S * 0.2237, yRadius: S * 0.2237).fill()
let targetW = S * 0.56
let scale = targetW / CGFloat(cropW)
let drawW = CGFloat(cropW) * scale, drawH = CGFloat(cropH) * scale
trimmed.draw(in: NSRect(x: (S - drawW) / 2, y: (S - drawH) / 2 + S * 0.01,
                        width: drawW, height: drawH))
icon.unlockFocus()
if let tiff = icon.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
   let png = rep.representation(using: .png, properties: [:]) {
    try? png.write(to: URL(fileURLWithPath: masterOut)); print("wrote \(masterOut)")
}
