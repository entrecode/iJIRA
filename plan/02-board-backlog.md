# M6/M7 — Sprint-Board & Backlog-Liste

## Ziel

Oberer Bereich des Board-Tabs: spaltenbasierte Sprint-Ansicht des gewählten
Boards (Spalten = Board-Konfiguration, dynamisch). Darüber ein Dropdown mit
**allen Boards aller sichtbaren Spaces** (nur Boardname, ohne Space) —
Wechsel ohne Ladezeit. Darunter: Liste der eigenen offenen Issues, die in
keinem aktiven Sprint sind. Überall nur Issues mit `assignee = currentUser()`.

## 1. Jira Agile API (rest/agile/1.0 — gleiche Basic Auth wie rest/api/3)

| Zweck | Endpoint | Anmerkungen |
|---|---|---|
| Alle Boards | `GET /rest/agile/1.0/board?startAt=…&maxResults=50` | paginieren bis `isLast`; Felder: `id`, `name`, `type` ("scrum"/"kanban"), `location.projectKey`/`displayName` |
| Spalten-Konfig | `GET /rest/agile/1.0/board/{id}/configuration` | `columnConfig.columns[] = {name, statuses[{id}]}` — Status-ID → Spalte |
| Aktive Sprints | `GET /rest/agile/1.0/board/{id}/sprint?state=active` | kann 0..n liefern; alle aktiven mergen, Namen joinen |
| Sprint-Issues (meine) | `GET /rest/agile/1.0/sprint/{sprintId}/issue?jql=assignee%3DcurrentUser()&fields=summary,status,priority,issuetype,updated&maxResults=100` | Antwort wie Issue-Search (`issues[]`, `fields.status.id`!) |
| Kanban-Issues (meine) | `GET /rest/agile/1.0/board/{id}/issue?jql=…` | Fallback für `type == "kanban"` (kein Sprint) |
| Statuswechsel | `GET/POST /rest/api/3/issue/{key}/transitions` | für DnD, siehe §6 |

Backlog-Liste (boardunabhängig, via bestehendem `post("rest/api/3/search/jql")`):

```
assignee = currentUser() AND statusCategory != Done
  AND (sprint is EMPTY OR sprint not in openSprints())
ORDER BY updated DESC          (fields: summary,status,priority,issuetype,updated; max 100)
```

