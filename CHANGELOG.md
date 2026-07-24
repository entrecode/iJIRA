# Changelog

Alle nennenswerten Änderungen an iJIRA. Das Format ist angelehnt an
[Keep a Changelog](https://keepachangelog.com/de/1.1.0/), die Versionierung
folgt [SemVer](https://semver.org/lang/de/) (Git-Tags ohne v-Präfix).

Neue Änderungen kommen unter **Unreleased**; beim Release verschiebt
`scripts/release.sh` sie automatisch in einen Versionsabschnitt.

## [Unreleased]

## [1.0.3] – 2026-07-24

### Neu

- Bild-/Datei-Upload per Drag & Drop in die Kommentar-Editoren (Issue-Detail
  und Konversations-Antwort) — Dateien werden als Anhang hochgeladen und beim
  Senden als eingebettete Bilder/Videos in den Kommentar übernommen.
- Menüleisten-Icon im Stil des App-Icons (drei gestaffelte Winkel) statt des
  generischen Glockensymbols; systemkonform in schwarz/weiß getintet.
- Version und Build-Nummer sind in der App sichtbar (Einstellungen-Fenster
  und „Über iJIRA“).

### Behoben

- Crash beim Öffnen der Auswahl-Popover (Parent, Assignee, Labels,
  Fix Versions): Das Suchfeld wird jetzt erst nach dem Einblenden des
  Popovers fokussiert.
- Crash beim Loggen von Harvest-Zeiten.

### Intern

- Releaseprozess: `scripts/release.sh` bumpt Version, pflegt das Changelog
  und taggt; `scripts/notarize.sh` leitet Version/Build aus Git ab —
  App-Version und Git-Tags können nicht mehr auseinanderlaufen.

## [1.0.2] – 2026-07-22

### Neu

- Hauptfenster mit Board- und Backlog-Ansicht inklusive Statuswechsel per
  Drag & Drop, Sprint-Ansicht und Volltextsuche.
- Eigenständiges Issue-Detail-Fenster: Titel, Beschreibung, Status, Assignee,
  Parent, Labels, Fix Version, Team, Components, Issue-Type und Sprint
  direkt editierbar; Verknüpfungen und Mentions.
- „Neues Issue“-Dialog mit Team- und Components-Auswahl.
- Harvest-Zeiterfassung mit Rücksync.
- Anhänge per Drag & Drop ins Issue-Detail hochladen.
- App-Icon (drei Neon-Pfeilspitzen) und transparenterer Look.

### Verbessert

- Detail-Dropdowns vereinheitlicht (Button + Popover, Pfeil konsistent am
  Zeilenende).
- Fix-Version-Auswahl als Tippsuche mit Versions-Sortierung statt eines
  überlangen Dropdowns.
- Menüleisten-Popover verliert keine Kommentar-Entwürfe mehr; Leertaste beim
  Tippen wird zuverlässig zugestellt.

### Intern

- Developer-ID-Signing für alle Builds (stabile Identität, notariell
  identisch mit dem Release).

## [1.0.1] – 2026-07-17

### Neu

- Eigene Kommentare erscheinen in der Timeline.
- Mentions in Kommentaren; „Bei Anmeldung starten“ (Login-Item);
  Benachrichtigungs-Historie.

### Verbessert

- Konversation: Header bleibt sichtbar (sticky), Verlauf startet unten beim
  neuesten Eintrag.
- Robustere JIRA-Anbindung: Paginierung und Retry-After-Behandlung.

### Behoben

- SwiftData-Store liegt auf einem app-eigenen Pfad (behebt Datenverlust bei
  Updates).

## [1.0.0] – 2026-06-24

Erstes Release: Menüleisten-App mit JIRA-Notifications als Messenger-artige
Timeline, Antworten mit Markdown-Support (`code`, Code-Blöcke, **fett**,
*kursiv*) und echten macOS-Push-Benachrichtigungen.

[Unreleased]: https://github.com/entrecode/iJIRA/compare/1.0.3...HEAD
[1.0.3]: https://github.com/entrecode/iJIRA/compare/1.0.2...1.0.3
[1.0.2]: https://github.com/entrecode/iJIRA/compare/1.0.1...1.0.2
[1.0.1]: https://github.com/entrecode/iJIRA/compare/1.0.0...1.0.1
[1.0.0]: https://github.com/entrecode/iJIRA/releases/tag/1.0.0
