#!/usr/bin/env bash
#
# Release-Ritual: Changelog finalisieren, Version in project.yml bumpen,
# committen, taggen (Semver ohne v-Prefix) und notarize.sh anstoßen.
# notarize.sh injiziert Version/Build zusätzlich aus Git — project.yml dient
# damit nur noch als Fallback für lokale Xcode-Builds und kann nicht driften.
#
# Voraussetzung: CHANGELOG.md hat unter "## [Unreleased]" Einträge — die
# werden zum Abschnitt der neuen Version und zu den GitHub-Release-Notes.
#
# Aufruf: scripts/release.sh 1.0.3
#
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Aufruf: scripts/release.sh <major.minor.patch>   (z. B. 1.0.3)" >&2
    exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
    echo "❌ Working Tree ist nicht sauber — bitte erst committen/stashen." >&2
    exit 1
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$BRANCH" != "main" ]; then
    echo "❌ Releases werden von main getaggt (aktuell: $BRANCH)." >&2
    exit 1
fi

if git rev-parse -q --verify "refs/tags/$VERSION" >/dev/null; then
    echo "❌ Tag $VERSION existiert bereits." >&2
    exit 1
fi

LAST="$(git describe --tags --abbrev=0 --match '[0-9]*.[0-9]*.[0-9]*' 2>/dev/null || echo "")"

# Changelog: Unreleased-Sektion muss Einträge haben.
UNRELEASED="$(awk '/^## \[Unreleased\]/{flag=1; next} /^## \[/{flag=0} flag' CHANGELOG.md)"
if ! echo "$UNRELEASED" | grep -q '^- \|^  '; then
    echo "❌ CHANGELOG.md hat keine Einträge unter '## [Unreleased]'." >&2
    echo "   Bitte Release-Notes dort eintragen und erneut starten." >&2
    exit 1
fi

echo "==> Release $VERSION (letzter Tag: ${LAST:-—})"
echo
echo "Release-Notes (aus CHANGELOG.md, Unreleased):"
echo "$UNRELEASED"
echo

# Deployte Konvention: Zeitzone immer explizit (Europe/Berlin).
TODAY="$(TZ=Europe/Berlin date +%F)"

# Unreleased → Versions-Abschnitt, frische Unreleased-Sektion darüber,
# Compare-Links aktualisieren.
awk -v ver="$VERSION" -v today="$TODAY" -v last="$LAST" '
    /^## \[Unreleased\]/ {
        print "## [Unreleased]"
        print ""
        print "## [" ver "] – " today
        next
    }
    /^\[Unreleased\]: / {
        print "[Unreleased]: https://github.com/entrecode/iJIRA/compare/" ver "...HEAD"
        if (last != "") {
            print "[" ver "]: https://github.com/entrecode/iJIRA/compare/" last "..." ver
        } else {
            print "[" ver "]: https://github.com/entrecode/iJIRA/releases/tag/" ver
        }
        next
    }
    { print }
' CHANGELOG.md > CHANGELOG.md.tmp && mv CHANGELOG.md.tmp CHANGELOG.md

sed -i '' -E "s/^( *MARKETING_VERSION:).*/\1 \"$VERSION\"/" project.yml

git diff project.yml CHANGELOG.md

read -r -p "Bump committen, Tag $VERSION setzen und Release bauen? [y/N] " answer
if [[ "$answer" != [yY] ]]; then
    git checkout -- project.yml CHANGELOG.md
    echo "Abgebrochen — project.yml und CHANGELOG.md zurückgesetzt."
    exit 1
fi

git add project.yml CHANGELOG.md
git commit -m "release: $VERSION"
git tag "$VERSION"

echo "==> Build + Notarisierung"
scripts/notarize.sh

# Notes der neuen Version für das GitHub-Release extrahieren.
NOTES_FILE=".build-release/RELEASE_NOTES.md"
awk -v ver="$VERSION" '
    $0 ~ "^## \\[" ver "\\]" {flag=1; next}
    /^## \[/{flag=0}
    /^\[/{flag=0}
    flag
' CHANGELOG.md > "$NOTES_FILE"

echo
echo "✅ Release $VERSION getaggt und gebaut."
echo
echo "Jetzt veröffentlichen:"
echo "  git push && git push origin $VERSION"
echo "  gh release create $VERSION .build-release/iJIRA.zip \\"
echo "    --title \"iJIRA $VERSION\" --notes-file $NOTES_FILE"
