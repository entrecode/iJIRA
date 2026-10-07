# Changelog

Alle nennenswerten Änderungen an iJIRA. Das Format ist angelehnt an
[Keep a Changelog](https://keepachangelog.com/de/1.1.0/), die Versionierung
folgt [SemVer](https://semver.org/lang/de/) (Git-Tags ohne v-Präfix).

Neue Änderungen kommen unter **Unreleased**; beim Release verschiebt
`scripts/release.sh` sie automatisch in einen Versionsabschnitt.

## [Unreleased]

### Behoben

- **Update-Dialog auf Deutsch:** Der Update-Dialog (Sparkle) erschien auf
  Englisch, weil die App macOS gegenüber nur Englisch als Sprache angab.
  iJIRA ist jetzt als deutschsprachig ausgewiesen; damit erscheinen auch
  System-Texte wie Standard-Menüeinträge auf Deutsch. Wirkt ab dem Update
  *nach* dieser Version — den Dialog zeigt immer die gerade installierte App.

## [1.2.0] – 2026-10-07

### Hinzugefügt

- **Tabellen:** Tabellen in Beschreibungen und Kommentaren werden jetzt als
  echte Tabelle dargestellt statt als Hinweis „bitte im Web ansehen" — mit
  Kopfzeile, Zeilenumbruch in langen Zellen, verbundenen Zellen und
  Zellfarben. In der Menüleiste erscheinen sie kompakt Zeile für Zeile.
- **Markdown-Tabellen schreiben:** Eine Markdown-Tabelle (`| a | b |` mit
  `|---|---|`-Trennzeile) in Kommentar, Beschreibung oder neuem Issue wird zur
  echten Jira-Tabelle — im Web wie in iJIRA. Beim Bearbeiten der Beschreibung
  erscheinen vorhandene Tabellen als Markdown-Tabelle an ihrer Stelle (statt
  ans Ende zu rücken); nur Tabellen mit verbundenen oder eingefärbten Zellen
  bleiben unverändert erhalten. Im Editor sind Tabellenzeilen monospaced.
- **Mehr Markdown:** Eingefügtes Markdown kommt jetzt so in Jira an, wie es
  gemeint ist: verschachtelte Listen per Einrückung, Aufgabenlisten
  (`- [ ]` / `- [x]`), Listen ab beliebiger Nummer, `~~durchgestrichen~~`,
  `_kursiv_`/`__fett__`/`***beides***`, verschachtelte Formatierung
  (**fett mit `code`**), Escapes (`\*`), `~~~`-Code-Blöcke, `***`/`___` als
  Trennlinie, `<br>` und `<https://…>`. `snake_case` und `5 * 3` bleiben Text.
  Aufgabenlisten werden auch in iJIRA dargestellt.

### Behoben

- **Beschreibung bearbeiten:** Text, der wie Formatierung aussieht (`*`,
  `_` am Wortrand, „1." oder „-" am Zeilenanfang), wird beim Öffnen des
  Editors escaped und beim Speichern nicht mehr ungewollt zu Liste oder
  Kursivschrift. Zeilenumbrüche in Listenpunkten und verschachtelte Listen
  überstehen das Speichern.

## [1.1.1] – 2026-08-14

### Behoben

- **Components im „Neues Issue"-Dialog abwählbar:** Im Components-Dropdown des
  Anlegen-Dialogs ließen sich einmal gewählte Komponenten nicht wieder
  abwählen — nur neue hinzufügen. Die Einträge sind jetzt native abhakbare
  Menüpunkte, An- und Abwählen funktioniert in beide Richtungen.

## [1.1.0] – 2026-08-07

### Hinzugefügt

- **Automatische Updates:** iJIRA sucht im Hintergrund nach neuen Versionen und
  bietet sie zur Installation an — kein manuelles Herunterladen mehr. Manuell
  anstoßen über **iJIRA → Nach Updates suchen …**, abschalten unter
  **Einstellungen → Allgemein**. Umgesetzt mit Sparkle; die Update-Infos liegen
  als signierte Datei im Repo, es gibt keinen eigenen Updateserver. Jedes
  Update wird vor der Installation gegen den in der App hinterlegten
  Schlüssel geprüft.

- **Genaue Zeit per Mouse-over:** Alle relativen Zeitangaben („vor 3 Std.") —
  an Kommentaren, Board-Karten, in der Timeline und bei „zuletzt
  aktualisiert" — zeigen beim Überfahren das genaue Datum samt Uhrzeit.
- **Link zu einzelnen Kommentaren:** Beim Überfahren eines Kommentars in der
  Detail-Ansicht erscheint ein Link-Knopf, der den Jira-Deeplink auf genau
  diesen Kommentar kopiert (Jira springt beim Öffnen direkt dorthin). In der
  Timeline im Popover liegt derselbe Link jetzt neben „Im Web öffnen".

### Verbessert

- **iJIRA ist eine normale App:** Bisher lief sie als reiner
  Menüleisten-Agent, der sich nur zeitweise ein Dock-Icon zulegte. Jetzt ist
  sie durchgängig eine gewöhnliche App mit Dock-Icon und Menüleiste — das
  Menüleisten-Symbol samt Timeline bleibt daneben erhalten. Wie gehabt läuft
  sie nach dem Schließen des letzten Fensters weiter und synchronisiert
  weiter.
- **Installation als Disk-Image:** Releases erscheinen jetzt als `.dmg` mit
  `Programme`-Alias zum Hineinziehen statt als Zip-Archiv. Damit landet die App
  verlässlich in `/Applications` — aus einem Zip heraus wurde sie oft direkt im
  Download-Ordner gestartet, was Login-Item und Update-Installation stört.

### Behoben

- **Sporadischer Absturz beim Öffnen der Auswahl-Popover:** Ein Klick auf
  Assignee, Parent, Labels oder Fix-Versions konnte die App beenden. Das
  Suchfeld wurde fokussiert, während macOS das Popover-Fenster noch
  einblendete — die dabei eingehängte Eingabe-Systemview (out-of-process)
  brachte AppKit zum Absturz, gehäuft auf der macOS-27-Beta. Der Fokus wird
  jetzt erst gesetzt, wenn das Popover fertig präsentiert ist
  (`NSPopover.didShowNotification` statt Run-Loop-Raten).

## [1.0.6] – 2026-08-04

### Hinzugefügt

- **Untergeordnete Vorgänge in der Detail-Ansicht:** Über den verlinkten
  Vorgängen steht jetzt, was unter dem Issue hängt — bei einem Epic die
  enthaltenen Vorgänge, bei einer Story die Sub-Tasks. Je Zeile Typ-Symbol,
  Key, Titel und Status; Klick öffnet das Issue. Die Karte erscheint nur, wenn
  es Kinder gibt.
- **Link zum Issue kopieren:** Neuer Link-Knopf im Kopfbereich der
  Detail-Ansicht (Einzelfenster wie Hauptfenster-Tab) legt die Browse-URL in
  die Zwischenablage — kurzes Häkchen als Bestätigung. Dazu **⌘⇧C** und der
  Eintrag „Link zum Issue kopieren" im Bearbeiten-Menü, die aufs vorderste
  Issue wirken. Rechtsklick auf Key-Chip oder Link-Knopf bietet beides an
  (Key bzw. Link), damit man nicht den richtigen Knopf treffen muss.

### Behoben

- **Lange Beschreibungen und Kommentare wurden abgeschnitten:** Enthielt ein
  Text ein Zitat, kürzte iJIRA alle anderen Absätze auf eine Zeile mit „…" —
  am deutlichsten bei Listen. Ursache war der Zitat-Balken: als Shape ohne
  Höhenbegrenzung beanspruchte er beliebig viel Platz, sodass der übrige Text
  gequetscht wurde. Er liegt jetzt als Overlay hinter dem Zitat und nimmt nur
  dessen Höhe ein — nebenbei verschwindet damit auch die große Leerfläche, die
  unter Zitaten stand.

## [1.0.5] – 2026-07-28

### Verbessert

- **Mehr Glas:** Der Fenster-Hintergrund nutzt jetzt das dünnste
  System-Material statt `.sidebar` — der Desktop scheint deutlich stärker
  durch, bleibt dabei aber unscharf. Die Panels darauf (Themen- und
  Sektions-Karten, Board-Spalten, Issue-Karten) sind 10 % durchscheinender;
  bewusst viel weniger als der Hintergrund, weil darüber Text lesbar bleiben
  muss.

### Behoben

- **Links in Beschreibungen und Kommentaren:** Smart Links zeigten einen
  kryptischen Text (`F7AA484D-744` statt `admin.appsite.de`) — die
  Key-Erkennung hatte eine UUID in der URL als Jira-Key gelesen. Und sie waren
  kaum anklickbar: Links liegen jetzt als Chip mit großzügiger Trefferfläche
  vor, statt als Link innerhalb eines Textabsatzes.
- **Verknüpfungen wurden in der falschen Richtung angelegt:** „ONE-1 blocks …"
  ergab eine Verknüpfung „ONE-1 is blocked by …". Alle Beziehungen waren beim
  Hinzufügen vertauscht; die Anzeige bestehender Verknüpfungen war korrekt.
- Der Frost-Effekt verschwand, sobald das Fenster den Fokus verlor (etwa weil
  das Einstellungs-Fenster davor lag): Das Material wechselte dann auf sein
  flaches, deckendes „inactive"-Aussehen.

## [1.0.4] – 2026-07-28

### Neu

- **Dritter Bereich „Review & Plan"** (⌘3) für Sprint Review und Planning, in
  drei Blöcken untereinander:
  - **Aktueller Sprint** — meine Issues des laufenden Sprints, gruppiert nach
    Thema (Epic), Themen absteigend nach der *in diesem Sprint* geloggten Zeit.
    Pro Thema getrennt in „fertig" (die beiden hintersten Board-Spalten) und
    „nicht fertig", mit Fertigstand-Balken. Zeiten kommen aus **Harvest**, wenn
    Harvest konfiguriert ist (Zuordnung wie beim Zeit-Button: `external_reference`
    oder Jira-Key in der Notiz), sonst aus den Jira-Worklogs — immer begrenzt auf
    den Sprintzeitraum (ganze Tage, Europe/Berlin). Die verwendete Quelle steht
    in der Ansicht.
  - **Nächster Sprint** — was im nächsten geplanten Sprint liegt, ebenfalls nach
    Themen, ohne fertig/nicht-fertig.
  - **Nicht eingeplant** — meine offenen Issues, die in keinem laufenden *oder*
    geplanten Sprint sind.
  Sub-Tasks bekommen keine eigene Zeile, sondern rollen mit ihrer Zeit in ihr
  Parent-Issue und lassen sich dort aufklappen. Themen sind einklappbar. Die
  Ansicht lädt beim Öffnen bzw. per ⌘R und wird als Snapshot zwischengespeichert.

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

[Unreleased]: https://github.com/entrecode/iJIRA/compare/1.2.0...HEAD
[1.2.0]: https://github.com/entrecode/iJIRA/compare/1.1.1...1.2.0
[1.1.1]: https://github.com/entrecode/iJIRA/compare/1.1.0...1.1.1
[1.1.0]: https://github.com/entrecode/iJIRA/compare/1.0.6...1.1.0
[1.0.6]: https://github.com/entrecode/iJIRA/compare/1.0.5...1.0.6
[1.0.5]: https://github.com/entrecode/iJIRA/compare/1.0.4...1.0.5
[1.0.4]: https://github.com/entrecode/iJIRA/compare/1.0.3...1.0.4
[1.0.3]: https://github.com/entrecode/iJIRA/compare/1.0.2...1.0.3
[1.0.2]: https://github.com/entrecode/iJIRA/compare/1.0.1...1.0.2
[1.0.1]: https://github.com/entrecode/iJIRA/compare/1.0.0...1.0.1
[1.0.0]: https://github.com/entrecode/iJIRA/releases/tag/1.0.0
