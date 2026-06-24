#!/usr/bin/env bash
#
# Baut iJIRA als Release, signiert mit "Developer ID Application",
# notarisiert bei Apple und stapelt das Ticket an die .app.
#
# Voraussetzungen (einmalig):
#   1. "Developer ID Application"-Zertifikat in der Keychain
#      (Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application)
#   2. Notar-Zugangsdaten als Keychain-Profil "iJIRA-notary":
#        xcrun notarytool store-credentials iJIRA-notary \
#          --apple-id "<deine-apple-id>" --team-id 4W7DMXPNC2 \
#          --password "<app-spezifisches-passwort>"
#      (App-spezifisches Passwort: appleid.apple.com → Anmeldung & Sicherheit)
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

echo "==> Release-Build (Developer ID, Hardened Runtime, Timestamp)"
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  DEVELOPMENT_TEAM="$TEAM" \
  ENABLE_HARDENED_RUNTIME=YES \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  -allowProvisioningUpdates clean build

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
echo "Fertig: $APP"
echo "Diese .app läuft auf fremden Macs ohne Gatekeeper-Warnung."
