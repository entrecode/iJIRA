#!/usr/bin/env bash
#
# Einmalige Sparkle-Einrichtung: EdDSA-Schlüsselpaar erzeugen (bzw. das
# vorhandene verwenden) und den öffentlichen Teil als SUPublicEDKey in
# project.yml eintragen.
#
# ⚠️  Der PRIVATE Schlüssel liegt in der Login-Keychain ("Private key for
#     signing Sparkle updates"). Geht er verloren, akzeptiert KEINE bereits
#     installierte iJIRA je wieder ein Update — dann hilft nur noch eine
#     manuelle Neuinstallation bei allen Nutzern. Also nach dem ersten Lauf
#     exportieren (siehe Hinweis am Ende) und sicher ablegen.
#
set -euo pipefail
cd "$(dirname "$0")/.."

# Sparkle-Tools liegen im aufgelösten SPM-Artefakt. Das ist erst nach einem
# Package-Resolve da — deshalb notfalls anstoßen.
find_tool() {
    find .build/SourcePackages/artifacts .build-release/SourcePackages/artifacts \
        -name "$1" -type f 2>/dev/null | head -1
}

if [ -z "$(find_tool generate_keys)" ]; then
    echo "==> Sparkle-Package auflösen"
    xcodegen generate
    xcodebuild -project iJIRA.xcodeproj -scheme iJIRA \
        -derivedDataPath .build -resolvePackageDependencies >/dev/null
fi

GENERATE_KEYS="$(find_tool generate_keys)"
if [ -z "$GENERATE_KEYS" ]; then
    echo "❌ generate_keys nicht gefunden — ist Sparkle als Package eingebunden?" >&2
    exit 1
fi

echo "==> Schlüssel erzeugen bzw. vorhandenen lesen"
echo "    (Die Keychain fragt ggf. nach Erlaubnis — bitte bestätigen.)"
OUTPUT="$("$GENERATE_KEYS" 2>&1)"

# generate_keys gibt den Public Key im Info.plist-Schnipsel aus:
#   <key>SUPublicEDKey</key>
#   <string>…base64…</string>
PUBLIC_KEY="$(echo "$OUTPUT" | grep -A1 "SUPublicEDKey" | grep "<string>" \
    | sed -E 's|.*<string>(.*)</string>.*|\1|' | head -1)"

if [ -z "$PUBLIC_KEY" ]; then
    echo "❌ Public Key konnte nicht aus der Ausgabe gelesen werden:" >&2
    echo "$OUTPUT" >&2
    exit 1
fi

echo "==> SUPublicEDKey in project.yml eintragen"
# Nur die SUPublicEDKey-Zeile ersetzen (beliebiger bisheriger Wert).
sed -i '' -E "s|^( *SUPublicEDKey:).*|\1 \"$PUBLIC_KEY\"|" project.yml

if ! grep -q "SUPublicEDKey: \"$PUBLIC_KEY\"" project.yml; then
    echo "❌ Eintrag in project.yml fehlgeschlagen — bitte manuell setzen:" >&2
    echo "   SUPublicEDKey: \"$PUBLIC_KEY\"" >&2
    exit 1
fi

xcodegen generate >/dev/null
echo
echo "✅ Sparkle eingerichtet."
echo "   Public Key: $PUBLIC_KEY"
echo
echo "⚠️  PRIVATEN SCHLÜSSEL JETZT SICHERN:"
echo "   $GENERATE_KEYS -x sparkle-private-key.txt"
echo "   → Datei in den Passwortmanager, danach lokal löschen."
echo "   Ohne dieses Backup ist die Update-Kette bei Keychain-Verlust tot."
