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
ZIP="$BUILD_DIR/$APP_NAME.zip"

echo "==> Projekt generieren"
xcodegen generate

# Version aus Git: neuester Semver-Tag (Konvention: ohne v-Prefix) als
# Marketing-Version, Commit-Count als monoton steigende Build-Nummer.
# Überschreibt die Fallback-Werte aus project.yml — Releases können damit
# nicht mehr von den Tags driften.
VERSION="$(git describe --tags --abbrev=0 --match '[0-9]*.[0-9]*.[0-9]*' 2>/dev/null || echo "0.0.0")"
BUILD_NUMBER="$(git rev-list --count HEAD)"
echo "==> Version $VERSION (Build $BUILD_NUMBER)"

# Prüfen ob Developer ID-Zertifikat vorhanden ist
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
    HAS_CERT=true
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

    echo "==> Zippen für Notar-Upload"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"

    echo "==> An Apple-Notardienst senden (wartet auf Ergebnis)"
    RESULT=$(xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait | tee /dev/stderr)
    if ! echo "$RESULT" | grep -q "status: Accepted"; then
        SUBMISSION_ID=$(echo "$RESULT" | awk '/id:/ {print $2; exit}')
        echo "❌ Notarisierung fehlgeschlagen. Protokoll:"
        xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$PROFILE" || true
        exit 1
    fi

    echo "==> Ticket anheften"
    xcrun stapler staple "$APP"

    echo "==> Gatekeeper-Bewertung"
    spctl -a -vvv --type execute "$APP" || true

    # Zip mit gestapelter App erneuern — das ist die Datei zum Weitergeben
    # (Ticket inklusive, funktioniert damit auch offline).
    echo "==> Distributions-Zip erneuern"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"

    echo
    echo "✅ Fertig: $APP (signiert + notarisiert)"
    echo "   Weitergeben: $ZIP"
else
    echo "==> Zippen"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"

    echo
    echo "✅ Fertig: $ZIP (ad-hoc, ohne Notarisierung)"
fi
