import AppKit
import SwiftUI

/// Transparenz von Fenster-Hintergrund und Panels.
///
/// Die Werte sind fest — sie wurden mit einem temporären Regler am echten
/// Fenster ermittelt und sind das Ergebnis davon.
enum Appearance {
    /// Panels sind 10 % durchscheinender als ihre Design-Deckkraft. Bewusst
    /// deutlich weniger als der Hintergrund: darüber steht Text, der lesbar
    /// bleiben muss.
    static let panelTransparency = 0.1

    static func panelOpacity(base: Double) -> Double {
        base * (1 - panelTransparency)
    }
}

// MARK: - Fenster-Hintergrund

/// Frosted-Backdrop hinter dem Fensterinhalt. Setzt nicht-opake Fenster
/// voraus — siehe `NSWindow.applyTransparentBackdrop()`.
struct WindowBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        // `.titlebar` ist das dünnste System-Material: der Desktop scheint
        // deutlich stärker durch als bei `.sidebar`, wird aber genauso
        // verwischt. Die Unschärfe ist der Punkt — ein einfach nur
        // durchsichtiges Fenster (etwa über `alphaValue`) zeigt den Hintergrund
        // gestochen scharf und sieht nicht nach Glas aus.
        view.material = .titlebar
        view.blendingMode = .behindWindow
        // Bewusst `.active` statt `.followsWindowActiveState`: letzteres
        // schaltet bei inaktivem Fenster auf das flache, deckende
        // „inactive"-Aussehen des Materials um — der Glas-Effekt verschwand
        // also, sobald ein anderes Fenster nach vorn kam.
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

extension NSWindow {
    /// Lässt den durchscheinenden Backdrop den Desktop zeigen statt der grauen
    /// Fenster-Hintergrundfarbe.
    func applyTransparentBackdrop() {
        isOpaque = false
        backgroundColor = .clear
    }
}

// MARK: - Panels

extension View {
    /// Hintergrund einer abgesetzten Fläche. `base` ist die im Design gewählte
    /// Deckkraft; `Appearance` dämpft sie einheitlich, sodass die relativen
    /// Abstufungen zwischen den Panels erhalten bleiben.
    func panelFill<Style: ShapeStyle, ClipShape: Shape>(_ style: Style,
                                                        base: Double,
                                                        in shape: ClipShape) -> some View {
        background(style.opacity(Appearance.panelOpacity(base: base)), in: shape)
    }
}
