#!/usr/bin/env bash
#
# Baut iJIRA als Release. Falls ein "Developer ID Application"-Zertifikat
# vorhanden ist, wird zusätzlich signiert, notarisiert und das Ticket angeheftet.
# Ohne Zertifikat: ad-hoc-Build mit Warnung, kein Abbruch.
#
# Voraussetzungen für Notarisierung (einmalig):
#   1. "Developer ID Application"-Zertifikat in der Keychain
#      (Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application)
#   2. Notar-Zugangsdaten als Keychain-Profil "iJIRA-notary":
#        xcrun notarytool store-credentials iJIRA-notary \
#          --apple-id "<deine-apple-id>" --team-id 4W7DMXPNC2 \
#          --password "<app-spezifisches-passwort>"
#
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="iJIRA"
TEAM="4W7DMXPNC2"
PROFILE="iJIRA-notary"
BUILD_DIR=".build-release"
APP="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
ZIP="$BUILD_DIR/$APP_NAME.zip"

echo "==> Projekt generieren"
xcodegen generate

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
      -allowProvisioningUpdates clean build
else
    xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
      -derivedDataPath "$BUILD_DIR" \
      CODE_SIGN_IDENTITY="-" \
      CODE_SIGN_STYLE=Manual \
      clean build
fi

if [ "$HAS_CERT" = true ]; then
    echo "==> Signatur prüfen"
    codesign --verify --deep --strict --verbose=2 "$APP"

    echo "==> Zippen für Notar-Upload"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"

    echo "==> An Apple-Notardienst senden (wartet auf Ergebnis)"
    xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

    echo "==> Ticket anheften"
    xcrun stapler staple "$APP"

    echo "==> Gatekeeper-Bewertung"
    spctl -a -vvv --type execute "$APP" || true

    echo
    echo "✅ Fertig: $APP (signiert + notarisiert)"
else
    echo
    echo "✅ Fertig: $APP (ad-hoc, ohne Notarisierung)"
fi
