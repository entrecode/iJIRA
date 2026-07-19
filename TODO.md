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

## Erledigt (2026-07-17)

- [x] **Eigene Nachrichten anzeigen:** Der Sync überspringt eigene Kommentare
  nicht mehr — sie erscheinen in der Timeline (Feld `isOwn`, immer gelesen,
  nie gepusht) und werden im Chat rechtsbündig/getönt dargestellt. Selbst
  gesendete Antworten tragen jetzt auch das eigene Avatar.

## Nicht machbar (Stand 2026-07-17)

- **Reactions anzeigen/senden:** Mit API-Token-Auth (Basic) gibt es keinen
  funktionierenden Zugang zu Jira-Cloud-Kommentar-Reactions. Live gegen
  `dein-team.atlassian.net` mit echten Credentials verifiziert:
  - `POST /rest/internal/2/reactions/view` + `/emojis` (im Atlassian-KB
    beschrieben): existiert nicht mehr → 404 „No endpoint".
  - `/gateway/api/reactions/reactions` (GET/POST/DELETE; der Weg der Web-UI):
    401 auch mit gültigem API-Token — der Service akzeptiert nur
    Session-Cookies.
  - GraphQL-Gateway `gateway/api/graphql` akzeptiert API-Tokens, aber dessen
    `reactionsSummary*`/`addReaction`/`deleteReaction` gehören zum
    **Confluence**-Reactions-Service (`ContainerType`-Enum ohne `ISSUE`,
    Backend `pf-reactions-service` erwartet numerische Confluence-IDs).
  - `rest/gira/1/` (site-lokales GraphQL des Issue-Views, Basic Auth ok):
    Schema enthält keinerlei Reactions-Typen.
  - Mobile-/Public-REST-Varianten und Comment-Properties (`expand=properties`):
    404 bzw. leer.
  Einziger denkbarer Weg wäre Cookie-/Session-Auth (WebView-Login) — großer
  Umbau, bewusst nicht gemacht. Ggf. auf JRACLOUD-78153 (offizielles
  Feature-Ticket „Comment reactions in REST API") warten.

## Erledigt (2026-07-19)

- [x] **M5–M9 komplett** (Plan in [plan/README.md](plan/README.md)):
  Hauptfenster mit Board/Issue-Umschalter + dynamischer Activation-Policy,
  echte Menüleiste, Settings-Fenster; Board-/Backlog-Ansicht mit
  Snapshot-Cache, Prefetch aller Boards und DnD-Statuswechsel; App-Icon
  (Neon-Chevrons); Harvest-Zeiterfassung (external_reference-Matching,
  15-min-Raster, Europe/Berlin).

## Offen

- [ ] **Keychain-Read blockiert den Start:** `AppState.init` liest das Token
  synchron auf dem Main-Thread — wenn securityd nach einem Rebuild die
  Zugriffserlaubnis abfragt, friert die App bis zur Bestätigung ein.
  Verbesserung: Read asynchron/lazy machen, UI startet sofort.
- [ ] **Tests:** Es gibt kein Test-Target. Kandidaten mit dem besten Nutzen:
  Cursor-/`historicalCutoff`-Logik in `SyncEngine.process`, `JiraDate.parse`,
  Changelog-Letzte-Seite-Logik (mit gemocktem Client via Protokoll),
  neu: Markdown↔ADF-Roundtrip.
- [ ] **Bell-Feed (M4 aus KONZEPT.md):** weiterhin offen, bewusst nicht begonnen.
