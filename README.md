# iJIRA

Native macOS-App, die die wichtigsten JIRA-Funktionen messenger-artig auf den Mac bringt.

## Download

**[Neueste Version herunterladen](../../releases/latest)** — notarisiertes `.dmg`, läuft ohne Gatekeeper-Warnung.

Image öffnen, iJIRA auf den `Programme`-Ordner ziehen, starten. Änderungen pro Version: [CHANGELOG.md](CHANGELOG.md).

Ab Version 1.1.0 hält sich die App selbst aktuell (Sparkle): Sie sucht im Hintergrund nach Updates und bietet sie zur Installation an. Abschaltbar unter **Einstellungen → Allgemein**, manuell anstoßen über **iJIRA → Nach Updates suchen …**. Das mit veröffentlichte `.zip` ist das Update-Paket für Sparkle — zum Installieren von Hand ist das `.dmg` gedacht.

## Features

- **JIRA-Notifications**: Direkte Notifications (neue Kommentare, Zuweisungen, Mentions) in einer Messenger-artigen Timeline.
- **Antworten**: Kommentare direkt aus der App verfassen, mit Markdown-Support (`code`, Code-Blöcke, **fett**, *kursiv*).
- **Review & Plan**: Sprint-Review-Ansicht — meine Sprint-Issues nach Thema (Epic) gruppiert, sortiert nach der im Sprint geloggten Zeit (aus Harvest, sonst aus den Jira-Worklogs), getrennt in fertig/nicht fertig; darunter der nächste Sprint und die nicht eingeplanten Issues.
- **macOS Integration**: Automatische Aktualisierung mit echten macOS-Push-Benachrichtigungen (Notification Center) und Menüleisten-Icon mit Badge.
- **Leichtgewichtig**: Hybrid-App mit AppKit (`NSStatusItem`, `NSPopover`) für die Hülle und SwiftUI für die Inhalte.

## Entwicklung

Dieses Projekt verwendet [XcodeGen](https://github.com/yonaskolb/XcodeGen), um die Xcode-Projektdatei (`.xcodeproj`) aus der `project.yml` zu generieren. Die `.xcodeproj` ist Wegwerf-Artefakt — Änderungen an Targets/Settings gehören in die `project.yml`.

### Voraussetzungen

- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- Xcode (macOS 14.0+)
- Für Releases zusätzlich: „Developer ID Application“-Zertifikat, Notar-Profil `ijira-notary` (Details im Kopf von `scripts/notarize.sh`), die [GitHub CLI](https://cli.github.com) (`brew install gh`) und `create-dmg` (`brew install create-dmg`, optional — ohne das Tool entsteht ein Image ohne gesetztes Fenster-Layout)

### Einmalig: Sparkle-Signaturschlüssel

Vor dem ersten Release muss der Update-Signaturschlüssel existieren:

```bash
scripts/sparkle-setup.sh
```

Das erzeugt ein EdDSA-Paar, legt den privaten Schlüssel in der Keychain ab und trägt den öffentlichen als `SUPublicEDKey` in die `project.yml` ein. **Der private Schlüssel muss gesichert werden** — geht er verloren, akzeptiert keine bereits installierte iJIRA je wieder ein Update, und alle Nutzer müssten manuell neu installieren. `notarize.sh` verweigert einen signierten Build, solange der Schlüssel fehlt.

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
gh release create 1.0.3 \
  .build-release/iJIRA-1.0.3.dmg \
  .build-release/iJIRA-1.0.3.zip \
  --title "iJIRA 1.0.3" --notes-file .build-release/RELEASE_NOTES.md

# 3. Erst JETZT den appcast pushen — vorher zeigt er auf Dateien,
#    die es noch nicht gibt:
git add appcast.xml && git commit -m "release: appcast 1.0.3" && git push
```

Alternativ zum `gh`-Befehl lässt sich das Release auf der GitHub-Seite anlegen: [Releases → „Draft a new release“](../../releases/new), den frisch gepushten Tag wählen, Notes aus `.build-release/RELEASE_NOTES.md` (bzw. dem neuen CHANGELOG-Abschnitt) einfügen und beide Assets hochladen.

### Wie das Auto-Update funktioniert

Es gibt keinen Updateserver. Die App liest `appcast.xml` von `raw.githubusercontent.com` aus diesem Repo; darin steht die neueste Version samt Link auf das `.zip`-Asset des zugehörigen GitHub-Releases und einer EdDSA-Signatur, die die App gegen ihren eingebauten Public Key prüft. Der Feed enthält bewusst nur den jeweils neuesten Eintrag — Sparkle braucht für den Sprung auf die aktuelle Version nicht mehr.

**Damit das Repo öffentlich lesbar sein muss:** ein privates Repo liefert weder `raw.githubusercontent.com`-Inhalte noch Release-Assets ohne Token aus, und ein in der App eingebetteter Token wäre praktisch öffentlich.

### Wann welches Script?

| Script | Zweck | Wann |
| --- | --- | --- |
| `scripts/release.sh <version>` | Kompletter Release: Changelog finalisieren, Version bumpen, Commit + Tag, Build via notarize.sh, dann appcast | Immer, wenn eine neue Version erscheint |
| `scripts/notarize.sh` | Nur bauen, signieren, notarisieren — erzeugt `.zip` **und** `.dmg`; Version/Build kommen aus dem bestehenden Git-Stand (neuester Tag + Commit-Count) | Rebuild eines bereits getaggten Stands oder Test des Release-Builds, ohne eine neue Version zu erzeugen |
| `scripts/make-dmg.sh <app> <dmg>` | Baut nur das Image (App + `Programme`-Alias) | Wird von notarize.sh aufgerufen; einzeln zum Prüfen des Layouts |
| `scripts/make-appcast.sh <version> [notes.md]` | Erzeugt und signiert `appcast.xml` aus dem Release-Zip | Wird von release.sh aufgerufen; einzeln, wenn der Feed neu geschrieben werden muss |
| `scripts/sparkle-setup.sh` | Erzeugt den Update-Signaturschlüssel und trägt den Public Key ein | Einmalig pro Maschine/Projekt |

`notarize.sh` erzeugt also nie eine neue Version — es baut, was Git hergibt. Direkt von einem ungetaggten Stand gebaut, trägt die App die Version des letzten Tags mit höherer Build-Nummer.

Weitere Details zur Architektur finden sich in der [KONZEPT.md](KONZEPT.md).
