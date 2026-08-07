#!/usr/bin/env bash
#
# Erzeugt appcast.xml (Sparkle-Update-Feed) aus dem Release-Zip.
#
# Der Feed enthält bewusst nur den NEUESTEN Eintrag: Sparkle braucht für das
# Update nicht mehr, und so muss über Releases hinweg kein Archiv-Verzeichnis
# gepflegt werden. Preis dafür ist, dass Sparkle keine „was ist seit deiner
# Version passiert"-Historie anzeigen kann — für den Sprung auf die aktuelle
# Version ist das ohne Belang.
#
# Die Enclosure-URL zeigt auf das Asset des GitHub-Releases zum passenden Tag;
# einen eigenen Updateserver gibt es nicht.
#
# Aufruf: scripts/make-appcast.sh <version> [pfad/zu/release-notes.md]
#
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
NOTES="${2:-}"
BUILD_DIR=".build-release"
ZIP="$BUILD_DIR/iJIRA-$VERSION.zip"
REPO="entrecode/iJIRA"

if [ -z "$VERSION" ]; then
    echo "Aufruf: scripts/make-appcast.sh <version> [release-notes.md]" >&2
    exit 1
fi
if [ ! -f "$ZIP" ]; then
    echo "❌ $ZIP fehlt — erst scripts/notarize.sh laufen lassen." >&2
    exit 1
fi

GENERATE_APPCAST="$(find "$BUILD_DIR/SourcePackages/artifacts" .build/SourcePackages/artifacts \
    -name generate_appcast -type f 2>/dev/null | head -1)"
if [ -z "$GENERATE_APPCAST" ]; then
    echo "❌ generate_appcast nicht gefunden (Sparkle-Package nicht aufgelöst?)." >&2
    exit 1
fi

# Frisches Staging-Verzeichnis: generate_appcast würde einen dort liegenden
# appcast fortschreiben — so entsteht deterministisch ein Ein-Eintrag-Feed.
STAGING="$BUILD_DIR/appcast-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp "$ZIP" "$STAGING/"

# Gleichnamige .md-Datei neben dem Archiv wird von generate_appcast als
# Release-Notes übernommen.
if [ -n "$NOTES" ] && [ -f "$NOTES" ]; then
    cp "$NOTES" "$STAGING/iJIRA-$VERSION.md"
fi

echo "==> appcast.xml erzeugen (Version $VERSION)"
echo "    (Die Keychain fragt ggf. nach dem Sparkle-Signaturschlüssel.)"
"$GENERATE_APPCAST" \
    --download-url-prefix "https://github.com/$REPO/releases/download/$VERSION/" \
    --link "https://github.com/$REPO" \
    --embed-release-notes \
    -o appcast.xml \
    "$STAGING"

if ! grep -q "sparkle:edSignature" appcast.xml; then
    echo "❌ appcast.xml enthält keine Signatur — Schlüssel in der Keychain?" >&2
    exit 1
fi

echo "✅ appcast.xml geschrieben"
echo "   Muss mit nach main gepusht werden — die App liest ihn von"
echo "   https://raw.githubusercontent.com/$REPO/main/appcast.xml"
