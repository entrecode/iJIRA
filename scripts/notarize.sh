#!/usr/bin/env bash
#
# Baut iJIRA als Release. Falls ein "Developer ID Application"-Zertifikat
# vorhanden ist, wird zusätzlich signiert, notarisiert und das Ticket angeheftet.
# Ohne Zertifikat: ad-hoc-Build mit Warnung, kein Abbruch.
#
# Voraussetzungen für Notarisierung (einmalig):
#   1. "Developer ID Application"-Zertifikat in der Keychain
#      (CSR via Schlüsselbundverwaltung → Zertifikatsassistent, dann
#      developer.apple.com → Certificates → Developer ID Application)
#   2. Notar-Zugangsdaten als Keychain-Profil "ijira-notary":
#        xcrun notarytool store-credentials ijira-notary \
#          --apple-id "<deine-apple-id>" --team-id MAMAYY5H8H \
#          --password "<app-spezifisches-passwort>"
#
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="iJIRA"
TEAM="MAMAYY5H8H"
PROFILE="ijira-notary"
BUILD_DIR=".build-release"
APP="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"

echo "==> Projekt generieren"
xcodegen generate

# Version aus Git: neuester Semver-Tag (Konvention: ohne v-Prefix) als
# Marketing-Version, Commit-Count als monoton steigende Build-Nummer.
# Überschreibt die Fallback-Werte aus project.yml — Releases können damit
# nicht mehr von den Tags driften.
VERSION="$(git describe --tags --abbrev=0 --match '[0-9]*.[0-9]*.[0-9]*' 2>/dev/null || echo "0.0.0")"
BUILD_NUMBER="$(git rev-list --count HEAD)"
echo "==> Version $VERSION (Build $BUILD_NUMBER)"

# Versionierte Namen: die Enclosure-URL im appcast zeigt auf genau diese
# Dateinamen im GitHub-Release des passenden Tags.
ZIP="$BUILD_DIR/$APP_NAME-$VERSION.zip"
DMG="$BUILD_DIR/$APP_NAME-$VERSION.dmg"
NOTARIZE_ZIP="$BUILD_DIR/$APP_NAME-notarize.zip"

# Prüfen ob Developer ID-Zertifikat vorhanden ist
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
    HAS_CERT=true
    # Ein signiertes Release ohne Sparkle-Schlüssel wäre eine Sackgasse: die
    # ausgelieferte App könnte nie ein Update prüfen, und ein späteres
    # Nachrüsten erreicht die bereits installierten Kopien nicht mehr.
    if ! grep -qE '^ *SUPublicEDKey: *"[^"]+"' project.yml; then
        echo "❌ SUPublicEDKey fehlt in project.yml — erst scripts/sparkle-setup.sh laufen lassen." >&2
        exit 1
    fi
else
    HAS_CERT=false
    echo "⚠️  Kein 'Developer ID Application'-Zertifikat gefunden."
    echo "   Build wird ohne Signierung/Notarisierung fortgesetzt."
    echo "   Die .app läuft nur auf diesem Mac (Gatekeeper-Warnung auf anderen Macs)."
fi

echo "==> Release-Build"
if [ "$HAS_CERT" = true ]; then
    xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
      -derivedDataPath "$BUILD_DIR" \
      CODE_SIGN_STYLE=Manual \
      CODE_SIGN_IDENTITY="Developer ID Application" \
      DEVELOPMENT_TEAM="$TEAM" \
      ENABLE_HARDENED_RUNTIME=YES \
      OTHER_CODE_SIGN_FLAGS="--timestamp" \
      CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
      MARKETING_VERSION="$VERSION" \
      CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
      -allowProvisioningUpdates clean build
else
    xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
      -derivedDataPath "$BUILD_DIR" \
      CODE_SIGN_IDENTITY="-" \
      CODE_SIGN_STYLE=Manual \
      MARKETING_VERSION="$VERSION" \
      CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
      clean build
fi

if [ "$HAS_CERT" = true ]; then
    echo "==> Signatur prüfen"
    codesign --verify --deep --strict --verbose=2 "$APP"

    # Kleine Helfer, damit App und DMG denselben Weg gehen.
    notarize() {
        local file="$1"
        local result
        result=$(xcrun notarytool submit "$file" --keychain-profile "$PROFILE" --wait | tee /dev/stderr)
        if ! echo "$result" | grep -q "status: Accepted"; then
            local id
            id=$(echo "$result" | awk '/id:/ {print $2; exit}')
            echo "❌ Notarisierung fehlgeschlagen für $file. Protokoll:" >&2
            xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2 || true
            exit 1
        fi
    }

    echo "==> App zippen für Notar-Upload"
    rm -f "$NOTARIZE_ZIP"
    ditto -c -k --keepParent "$APP" "$NOTARIZE_ZIP"

    echo "==> App an Apple-Notardienst senden (wartet auf Ergebnis)"
    notarize "$NOTARIZE_ZIP"
    rm -f "$NOTARIZE_ZIP"

    echo "==> Ticket an die App heften"
    # Bewusst zusätzlich zum DMG-Stapling: so trägt die App das Ticket auch
    # dann bei sich, wenn sie aus dem Image herauskopiert weitergereicht wird.
    xcrun stapler staple "$APP"

    echo "==> Gatekeeper-Bewertung"
    spctl -a -vvv --type execute "$APP" || true

    # Zip aus der gestapelten App — das ist die Datei, die Sparkle lädt.
    echo "==> Update-Zip erzeugen"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"

    echo "==> DMG bauen"
    scripts/make-dmg.sh "$APP" "$DMG"

    echo "==> DMG signieren"
    codesign --force --sign "Developer ID Application" --timestamp "$DMG"

    echo "==> DMG notarisieren"
    notarize "$DMG"
    xcrun stapler staple "$DMG"

    echo
    echo "✅ Fertig: $APP (signiert + notarisiert)"
    echo "   Download für Menschen: $DMG"
    echo "   Sparkle-Update:        $ZIP"
else
    echo "==> Zippen"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"

    echo "==> DMG bauen (ohne Signatur/Notarisierung)"
    scripts/make-dmg.sh "$APP" "$DMG" || true

    echo
    echo "✅ Fertig: $ZIP (ad-hoc, ohne Notarisierung)"
fi
