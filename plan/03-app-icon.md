# M8 — App-Icon: drei Neon-Pfeilspitzen

## Ziel

Ein macOS-typisches Icon (Squircle, volle 1024er-Auflösung, alle Größen),
angelehnt an Jira: **drei ineinanderliegende Pfeilspitzen (Chevrons), die
nach oben rechts zeigen**, in grelleren Farben als das Atlassian-Blau —
Richtung Neonblau/Cyan, mit Glow.

## 1. Design-Spezifikation

- Hintergrund: dunkles Navy-Verlauf-Squircle (`#0B1020` → `#101A3A`,
  diagonal), damit die Neon-Farben leuchten. Corner-Radius: macOS-Standard
  (Squircle-Maske; bei programmatischem Zeichnen reicht
  `NSBezierPath(roundedRect:)` mit r = 0.2237 × Kantenlänge).
- Drei Chevrons (Pfeilspitzen ohne Schaft, wie „❯" um 45° gedreht →
  Spitze zeigt nach ↗), entlang der Diagonale von unten links nach oben
  rechts gestaffelt, Größe abnehmend nach innen/unten:
  - äußere/oberste: Neon-Cyan `#00E5FF`
  - mittlere: Azur `#2E8CFF`
  - innere/unterste: Indigo `#5A6CFF`
  - jeweils mit weichem Outer-Glow (gleiche Farbe, Alpha 0.55,
    Blur ≈ 6 % der Kantenlänge) — „Neonröhren"-Look.
- Strichform: gefüllte Polygone (nicht Stroke), Schenkelbreite ≈ 12 % der
  Kantenlänge, Schenkelwinkel 90°, Spitzen leicht gerundet
  (`lineJoin .round` beim Pfad-Fill via Stroke-Trick oder Pfad mit
  Rundungen).
- Menüleisten-Icon (Template-Bell) bleibt unverändert — das App-Icon
  betrifft Dock, Cmd-Tab, Finder, Über-Dialog.

Geometrie eines Chevrons (Einheitsquadrat, Zentrum `c`, Größe `s`):
```
Pfeilspitze ↗ = zwei Schenkel von der Spitze P = c + (0.5s, 0.5s)·↗
  Schenkel A Richtung ↖ (nach links oben hinten): P → P + s·(-1, 0)…
Praktisch: Chevron als „>"-Polygon konstruieren und um -45° rotieren.
```

## 2. Generierung — `scripts/generate-icon.swift`

Ein selbständiges Swift-Skript (läuft mit `swift scripts/generate-icon.swift`),
zeichnet mit CoreGraphics offscreen und schreibt `AppIcon.iconset`:

```swift
#!/usr/bin/env swift
import AppKit

let sizes: [(Int, Int)] = [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)]
// pro Eintrag: icon_{pt}x{pt}[@2x].png mit Pixelgröße pt*scale

func drawIcon(px: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: px, height: px))
    image.lockFocus()
    defer { image.unlockFocus() }
    guard let ctx = NSGraphicsContext.current?.cgContext else { return image }

    // 1) Squircle-Hintergrund mit Verlauf
    let inset = px * 0.05                       // macOS-Icon-Grid: Rand frei lassen
    let rect = CGRect(x: inset, y: inset, width: px - 2*inset, height: px - 2*inset)
    let bg = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.2237, yRadius: rect.width * 0.2237)
    bg.addClip()
    let gradient = NSGradient(colors: [NSColor(hex: 0x0B1020), NSColor(hex: 0x101A3A)])!
    gradient.draw(in: bg, angle: 60)

    // 2) drei Chevrons ↗ mit Glow
    let colors: [UInt32] = [0x5A6CFF, 0x2E8CFF, 0x00E5FF]   // innen → außen
    for (i, hex) in colors.enumerated() {
        let t = CGFloat(i)                       // 0,1,2
        let size = rect.width * (0.30 + 0.13 * t)         // wachsend nach außen
        let offset = rect.width * (-0.16 + 0.16 * t)      // Staffelung ↗
        let center = CGPoint(x: rect.midX + offset, y: rect.midY + offset)
        let path = chevronPath(center: center, size: size, thickness: rect.width * 0.115)
        ctx.setShadow(offset: .zero, blur: px * 0.06,
                      color: NSColor(hex: hex).withAlphaComponent(0.55).cgColor)
        NSColor(hex: hex).setFill()
        path.fill()
    }
    return image
}

func chevronPath(center: CGPoint, size: CGFloat, thickness: CGFloat) -> NSBezierPath {
    // „>"-Chevron bauen, dann um -45° um center rotieren → Spitze ↗
    // Polygon: äußere Spitze, zwei Schenkel-Enden, innere Spitze …
    // (lineJoinStyle = .round; alternativ Stroke mit .round + Konvertierung)
}
```

Danach:
```bash
iconutil -c icns AppIcon.iconset -o iJIRA/Resources/AppIcon.icns
rm -r AppIcon.iconset
```
(Das Skript soll beides selbst erledigen; Ausgabepfad als Argument,
Default `iJIRA/Resources/AppIcon.icns`.)

## 3. Projekt-Integration (xcodegen)

`project.yml`:
```yaml
targets:
  iJIRA:
    sources:
      - path: iJIRA
      # Resources werden von xcodegen automatisch als Ressourcen erkannt,
      # .icns unter iJIRA/Resources/ landet im Bundle.
    info:
      properties:
        CFBundleIconFile: AppIcon        # ohne .icns-Endung
```
- Verifizieren: `.icns` erscheint in `iJIRA.app/Contents/Resources/`,
  Dock-Icon nach Policy-Wechsel (M5) sichtbar; ggf. Finder-Icon-Cache
  (`killall Dock`) für den Test.
- Icon-Feinschliff ist iterativ: Skript rendert zusätzlich ein 256er-PNG
  nach `/tmp/ijira-icon-preview.png` — per `Read`-Tool begutachtbar,
  Parameter (Farben, Staffelung, Glow) oben im Skript als Konstanten.

## 4. Verifikation

- `swift scripts/generate-icon.swift && ls -la iJIRA/Resources/AppIcon.icns`
- Build → `.app/Contents/Resources/AppIcon.icns` vorhanden,
  `defaults read` der Info.plist zeigt CFBundleIconFile.
- Optik: Preview-PNG in 256/1024 prüfen (Kontrast auf hellem + dunklem
  Dock-Hintergrund).
