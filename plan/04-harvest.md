# M9 — Harvest-Zeiterfassung (Bonus)

## Ziel

Optionale Harvest-Verbindung in den Einstellungen. Ist sie konfiguriert,
zeigt die Issue-View oben einen Zeit-Button: er zeigt die bereits auf das
Issue geloggte Zeit und erlaubt, in 15-Minuten-Schritten bis 3 h zu loggen.
Notes = „KEY: Titel", Verlinkung + Matching über `external_reference` —
wie beim offiziellen Harvest-Jira-Plugin.

## 1. Harvest API v2 (verifiziert 2026-07-19)

Basis `https://api.harvestapp.com/v2`, Header bei JEDEM Request:
```
Authorization: Bearer <Personal Access Token>
Harvest-Account-Id: <Account-ID>
User-Agent: iJIRA (https://github.com/entrecode/iJIRA)
```
(PAT + Account-ID von https://id.getharvest.com/developers)

| Zweck | Endpoint |
|---|---|
| Verbindungstest / User | `GET /v2/users/me` → `{id, first_name, …}` |
| Projekte+Tasks des Users | `GET /v2/users/me/project_assignments` → `project_assignments[] = {project{id,name}, client{name}, task_assignments[] = {task{id,name}, billable}}` (paginiert, `per_page=100`) |
| Geloggte Zeit je Issue | `GET /v2/time_entries?external_reference_id={jiraIssueId}` → `time_entries[].hours` summieren (alle User? → zusätzlich `user_id={me.id}` filtern — Entscheidung: nur eigene Zeit anzeigen) |
| Zeit loggen | `POST /v2/time_entries` |

POST-Body (Muster offizielles Plugin):
```json
{
  "project_id": 12345678,
  "task_id": 9876543,
  "spent_date": "2026-07-19",          // HEUTE in Europe/Berlin!
  "hours": 0.75,
  "notes": "ONE-9191: Membership Templates ohne Mitgliederstatus",
  "external_reference": {
    "id": "85161",                      // numerische Jira-Issue-ID (stabil bei Key-Umzug)
    "group_id": "ONE",                  // Jira-Projekt-Key
    "permalink": "https://dein-team.atlassian.net/browse/ONE-9191"
  }
}
```
- `permalink` macht den Eintrag in Harvest klickbar (Link-Icon an der
  Notiz) — Anforderung „JIRA-Key (verlinkt!)".
- Matching der Summe über `external_reference_id == issueId` — robust
  gegen Titel-/Notes-Änderungen.

## 2. Einstellungen (Settings-Tab „Harvest", M5-Fenster)

Felder:
- **Access Token** → Keychain (`KeychainStore(service: "de.entrecode.iJIRA.harvest")`, account = "token")
- **Account-ID** → UserDefaults `harvestAccountId`
- Button „Verbinden/Prüfen" → `GET /users/me`, Erfolg zeigt Namen; lädt
  danach `project_assignments` und füllt:
- **Projekt** (Picker: `client.name — project.name`, Wert `project.id`) →
  `harvestProjectId`
- **Aufgabe/Billable Type** (Picker: `task.name` (+ „billable"-Punkt),
  Werte aus `task_assignments` des gewählten Projekts) → `harvestTaskId`
- Hinweistext: „Gilt für alle Issues" (fixe Zuordnung — Anforderung).
- „Trennen" löscht Token/IDs.

Neue Dateien:
- `Harvest/HarvestClient.swift` — dünner Client (eigene URLSession mit
  20 s/60 s-Timeouts wie JiraClient, `get`/`post`, Fehler-Mapping:
  401 → „Token prüfen", 403, 422 → Message aus Body).
- `Harvest/HarvestState.swift` (@MainActor @Observable) — Konfiguration
  laden/persistieren, `isConfigured`, Cache der project_assignments,
  `client()`-Factory. Wird im AppDelegate erzeugt, an Settings + Issue-View
  gereicht (Environment).
- `Harvest/DTOs.swift` — `HarvestUser`, `ProjectAssignmentsResponse`,
  `TimeEntriesResponse {time_entries[{hours, spent_date, notes}], total_entries, next_page}`.

## 3. Issue-View-Integration

`IssueDetailModel`-Erweiterung:
```swift
private(set) var loggedHours: Double?     // nil = unbekannt/lädt
private(set) var isLoggingTime = false
func refreshLoggedTime() async            // GET time_entries?external_reference_id=…&user_id=…
func logTime(hours: Double) async -> Bool // POST, danach refreshLoggedTime()
```
- `refreshLoggedTime()` beim Laden des Issues (parallel, non-blocking),
  Cache 5 min (`loggedTimeFetchedAt`), Pagination: alle Seiten summieren
  (praktisch 1 Seite).
- `spent_date`: `DateFormatter` mit `TimeZone(identifier: "Europe/Berlin")`
  — die App kann auf Reisen laufen, geloggt wird der Berliner Arbeitstag.
- Notes: `"\(issueKey): \(summary)"` (Summary auf 200 Zeichen kürzen).
- `group_id`: Projekt-Key = `issueKey` vor dem „-".

UI (`IssueView/TimeLogButton.swift`), im Header der Issue-Ansicht (Fenster
UND Hauptfenster-Variante, neben Web-Link):
```
[ ⏱ 1:45 ▾ ]        // geloggte eigene Zeit; „⏱ –" solange unbekannt
```
- Nur sichtbar, wenn `harvestState.isConfigured`.
- Klick → Popover: Grid mit 12 Buttons `0:15 … 3:00` (15-min-Schritte,
  4 Spalten), Fußzeile „wird geloggt auf: {Projekt} · {Task}" (aus
  Settings, dezent) + Hinweis auf heutiges Datum.
- Klick auf Dauer → optimistisch `loggedHours += h`, Button-Spinner,
  POST; Fehler → Rollback + ErrorToast (bestehendes Muster).
- Format: `H:mm` (0.75 → „0:45").

## 4. Edge-Cases

- Harvest konfiguriert, aber Projekt/Task-Zuordnung ungültig geworden
  (Projekt archiviert) → 422 vom POST; Toast mit Hinweis auf Einstellungen.
- `external_reference_id`-Filter matcht auch Einträge des offiziellen
  Plugins/anderer Tools — gewollt (gleiche Referenz-Konvention), aber via
  `user_id` auf eigene beschränkt (Anzeige = „von mir geloggt").
- Kein Doppel-Timer/Running-Timer-Support — bewusst nur Pauschal-Loggen
  (Anforderung). `is_running`-Einträge zählen in der Summe mit
  (`hours` läuft mit; akzeptiert).
- Rate-Limit Harvest: 100 req/15 s — irrelevant bei unserem Volumen.

## 5. Verifikation

- Settings: Token+Account-ID rein → „Verbunden als {Name}", Projekt/Task
  wählbar; Werte überleben Neustart (Keychain/Defaults).
- Issue öffnen → Log „Harvest: {key} 1.75 h geloggt gesamt" (neue Zeile).
- 0:15 loggen → in Harvest-Web sichtbar: Notiz „KEY: Titel" MIT Link aufs
  Issue; Button zählt hoch; erneutes Öffnen zeigt Summe inkl. neuem Eintrag.
- Headless-Test: HarvestClient gegen echten Account via App-Logs
  (Settings-Verbindungstest), kein separates Test-Target nötig.
