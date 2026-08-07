#!/usr/bin/env bash
#
# Baut das Distributions-Image: iJIRA.app neben einem /Applications-Alias,
# damit die App per Drag & Drop installiert wird (statt aus einem Zip heraus
# zu starten).
#
# Bevorzugt `create-dmg` (brew install create-dmg) — das setzt Fenstergröße
# und Icon-Positionen. Dafür braucht es allerdings Finder/AppleScript, was in
# SSH- oder gesperrten Sessions scheitert. In dem Fall (oder ohne das Tool)
# fällt das Skript auf ein schlichtes hdiutil-Image zurück: gleiche Funktion,
# nur ohne gesetztes Layout.
#
# Aufruf: scripts/make-dmg.sh <pfad/zur/iJIRA.app> <ziel.dmg>
#
set -euo pipefail

APP="${1:-}"
DMG="${2:-}"
VOLNAME="iJIRA"

if [ -z "$APP" ] || [ -z "$DMG" ]; then
    echo "Aufruf: scripts/make-dmg.sh <app> <dmg>" >&2
    exit 1
fi
if [ ! -d "$APP" ]; then
    echo "❌ App nicht gefunden: $APP" >&2
    exit 1
fi

rm -f "$DMG"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"

make_plain_dmg() {
    # Schlichtes, aber vollwertiges Image: App + Alias auf /Applications.
    ln -s /Applications "$STAGING/Applications"
    hdiutil create -volname "$VOLNAME" -srcfolder "$STAGING" \
        -ov -format UDZO "$DMG" >/dev/null
}

if command -v create-dmg >/dev/null 2>&1; then
    echo "==> DMG mit create-dmg"
    # create-dmg legt den /Applications-Alias selbst an (--app-drop-link).
    # Es liefert gelegentlich einen Exit-Code != 0, obwohl das Image entstanden
    # ist — deshalb wird unten das Ergebnis geprüft, nicht der Status.
    create-dmg \
        --volname "$VOLNAME" \
        --window-pos 200 120 \
        --window-size 600 400 \
        --icon-size 110 \
        --icon "$(basename "$APP")" 150 190 \
        --hide-extension "$(basename "$APP")" \
        --app-drop-link 450 190 \
        --no-internet-enable \
        "$DMG" "$STAGING" >/dev/null 2>&1 || true

    if [ ! -f "$DMG" ]; then
        echo "⚠️  create-dmg hat kein Image erzeugt (fehlt Finder/AppleScript?)."
        echo "    Fallback auf hdiutil ohne Layout."
        make_plain_dmg
    fi
else
    echo "==> DMG mit hdiutil (create-dmg nicht installiert)"
    echo "    Für ein Image mit gesetztem Layout: brew install create-dmg"
    make_plain_dmg
fi

if [ ! -f "$DMG" ]; then
    echo "❌ DMG konnte nicht erzeugt werden." >&2
    exit 1
fi

echo "✅ $DMG"
