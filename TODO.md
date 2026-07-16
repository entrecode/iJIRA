# TODO

Offene Punkte aus dem Sync-/Stabilitäts-Review vom 2026-07-07 (Europe/Berlin).
Stand 2026-07-16: Die Zuverlässigkeits-Fixes (App Nap, Request-Timeouts,
Wake-/Netzwerk-Trigger, Watchdog, Changelog-Paginierung) sowie die Punkte
unten unter „Erledigt" sind umgesetzt.

## Erledigt (2026-07-16)

- [x] **Root cause „Inhalte verschwinden / lädt nicht mehr":** Der SwiftData-Store
  lag am generischen Pfad `~/Library/Application Support/default.store`, den sich
  alle SwiftData-Apps ohne eigene Konfiguration teilen. Eine fremde App hat dort
  die iJIRA-Tabellen zerstört (`no such table: ZSYNCCURSOR`) → alle Fetches/Saves
  schlugen bis zum Neustart fehl. Store liegt jetzt exklusiv unter
  `~/Library/Application Support/iJIRA/iJIRA.store`, kaputte Stores werden einmal
  entfernt und neu angelegt.
- [x] **Mentions abdecken:** JQL erweitert um `comment ~ currentUser() OR
  description ~ currentUser()` (Jira matcht Mentions serverseitig als
  `[~accountid:…]` über die Text-Suche).
- [x] **`Retry-After` bei HTTP 429:** Header wird gelesen und der Sync wartet
  exakt so lange (gedeckelt auf 30 min) statt generisch zu backoffen.
- [x] **Paginierung der Issue-Suche:** `searchInvolvedIssues` blättert über
  `nextPageToken` weiter (bis zu 5 Seiten à 100 Issues).
- [x] **SyncCursor-Aufräumen:** Cursors von Issues, die >8 Tage nicht mehr
  aktualisiert wurden, werden beim Sync entfernt.
- [x] **Diagnose-Logging:** `os.Logger` (Subsystem `de.entrecode.iJIRA`,
  Kategorien `sync`/`store`/`app`); Log pro Sync-Lauf (Issue-Anzahl, neue
  Einträge, Dauer, Fehler). Auswertung:
  `log show --last 3d --predicate 'subsystem == "de.entrecode.iJIRA"' --info`
- [x] **Sammel-Notification anklickbar:** Tap auf „N neue Benachrichtigungen"
  öffnet das Popover (`MenuBarController.showPopover()`).
- [x] **Login-Item:** „Bei Anmeldung starten"-Toggle in den Settings via
  `SMAppService.mainApp` (funktioniert nur für installierte Builds, Debug-Builds
  zeigen ggf. einen Fehler).
- [x] **Konversation: Nachladen älterer Historie:** „Ältere Kommentare laden"
  zieht weitere Kommentar-Seiten via REST nach (als gelesen, `source = history`,
  vom Purge ausgenommen).

## Offen

- [ ] **Tests:** Es gibt kein Test-Target. Kandidaten mit dem besten Nutzen:
  Cursor-/`historicalCutoff`-Logik in `SyncEngine.process`, `JiraDate.parse`,
  Changelog-Letzte-Seite-Logik (mit gemocktem Client via Protokoll).
- [ ] **Bell-Feed (M4 aus KONZEPT.md):** weiterhin offen, bewusst nicht begonnen.
