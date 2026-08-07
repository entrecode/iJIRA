#!/usr/bin/env swift
// Erzeugt das Social-Preview-Bild für GitHub (1280×640) — das Bild, das statt
// des Organisations-Avatars erscheint, wenn jemand einen Repo-Link teilt.
// Gleiche Bildsprache wie das App-Icon: Neon-Chevrons auf dunklem Navy.
//
//   swift scripts/generate-social-preview.swift [ausgabe.png]
//
// GitHub nimmt das Bild nur über die Weboberfläche entgegen (es gibt dafür
// keine API): Repo → Settings → General → Social preview → Edit → Upload.

import AppKit

enum Design {
    static let backgroundTop: UInt32 = 0x101A3A
    static let backgroundBottom: UInt32 = 0x0B1020
    static let chevronColors: [UInt32] = [0x5A6CFF, 0x2E8CFF, 0x00E5FF]
    static let chevronOffsets: [CGFloat] = [-0.06, 0.12, 0.30]
    static let chevronLengths: [CGFloat] = [0.26, 0.33, 0.40]
    static let thickness: CGFloat = 0.105
    static let glow: CGFloat = 0.055

    static let title = "iJIRA"
    static let subtitle = "JIRA als Messenger — nativ für den Mac"
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

/// Chevron-Marke aus dem App-Icon, in ein quadratisches Feld gezeichnet.
func drawMark(in box: CGRect) {
    let w = box.width
    let center = CGPoint(x: box.midX, y: box.midY)
    let diag = CGPoint(x: 0.7071, y: 0.7071)

    for index in 0..<Design.chevronColors.count {
        let color = NSColor(hex: Design.chevronColors[index])
        let offset = w * Design.chevronOffsets[index]
        let length = w * Design.chevronLengths[index]
        let tip = CGPoint(x: center.x + diag.x * offset,
                          y: center.y + diag.y * offset)

        let path = NSBezierPath()
        path.move(to: CGPoint(x: tip.x - length, y: tip.y))
        path.line(to: tip)
        path.line(to: CGPoint(x: tip.x, y: tip.y - length))
        path.lineWidth = w * Design.thickness
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        let shadow = NSShadow()
        shadow.shadowColor = color.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = w * Design.glow
        shadow.shadowOffset = .zero
        NSGraphicsContext.current?.saveGraphicsState()
        shadow.set()
        color.setStroke()
        path.stroke()
        NSGraphicsContext.current?.restoreGraphicsState()
        color.setStroke()
        path.stroke()
    }
}

func draw(width: CGFloat, height: CGFloat) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    let rect = CGRect(x: 0, y: 0, width: width, height: height)
    ctx.clear(rect)

    // Vollflächiger Verlauf — anders als beim App-Icon ohne Squircle, GitHub
    // beschneidet das Bild selbst.
    NSGradient(colors: [NSColor(hex: Design.backgroundTop),
                        NSColor(hex: Design.backgroundBottom)])?
        .draw(in: rect, angle: -60)

    // Marke links, Text rechts daneben.
    let markSize = height * 0.52
    let markBox = CGRect(x: width * 0.10,
                         y: (height - markSize) / 2,
                         width: markSize, height: markSize)
    drawMark(in: markBox)

    let textLeft = markBox.maxX + width * 0.06
    let titleFont = NSFont.systemFont(ofSize: height * 0.17, weight: .bold)
    let subtitleFont = NSFont.systemFont(ofSize: height * 0.058, weight: .regular)

    let title = NSAttributedString(string: Design.title, attributes: [
        .font: titleFont,
        .foregroundColor: NSColor.white,
    ])
    let subtitle = NSAttributedString(string: Design.subtitle, attributes: [
        .font: subtitleFont,
        .foregroundColor: NSColor(hex: 0x9FB2D9),
    ])

    // Beide Zeilen als Block vertikal zentrieren.
    let gap = height * 0.035
    let blockHeight = title.size().height + gap + subtitle.size().height
    var y = (height + blockHeight) / 2 - title.size().height
    title.draw(at: CGPoint(x: textLeft, y: y))
    y -= gap + subtitle.size().height
    subtitle.draw(at: CGPoint(x: textLeft, y: y))
}

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "/tmp/ijira-social-preview.png"

// GitHubs empfohlene Größe; wird in der Vorschau auf 1280×640 dargestellt.
let width = 1280, height = 640
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: width, height: height)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
draw(width: CGFloat(width), height: CGFloat(height))
NSGraphicsContext.current?.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else {
    fatalError("PNG-Encoding fehlgeschlagen")
}
try! data.write(to: URL(fileURLWithPath: outputPath))
print("OK: \(outputPath) (\(width)×\(height))")
