# Plan: Hauptfenster, Board, Menüs, Icon, Harvest

Stand 2026-07-19 (Europe/Berlin). Detailplanung für den Ausbau von iJIRA zum
vollwertigen Jira-Ersatz. Jedes Dokument ist so ausgearbeitet, dass die
Umsetzung mechanisch möglich ist (Endpoints, DTOs, Datei-Änderungen,
Edge-Cases, Verifikation).

## Meilensteine & Reihenfolge

| # | Meilenstein | Dokument | Abhängig von |
|---|-------------|----------|--------------|
| M5 | Hauptfenster-Shell: Board/Issue-Umschalter, echte macOS-Menüleiste, Einstellungs-Fenster | [01-hauptfenster-navigation.md](01-hauptfenster-navigation.md) | — |
| M6 | Board- & Backlog-Ansicht (read-only, gecacht, Board-Dropdown) | [02-board-backlog.md](02-board-backlog.md) | M5 |
| M7 | Drag & Drop Statuswechsel + Prefetch aller Boards | [02-board-backlog.md](02-board-backlog.md) §6–7 | M6 |
| M8 | App-Icon (drei Neon-Pfeilspitzen) | [03-app-icon.md](03-app-icon.md) | — (parallel) |
| M9 | Harvest-Zeiterfassung | [04-harvest.md](04-harvest.md) | M5 (Settings-Fenster) |

Empfohlene Commits: einer je Meilenstein, M6/M7 ggf. getrennt
(read-only-Board zuerst, DnD danach).

## Grundprinzipien (gelten für alle Meilensteine)

1. **Snappy = Cache zuerst, Netz im Hintergrund.** Jede Ansicht rendert
   sofort aus dem letzten Snapshot (Memory + JSON auf Platte) und aktualisiert
   sich still. Kein Spinner beim Board-Wechsel, kein Nachladen im Dropdown.
2. **Automatisch aktuell.** Aktives Board alle 60 s + bei Fenster-Fokus,
   Wake und nach jeder eigenen Mutation; inaktive Boards alle 10 min
   (Prefetch). Bestehende SyncEngine bleibt unberührt.
3. **Optimistische Updates.** DnD/Edits ändern die UI sofort; bei
   Server-Fehler Rollback + Fehler-Toast (Muster aus `IssueDetailModel`).
4. **Ein Fenster.** Issue-Details öffnen im Hauptfenster (Tab „Issue");
   die bisherigen Einzelfenster bleiben als Option (⌥-Klick) erhalten.
5. **Zeitzone.** Alles, was Kalenderdaten erzeugt (Harvest `spent_date`),
   rechnet explizit in `Europe/Berlin`.

## Bestehende Bausteine, die wiederverwendet werden

- `JiraClient` (Basic Auth, `get`/`post`/`sendNoContent`, Media-Session)
- `IssueDetailView`/`IssueDetailModel` (wird einbettbar statt fenster-exklusiv)
- `IssueSearchField`, `JiraKeyParser`, `UserDirectory` (vorgeladen)
- `MarkdownTextEditor` + Mentions, `ADFContentView`
- `KeychainStore` (bekommt zweiten Service-Eintrag für Harvest)
- Deep-Link `ijira://issue/KEY` (headless-Test der Fensterpfade)

## Verifikation (je Meilenstein)

- Build: `xcodegen generate && xcodebuild … build` (nach neuen Dateien immer
  xcodegen!).
- Headless-Smoke: App starten, `open "ijira://issue/KEY"`, Logs prüfen
  (`subsystem == "de.entrecode.iJIRA"`). Neue Log-Zeilen pro Feature sind in
  den Dokumenten definiert.
- Manuell (Nutzer): DnD, Menüs, Icon-Optik, Harvest-Loggen.
