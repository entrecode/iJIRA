# iJIRA

Native macOS-App, die die wichtigsten JIRA-Funktionen messenger-artig auf den Mac bringt.

## Download

**[Neueste Version herunterladen](../../releases/latest)** — notarisierte `.app`, läuft ohne Gatekeeper-Warnung.

Entpacken, in `/Applications` verschieben, starten. Änderungen pro Version: [CHANGELOG.md](CHANGELOG.md).

## Features

- **JIRA-Notifications**: Direkte Notifications (neue Kommentare, Zuweisungen, Mentions) in einer Messenger-artigen Timeline.
- **Antworten**: Kommentare direkt aus der App verfassen, mit Markdown-Support (`code`, Code-Blöcke, **fett**, *kursiv*).
- **macOS Integration**: Automatische Aktualisierung mit echten macOS-Push-Benachrichtigungen (Notification Center) und Menüleisten-Icon mit Badge.
- **Leichtgewichtig**: Hybrid-App mit AppKit (`NSStatusItem`, `NSPopover`) für die Hülle und SwiftUI für die Inhalte.

## Entwicklung

Dieses Projekt verwendet [XcodeGen](https://github.com/yonaskolb/XcodeGen), um die Xcode-Projektdatei (`.xcodeproj`) aus der `project.yml` zu generieren. Die `.xcodeproj` ist Wegwerf-Artefakt — Änderungen an Targets/Settings gehören in die `project.yml`.

### Voraussetzungen

- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- Xcode (macOS 14.0+)
- Für Releases zusätzlich: „Developer ID Application“-Zertifikat, Notar-Profil `ijira-notary` (Details im Kopf von `scripts/notarize.sh`) und die [GitHub CLI](https://cli.github.com) (`brew install gh`)

### Lokal bauen und starten

```bash
xcodegen generate      # nach jedem Ändern der project.yml erneut ausführen
open iJIRA.xcodeproj   # dann in Xcode: ⌘R
```

Lokale Builds tragen die Fallback-Version aus der `project.yml`. Die echte Version bekommen erst Release-Builds — abgeleitet aus dem neuesten Git-Tag (Marketing-Version) und der Commit-Anzahl (Build-Nummer, sichtbar in Einstellungen und „Über iJIRA“).

## Releaseprozess

Versionen folgen SemVer, Git-Tags **ohne** v-Präfix (`1.0.3`, nicht `v1.0.3`).

**Während der Entwicklung:** Nennenswerte Änderungen in der [CHANGELOG.md](CHANGELOG.md) unter `## [Unreleased]` sammeln — das werden die Release-Notes.

**Release veröffentlichen:**

```bash
# 1. Release bauen: prüft Changelog, bumpt project.yml, committet,
#    taggt und ruft notarize.sh auf (fragt vor dem Commit nach)
scripts/release.sh 1.0.3

# 2. Veröffentlichen (Befehle gibt release.sh am Ende auch selbst aus):
git push && git push origin 1.0.3
gh release create 1.0.3 .build-release/iJIRA.zip \
  --title "iJIRA 1.0.3" --notes-file .build-release/RELEASE_NOTES.md
```

Alternativ zum `gh`-Befehl lässt sich das Release auf der GitHub-Seite anlegen: [Releases → „Draft a new release“](../../releases/new), den frisch gepushten Tag wählen, Notes aus `.build-release/RELEASE_NOTES.md` (bzw. dem neuen CHANGELOG-Abschnitt) einfügen und `.build-release/iJIRA.zip` als Asset hochladen.

### Wann welches Script?

| Script | Zweck | Wann |
| --- | --- | --- |
| `scripts/release.sh <version>` | Kompletter Release: Changelog finalisieren, Version bumpen, Commit + Tag, dann Build via notarize.sh | Immer, wenn eine neue Version erscheint |
| `scripts/notarize.sh` | Nur bauen, signieren, notarisieren — Version/Build kommen aus dem bestehenden Git-Stand (neuester Tag + Commit-Count) | Rebuild eines bereits getaggten Stands oder Test des Release-Builds, ohne eine neue Version zu erzeugen |

`notarize.sh` erzeugt also nie eine neue Version — es baut, was Git hergibt. Direkt von einem ungetaggten Stand gebaut, trägt die App die Version des letzten Tags mit höherer Build-Nummer.

Weitere Details zur Architektur finden sich in der [KONZEPT.md](KONZEPT.md).