Entscheidung: Die Liste ist global über alle Projekte („dennoch dem Nutzer
zugeordnet"), nicht board-gefiltert — deckt auch Projekte ohne Board ab.
Issues ohne Sprint-Feld (Business-Projekte) liefert `sprint is EMPTY` mit.

## 2. Neue DTOs (`Jira/DTOs/Agile.swift`)

```swift
struct BoardDTO: Decodable, Sendable, Identifiable {
    let id: Int; let name: String; let type: String
    let location: Location?
    struct Location: Decodable, Sendable { let projectKey: String?; let displayName: String? }
}
struct BoardsResponse: Decodable, Sendable { let values: [BoardDTO]; let isLast: Bool? }
struct BoardConfigurationDTO: Decodable, Sendable {
    let columnConfig: ColumnConfig
    struct ColumnConfig: Decodable, Sendable { let columns: [Column] }
    struct Column: Decodable, Sendable {
        let name: String
        let statuses: [StatusRef]
        struct StatusRef: Decodable, Sendable { let id: String }
    }
}
struct SprintDTO: Decodable, Sendable, Identifiable {
    let id: Int; let name: String; let state: String?
    let startDate: String?; let endDate: String?
}
struct SprintsResponse: Decodable, Sendable { let values: [SprintDTO] }
/// Issue-Karten brauchen zusätzlich status.id + priority/issuetype-Icons:
struct BoardIssueDTO: Decodable, Sendable, Identifiable { … analog IssueDTO,
    fields: { summary, updated, status{id,name,statusCategory}, priority{name,iconUrl}, issuetype{name,iconUrl} } }
```

`JiraClient`-Methoden: `allBoards()`, `boardConfiguration(boardId:)`,
`activeSprints(boardId:)`, `sprintIssues(sprintId:jql:)`,
`boardIssues(boardId:jql:)`, `myOpenIssuesOutsideSprints()`,
`transitions(issueKey:)`, `applyTransition(issueKey:transitionId:)`.

## 3. BoardStore — Cache-Architektur (das Snappy-Herzstück)

`iJIRA/Board/BoardStore.swift` (@MainActor @Observable):

```swift
struct BoardSnapshot: Codable {          // pro Board persistiert
    var boardId: Int
    var columns: [ColumnSnapshot]        // {name, statusIds, issues[]}
    var sprintName: String?              // "Sprint 42" / nil bei Kanban
    var sprintId: Int?
    var fetchedAt: Date
}
final class BoardStore {
    private(set) var boards: [BoardDTO]          // Dropdown-Inhalt
    var selectedBoardId: Int                     // UserDefaults
    private(set) var snapshots: [Int: BoardSnapshot]  // alle Boards!
    private(set) var backlog: [BoardIssueDTO]
    private(set) var lastRefresh: [Int: Date]
}
```

- **Persistenz:** `~/Library/Application Support/iJIRA/boards/` —
  `boards.json` + `board-{id}.json` + `backlog.json` (JSONEncoder).
  Beim Init synchron laden → erster Frame zeigt sofort Daten.
- **Prefetch:** Nach Connect `refreshBoardList()` (paginiert), danach
  sequentiell `refreshSnapshot(boardId:)` für ALLE Boards (Konfig + Sprint +
  Issues = 3 Requests/Board; bei ~10 Boards unkritisch, 250 ms Abstand
  gegen Rate-Limits). Ergebnis: Dropdown-Wechsel trifft immer einen
  Snapshot → **null Ladezeit**.
- **Refresh-Takte** (Task-Loop analog SyncEngine, eigener Timer):
  aktives Board 60 s; alle anderen + Backlog 10 min; zusätzlich bei
  `NSWindow.didBecomeKey`, Wake und nach jedem DnD/Edit. Kein Refresh,
  wenn Hauptfenster geschlossen (Loop pausiert, Menüleisten-Sync läuft ja
  weiter).
- **Spalten-Zuordnung:** `column.statusIds.contains(issue.fields.status.id)`;
  Issues mit unbekanntem Status → letzte Spalte „Sonstige" (nur wenn nötig).
- Log-Zeilen: „Board {id} aktualisiert: {n} Issues, {m} Spalten, {dauer}s",
  „Boards: {n} geladen".

## 4. Board-UI (`Board/BoardView.swift`, `Board/BoardColumnView.swift`, `Board/IssueCardView.swift`)

```
┌────────────────────────────────────────────────────────────┐
│ [Board-Dropdown ▾]   Sprint 42 · 14.–28.07.       (dezent)  │
│ ┌─ To Do ──────┐ ┌─ In Progress ─┐ ┌─ Review ─┐ ┌─ Done ─┐ │
│ │ ┌──────────┐ │ │               │ │          │ │        │ │
│ │ │ONE-9191⧉│ │ │   (Karten)    │ │          │ │        │ │
│ │ │Summary…  │ │ │               │ │          │ │        │ │
│ │ └──────────┘ │ │               │ │          │ │        │ │
│ └──────────────┘ └───────────────┘ └──────────┘ └────────┘ │
├────────────────────────────────────────────────────────────┤
│ WEITERE OFFENE ISSUES (nicht im Sprint)                     │
│  ONE-8804  Clubapp: Aboschulden…            [To Do]         │
│  …                                                          │
└────────────────────────────────────────────────────────────┘
```

- **Dropdown:** `Menu` mit `boards.map(\.name)` (nur Boardname —
  Anforderung; bei Namens-Duplikaten Suffix „ · PROJEKTKEY" nur für die
  Duplikate). Auswahl setzt `selectedBoardId` → Snapshot ist schon da.
- **Spalten:** horizontaler `ScrollView` mit `HStack`, Spaltenbreite
  ~260 pt, Spalten-Header mit Name + Anzahl. Vertikal je Spalte eigener
  `ScrollView`.
- **Karte** (`IssueCardView`): Key-Zeile (monospaced, Copy-Button mit
  Häkchen-Feedback wie im Detail-Header — Anforderung „direkt kopierbar"),
  Summary (2 Zeilen), Fußzeile: Issue-Typ-Icon (`AsyncImage` iconUrl,
  16 px) + Priorität + relative Zeit. Klick → `IssueWindowManager.open`
  (→ Hauptfenster-Tab Issue), ⌥-Klick → Einzelfenster. Hover-Highlight,
  `.contentShape` volle Karte.
- **Backlog-Liste:** einfache `LazyVStack`-Rows (Key kopierbar, Summary,
  StatusBadge, relative Zeit), gleiche Klick-Semantik.
- Empty-States: „Kein aktiver Sprint", „Keine eigenen Issues im Sprint 🎉".

## 5. Performance-Details

- Icon-URLs (Issue-Typ/Priorität) sind öffentlich cachebar →
  eigener kleiner `ImageMemoryCache` (NSCache) statt AsyncImage-Defaults,
  geteilt mit Avataren.
- Karten sind `Equatable`-Views (Snapshot-Structs, keine Modelle) →
  minimale Re-Renders beim 60-s-Refresh (Diff über `fetchedAt` egal,
  SwiftUI diffed die Struct-Arrays).
- Kein Netzwerkzugriff im View-Body — ausschließlich `BoardStore`.

## 6. Drag & Drop → Statuswechsel (M7)

- Karte: `.draggable(issue.key)` (Transferable String). Spalte:
  `.dropDestination(for: String.self)` + `isTargeted`-Highlight
  (Akzent-Rahmen wie Attachment-Drop).
- Drop-Ablauf (`BoardStore.move(issueKey:toColumn:)`):
  1. **Optimistisch**: Issue im Snapshot in die Zielspalte verschieben.
  2. `GET transitions` → Kandidaten = Transitions, deren `to.id` in
     `column.statusIds` liegt. Auswahl: exakter Match auf ersten Status
     der Spalte, sonst erster Kandidat.
  3. `POST transitions {transition: {id}}`.
  4. Erfolg → stiller Board-Refresh. Fehler/kein Kandidat → Snapshot
     zurückrollen + Toast „Kein Übergang nach ‚{Spalte}' möglich"
     (Workflow-Restriktionen!).
- Gleiche Spalte / gleicher Status → No-op.
- Log: „DnD {key}: {von} → {nach} via Transition {id}".

## 7. Einbettung in M5-Shell

- `MainWindowView` Tab „Board" = `BoardView(store: boardStore)`.
- `BoardStore` wird im AppDelegate erzeugt (nach Connect gestartet) und an
  `MainWindowController.configure` gereicht — er lebt unabhängig vom
  Fenster (Prefetch läuft auch ohne offenes Fenster weiter, gedrosselt).

## 8. Edge-Cases

- Board ohne aktiven Sprint (Scrum) → Empty-State + trotzdem Spalten
  anzeigen? Nein: Hinweis „Kein aktiver Sprint" + Backlog-Liste bleibt.
- Mehrere aktive Sprints (parallel sprints) → Issues beider Sprints
  mergen, Header „Sprint A + Sprint B".
- 429/Netzfehler beim Prefetch → Backoff, alter Snapshot bleibt (mit
  dezentem „Stand vor 25 min" im Board-Header ab >5 min Alter).
- Board gelöscht/unsichtbar geworden → aus Liste entfernen; war es
  selektiert → erstes Board wählen.
- `location` fehlt (persönliche Boards) → trotzdem anzeigen.

## 9. Verifikation

- Headless: Logs „Boards: n geladen", „Board {id} aktualisiert …" nach
  Connect; `board-*.json` Dateien entstehen; zweiter Start rendert ohne
  Netz (Netz aus? → Snapshot-Render prüfen via Log „Board aus Cache").
- Manuell: Dropdown-Wechsel (sofort?), DnD in erlaubte/verbotene Spalte,
  Karte klicken/⌥-klicken, Key kopieren.
