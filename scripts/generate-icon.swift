#!/usr/bin/env swift
// Erzeugt das iJIRA-App-Icon: drei ineinanderliegende Neon-Pfeilspitzen (↗)
// auf dunklem Squircle. Ausgabe: AppIcon.icns (+ Preview-PNGs unter /tmp).
//
//   swift scripts/generate-icon.swift [ausgabe.icns]
//
// Design-Konstanten stehen gesammelt unten in `Design` — für Iterationen.

import AppKit

// MARK: - Design-Konstanten

enum Design {
    // Hintergrund-Verlauf (dunkles Navy, damit Neon leuchtet)
    static let backgroundTop: UInt32 = 0x101A3A
    static let backgroundBottom: UInt32 = 0x0B1020

    // Chevrons von innen/unten nach außen/oben
    static let chevronColors: [UInt32] = [0x5A6CFF, 0x2E8CFF, 0x00E5FF]
    /// Tip-Position entlang der ↗-Diagonale (Anteil der Icon-Breite)
    static let chevronOffsets: [CGFloat] = [-0.06, 0.12, 0.30]
    /// Armlänge (Anteil der Icon-Breite)
    static let chevronLengths: [CGFloat] = [0.26, 0.33, 0.40]
    /// Strichstärke (Anteil der Icon-Breite)
    static let thickness: CGFloat = 0.105
    /// Glow-Radius (Anteil der Icon-Breite)
    static let glow: CGFloat = 0.055
    /// Squircle: freier Rand + Eckradius (macOS-Grid)
    static let margin: CGFloat = 0.05
    static let cornerRadius: CGFloat = 0.2237
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

// MARK: - Zeichnen

func draw(px: CGFloat) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    ctx.clear(CGRect(x: 0, y: 0, width: px, height: px))

    // Squircle-Hintergrund
    let inset = px * Design.margin
    let rect = CGRect(x: inset, y: inset, width: px - 2 * inset, height: px - 2 * inset)
    let radius = rect.width * Design.cornerRadius
    let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    NSGraphicsContext.current?.saveGraphicsState()
    squircle.addClip()
    NSGradient(colors: [NSColor(hex: Design.backgroundTop),
                        NSColor(hex: Design.backgroundBottom)])?
        .draw(in: rect, angle: -60)

    // Drei Chevrons ↗ — Polyline (links-Ende → Spitze → unten-Ende),
    // runde Kappen, Neon-Glow via Schatten in Strichfarbe.
    let w = rect.width
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let diag = CGPoint(x: 0.7071, y: 0.7071)

    for index in 0..<Design.chevronColors.count {
        let color = NSColor(hex: Design.chevronColors[index])
        let offset = w * Design.chevronOffsets[index]
        let length = w * Design.chevronLengths[index]
        let tip = CGPoint(x: center.x + diag.x * offset,
                          y: center.y + diag.y * offset)

        let path = NSBezierPath()
        path.move(to: CGPoint(x: tip.x - length, y: tip.y))   // Arm nach links
        path.line(to: tip)                                     // Spitze ↗
        path.line(to: CGPoint(x: tip.x, y: tip.y - length))    // Arm nach unten
        path.lineWidth = w * Design.thickness
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        let shadow = NSShadow()
        shadow.shadowColor = color.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = px * Design.glow
        shadow.shadowOffset = .zero
        NSGraphicsContext.current?.saveGraphicsState()
        shadow.set()
        color.setStroke()
        path.stroke()
        // Zweiter Strich ohne Schatten → kräftiger Kern über dem Glow
        NSGraphicsContext.current?.restoreGraphicsState()
        color.setStroke()
        path.stroke()
    }

    NSGraphicsContext.current?.restoreGraphicsState()
}

func render(px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(px: CGFloat(px))
    NSGraphicsContext.current?.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, to url: URL) {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("PNG-Encoding fehlgeschlagen: \(url.lastPathComponent)")
    }
    try! data.write(to: url)
}

// MARK: - Main

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "iJIRA/Resources/AppIcon.icns"
let outputURL = URL(fileURLWithPath: outputPath)

let fm = FileManager.default
let iconsetURL = fm.temporaryDirectory.appendingPathComponent("iJIRA-AppIcon.iconset")
try? fm.removeItem(at: iconsetURL)
try! fm.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

// Alle macOS-Icon-Größen
let entries: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
    (256, 1), (256, 2), (512, 1), (512, 2),
]
for entry in entries {
    let px = entry.points * entry.scale
    let suffix = entry.scale == 2 ? "@2x" : ""
    let name = "icon_\(entry.points)x\(entry.points)\(suffix).png"
    writePNG(render(px: px), to: iconsetURL.appendingPathComponent(name))
}

// Previews für die visuelle Kontrolle
writePNG(render(px: 256), to: URL(fileURLWithPath: "/tmp/ijira-icon-preview.png"))
writePNG(render(px: 1024), to: URL(fileURLWithPath: "/tmp/ijira-icon-preview-1024.png"))

// .icns bauen
try? fm.createDirectory(at: outputURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
try! iconutil.run()
iconutil.waitUntilExit()
try? fm.removeItem(at: iconsetURL)

guard iconutil.terminationStatus == 0 else {
    fatalError("iconutil fehlgeschlagen (\(iconutil.terminationStatus))")
}
print("OK: \(outputURL.path) + /tmp/ijira-icon-preview.png")
