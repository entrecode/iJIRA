# iJIRA — Konzept

Native macOS-App, die die wichtigsten JIRA-Funktionen messenger-artig auf den
Mac bringt. **Phase 1** (dieses Dokument im Detail): JIRA-Notifications abrufen,
als Chat-/Messenger-Liste anzeigen, automatisch aktualisieren, als echte
macOS-Push-Benachrichtigungen ins Notification Center spiegeln und über ein
Menüleisten-Icon auf Neuigkeiten hinweisen.

> Entscheidungen (mit dir abgestimmt): **Jira Cloud** · **SwiftUI + AppKit** ·
> **kombinierte Notification-Quelle** (Glocken-Feed primär, REST-Polling als
> verlässliches Rückgrat/Fallback).

---

## 1. Produktvision & Scope

Ziel ist kein Jira-Vollclient, sondern ein **leichtgewichtiger Begleiter**, der
in der Menüleiste lebt:

- **Phase 1 — Notifications (Fokus):** Direkte Notifications (neue Kommentare,
  Zuweisungen, Mentions, Status-/Feld-Updates an Issues, die mich betreffen)
  laufen in eine Messenger-artige Timeline. Neue Einträge erscheinen automatisch,
  als macOS-Notification und über ein Badge am Menüleisten-Icon.
- **Links gehen ins Web:** Klick auf ein Issue/Detail öffnet `…/browse/KEY-123`
  im Standardbrowser. Die App rendert *keine* Issue-Detailseiten nach.
- **Spätere Phasen (nur skizziert, nicht Teil von Phase 1):**
  „Meine Issues"/JQL-Filter, Quick-Kommentar direkt aus der Notification,
  Statuswechsel (Transitions), Worklog/Timetracking, globale Suche.

**Nicht-Ziele:** kein Admin/Projektkonfig, kein Board-Management, kein Ersatz
für die Weboberfläche bei komplexen Aktionen.

---

## 2. Tech-Stack

**Architekturprinzip: Hybrid — AppKit-Hülle, SwiftUI-Inhalte.** Die schwer zu
testenden, fehleranfälligen Teile (Menüleisten-Item mit Badge, Agent-Lifecycle,
Popover-Fenster) werden mit der deterministischen, langjährig stabilen
AppKit-API gebaut. Die dynamischen Inhalte (Timeline, Konversation, Settings)
mit SwiftUI, das Auto-Updates aus dem Store ohne manuelles Diffing liefert.
Begründung: maximale Stabilität dort, wo Eingreifen schwer ist (die App wird
ausschließlich von Claude gepflegt), minimaler Code dort, wo SwiftUI glänzt.

| Bereich | Wahl | Begründung |
| --- | --- | --- |
| Sprache | **Swift** + `async/await` | Eine Sprache für beide Frameworks |
| Menüleisten-Item + Badge | **AppKit `NSStatusItem`** (eigenes Badge-Drawing) | `MenuBarExtra` kann kein numerisches Badge; `NSStatusItem` ist voll kontrollierbar & stabil |
| Popover-Fenster | **AppKit `NSPopover`** (hostet SwiftUI via `NSHostingController`) | Größe/Verhalten deterministisch im Griff |
| App-Lifecycle / Agent | **AppKit `NSApplication` + `AppDelegate`**, `LSUIElement` | Hintergrund-Agent ohne Dock-Icon zuverlässig steuerbar |
| Inhalts-UI (Timeline/Detail/Settings) | **SwiftUI** (eingebettet via `NSHostingController`) | Deklarative Listen mit Auto-Updates, wenig Code |
| Daten → UI | **SwiftData + `@Observable`** | Updates fließen automatisch in die SwiftUI-Views |
| Push/Notification Center | **`UserNotifications`** Framework | Lokale Notifications inkl. Actions (Reply/Open) |
| Netzwerk | `URLSession` + `async/await` | Kein Dependency-Ballast |
| Persistenz | **SwiftData** | Lokaler Cache der Notification-Timeline & „gelesen"-Status |
| Secrets | **Keychain** (`kSecClassGenericPassword`) | API-Token / OAuth-Refresh-Token sicher ablegen |
| OAuth (optional) | `ASWebAuthenticationSession` | Für 3LO, falls Glocken-Feed genutzt wird |
| Min. Target | **macOS 14 (Sonoma)** | SwiftData & `@Observable` stabil |
| Distribution | Developer ID + Notarization (kein App-Store-Zwang) | Interne Verteilung möglich |

> Bewusst **kein** `MenuBarExtra` (pure SwiftUI): scheitert am numerischen Badge
> und hat versionsabhängige Popover-/Lifecycle-Eigenheiten, die ohne Live-Debug
> schwer zu beheben sind. Bewusst **kein** pures AppKit für die Inhalte: zu viel
> Boilerplate (NSTableView-Diffing) bei dynamisch aktualisierter Timeline.

---

## 3. Architektur (Überblick)

```
┌──────────────────────────────────────────────────────────────┐
│                         iJIRA.app                              │
│                                                                │
│  ┌────────────┐   ┌──────────────────┐   ┌─────────────────┐  │
│  │ NSStatusItem│   │ SwiftUI Views via │   │ UserNotifications│ │
│  │ (AppKit,   │◀──│ NSHostingController│──▶│   (Push ins      │ │
│  │ Badge) +   │   │ Timeline/Detail/   │   │ Notification Ctr)│ │
│  │ NSPopover  │   │ Settings           │   │                  │ │
│  └─────┬──────┘   └─────────┬────────┘   └────────▲────────┘  │
│        │                    │                      │           │
│        ▼                    ▼                      │           │
│  ┌──────────────────────────────────────────┐     │           │
│  │            NotificationStore               │─────┘           │
│  │  (SwiftData: Notification, ReadState)      │                 │
│  └───────────────▲────────────────▲──────────┘                 │
│                  │                │                             │
│        ┌─────────┴──────┐  ┌──────┴───────────┐                │
│        │  SyncEngine     │  │  Deduplicator/   │                │
│        │ (Scheduler/Poll)│  │  Normalizer      │                │
│        └───┬─────────┬───┘  └──────────────────┘                │
│            │         │                                          │
│   ┌────────┴───┐ ┌───┴───────────────┐                          │
│   │ RestSource │ │ BellFeedSource     │   ◀── austauschbare      │
│   │ (Polling)  │ │ (Notif-Platform)   │      NotificationSource  │
│   └─────┬──────┘ └─────────┬─────────┘                          │
│         │                  │                                    │
│   ┌─────┴──────────────────┴─────┐                              │
│   │       JiraClient (Auth)       │  Keychain ◀── Token         │
│   └───────────────────────────────┘                            │
└──────────────────────────────────────────────────────────────┘
```

Kernidee: Eine **`NotificationSource`-Protokoll-Abstraktion** kapselt „woher
kommen Notifications". Es gibt zwei Implementierungen (REST-Polling, Bell-Feed),
die beide normalisierte `IncomingNotification`-Events liefern. Die `SyncEngine`
führt beide Ströme zusammen, der `Deduplicator` entfernt Doppelungen, der
`NotificationStore` persistiert, und erst *neue* Einträge lösen UI-Update,
macOS-Push und Badge-Aktualisierung aus.

**Hybrid-Grenze (AppKit ⇄ SwiftUI):** Die AppKit-Hülle (`AppDelegate`,
`MenuBarController` mit `NSStatusItem`/`NSPopover`) besitzt das App-Fenster,
das Lifecycle und das Badge. Alle Inhaltsflächen sind SwiftUI-Views, die über
`NSHostingController` in den Popover bzw. ein `NSWindow` gehostet werden. Die
Views lesen reaktiv aus dem `@Observable NotificationStore` (SwiftData) — die
AppKit-Schicht muss UI-Updates also nicht manuell anstoßen, sie aktualisiert
nur das Badge anhand der ungelesen-Zahl.

---

## 4. Authentifizierung (Jira Cloud)

Zwei Verfahren, je nach genutzter Quelle:

### 4.1 API-Token (Basic Auth) — Pflicht für REST-Polling
- Nutzer legt unter <https://id.atlassian.com/manage-profile/security/api-tokens>
  ein Token an.
- In der App: **Site-URL** (`https://dein-team.atlassian.net`), **E-Mail**,
  **API-Token** eingeben.
- Request-Header: `Authorization: Basic base64(email:token)`.
- Token landet in der **Keychain**, nie im Klartext/Defaults.

### 4.2 OAuth 2.0 (3LO) — nur falls Bell-Feed genutzt wird
- Der echte Glocken-Feed der Notification-Platform ist **session-/cookie-basiert**
  und über ein reines API-Token **nicht** ansprechbar (siehe §5.2). Realistisch
  zugänglich wird er nur über einen authentifizierten OAuth-Flow.
- Flow via `ASWebAuthenticationSession`, Refresh-Token in der Keychain.
- **Empfehlung:** Phase 1 startet mit API-Token (REST). OAuth wird erst
  aktiviert, wenn der Bell-Feed-Mehrwert das rechtfertigt — die App ist auch
  ohne ihn voll funktionsfähig.

---

## 5. Notification-Quellen (kombiniert)

### 5.1 REST-Polling — das verlässliche Rückgrat

Da Jira Cloud **keine offiziell dokumentierte API für den persönlichen
Notification-Feed** hat, rekonstruieren wir „direkte Notifications" aus dem
dokumentierten, stabilen Issue-Search-API:

- **Endpoint:** `POST /rest/api/3/search/jql` (Enhanced Search; das alte
  `/rest/api/3/search` wird abgekündigt). Paginierung über `nextPageToken`.
- **JQL** (Beispiel — fängt alles ein, das mich betrifft und sich kürzlich
  geändert hat):
  ```
  (assignee = currentUser()
   OR watcher = currentUser()
   OR reporter = currentUser()
   OR mentioned = currentUser())     // 'mentioned' nur falls verfügbar
  AND updated >= "-7d"
  ORDER BY updated DESC
  ```
- **`expand=changelog`** bzw. der Bulk-Changelog-Endpoint liefert *was* sich
  geändert hat (Status, Assignee, Felder).
- **Kommentare:** pro betroffenem Issue `GET /rest/api/3/issue/{key}/comment`
  (seit letztem Sync), um neue Kommentare als eigene Timeline-Events zu erzeugen.
- **Delta-Erkennung:** Pro Issue merken wir den letzten gesehenen `updated`-
  Timestamp + letzte Comment-ID. Nur echte Neuigkeiten erzeugen Events.
- **Polling-Intervall:** adaptiv (z. B. 60 s im Vordergrund / aktiv, 5 min
  idle), respektiert `Retry-After` bei Rate-Limits (HTTP 429).

Vorteil: garantiert funktionsfähig, dokumentiert, nur API-Token nötig.
Grenze: kein Echtzeit-Push (Intervall-Latenz), „Notification" ist abgeleitet,
nicht 1:1 der Glocken-Eintrag.

### 5.2 Bell-Feed (Notification-Platform) — best effort

- Die Web-Glocke ruft eine **interne, undokumentierte** Atlassian-Notification-
  Platform auf (Gateway-Route der Form `…/gateway/api/notification-log/…`).
- **Risiken, ehrlich benannt:** undokumentiert → kann sich jederzeit ändern;
  i. d. R. **Cookie-/Session-gebunden** → mit reinem API-Token nicht nutzbar;
  über OAuth-Scopes nicht offiziell freigegeben.
- **Strategie:** Als optionale, gekapselte `BellFeedSource` implementieren,
  hinter einem Feature-Flag. Liefert sie Daten → näher am Original (echte
  Notification-Texte, gelesen-Status). Liefert sie nichts/Fehler → still
  degradieren, REST-Polling trägt die App allein.

### 5.3 Zusammenführung
- Beide Quellen emittieren `IncomingNotification` mit stabilem **Dedup-Key**
  (`issueKey + changeType + sourceTimestamp` bzw. `commentId`).
- `Deduplicator` verwirft bereits bekannte Keys (persistierter Key-Index).
- Bei Überschneidung gewinnt der reichhaltigere Bell-Eintrag (besserer Text),
  REST füllt Lücken.

---

## 6. Datenmodell (SwiftData)

```swift
@Model final class JiraNotification {
    @Attribute(.unique) var dedupKey: String   // siehe §5.3
    var issueKey: String                        // "ONE-8392"
    var issueSummary: String
    var kind: NotificationKind                  // comment | assigned | mention | statusChange | fieldChange
    var title: String                           // "Neuer Kommentar von …"
    var bodyPreview: String                     // gekürzter Text / ADF→plain
    var actorName: String
    var actorAvatarURL: URL?
    var webURL: URL                             // …/browse/KEY-123 (+ optional Kommentar-Anker)
    var createdAt: Date                         // Zeitpunkt des Events in Jira
    var receivedAt: Date                        // wann die App es sah
    var isRead: Bool
    var source: SourceKind                      // rest | bell
}

@Model final class SyncCursor {                 // pro Issue: Delta-Erkennung
    @Attribute(.unique) var issueKey: String
    var lastSeenUpdated: Date
    var lastSeenCommentId: String?
}
```

Gruppierung in der UI: Notifications werden **pro Issue als „Konversation"**
gebündelt (Messenger-Metapher) und chronologisch sortiert.

---

## 7. UI-Konzept (messenger-artig)

### 7.1 Menüleiste (`MenuBarExtra`)
- Icon-Zustände: **neutral** / **Badge mit ungelesener Anzahl** (z. B. blauer
  Punkt + Zahl). Bei neuen Notifications kurz hervorheben.
- Klick öffnet ein **Popover/Window** mit der Timeline (Style `.window` für mehr
  Platz, alternativ `.menu` für kompakt).

### 7.2 Timeline (Hauptansicht)
- Linke Spalte optional: **Konversationsliste** (pro Issue, neuester Eintrag
  oben, ungelesen fett + Punkt) — wie eine Messenger-Inbox.
- Rechts / Hauptbereich: **Chat-artiger Verlauf** der gewählten Konversation —
  Sprechblasen mit Avatar des Actors, Zeitstempel, Event-Typ-Icon.
- **Kommentare** werden als Nachrichtenblasen gerendert (ADF → attributierter
  Text, Mentions/Links erkannt).
- **Status-/Feld-Updates** als kompakte System-Zeilen („Status: In Progress →
  Done").
- Aktionen pro Eintrag: **„Im Web öffnen"** (öffnet `webURL`), „Als gelesen
  markieren". (Quick-Reply: spätere Phase.)

### 7.3 Interaktion
- Beim Öffnen einer Konversation → Einträge als gelesen markieren → Badge
  aktualisieren.
- „Alle als gelesen" im Header.
- Settings-Tab: Account (Site/E-Mail/Token), Polling-Intervall, Notification-
  Optionen, Bell-Feed-Toggle.

---

## 8. macOS-Push (Notification Center)

- **Framework:** `UserNotifications` (`UNUserNotificationCenter`).
- **Berechtigung:** beim ersten Start `requestAuthorization([.alert, .sound, .badge])`.
- **Pro neuer (ungelesener, nicht von mir selbst stammender) Notification** ein
  `UNNotificationRequest`:
  - Title: Issue-Key + Kurztext, Subtitle: Actor, Body: Preview.
  - `userInfo` enthält `dedupKey` + `webURL`.
- **Notification Actions:**
  - `OPEN_WEB` → öffnet Issue im Browser.
  - `MARK_READ` → markiert in der App als gelesen.
  - (später `REPLY` mit `UNTextInputNotificationAction` → Kommentar posten.)
- **Anti-Spam:** Beim Erststart / großem Backlog **kein** Massen-Push
  (Baseline still einlesen); Pushes nur für echte Deltas nach dem ersten Sync.
  Coalescing, wenn viele Events gleichzeitig kommen.
- **App-Badge** (Dock) optional zusätzlich zum Menüleisten-Badge.

---

## 9. Sync-Engine & Lifecycle

- **Scheduler:** Timer-basiert mit adaptivem Intervall (§5.1); zusätzlich Sync
  bei App-Aktivierung und beim Aufwachen aus dem Ruhezustand
  (`NSWorkspace.didWakeNotification`).
- **Hintergrundbetrieb:** App läuft als **Menüleisten-Agent**
  (`LSUIElement` / `MenuBarExtra` ohne Dock-Icon optional), pollt also auch ohne
  sichtbares Fenster.
- **Fehlerresilienz:** Exponential Backoff, `Retry-After`-Beachtung,
  Offline-Erkennung (`NWPathMonitor`), klare Fehler-/Reauth-Hinweise im UI.
- **Konsistenz:** `reconcileIssues`-Parameter des Search-APIs nutzen, um
  Index-Lag direkt nach Änderungen zu umgehen.

---

## 10. Sicherheit & Datenschutz

- Tokens **ausschließlich** in der Keychain; nichts in `UserDefaults`/Logs.
- Nur HTTPS; keine Telemetrie an Dritte.
- Lokaler Cache (SwiftData) in der App-Sandbox; „Account entfernen" löscht
  Keychain-Eintrag + lokalen Store.
- Minimal-Scopes bei OAuth (nur lesend, falls Bell-Feed).

---

## 11. Vorgeschlagene Projektstruktur

```
iJIRA/
├── iJIRA.xcodeproj
├── iJIRA/
│   ├── main.swift                  // @main: NSApplication + AppDelegate (LSUIElement)
│   ├── App/
│   │   ├── AppDelegate.swift       // Lifecycle, UNUserNotificationCenter-Delegate, Wake-Handling
│   │   ├── MenuBarController.swift  // NSStatusItem, eigenes Badge-Drawing, NSPopover
│   │   └── PopoverContentHosting.swift // NSHostingController ⇄ SwiftUI-Root
│   ├── Auth/
│   │   ├── KeychainStore.swift
│   │   ├── Credentials.swift
│   │   └── OAuthService.swift       // optional (Phase 1.5)
│   ├── Jira/
│   │   ├── JiraClient.swift         // URLSession, Auth-Header, Rate-Limit
│   │   ├── ADFRenderer.swift        // Atlassian Document Format → AttributedString
│   │   └── DTOs/                     // Codable-Modelle der Jira-Responses
│   ├── Notifications/
│   │   ├── NotificationSource.swift  // Protokoll
│   │   ├── RestSource.swift          // §5.1 Polling
│   │   ├── BellFeedSource.swift      // §5.2 best effort
│   │   ├── SyncEngine.swift
│   │   ├── Deduplicator.swift
│   │   └── PushPresenter.swift       // UserNotifications-Mapping
│   ├── Store/
│   │   ├── Models.swift              // SwiftData @Model (§6)
│   │   └── NotificationStore.swift
│   ├── Views/
│   │   ├── TimelineView.swift
│   │   ├── ConversationView.swift
│   │   ├── NotificationRow.swift
│   │   └── SettingsView.swift
│   └── Resources/ (Assets, MenuBar-Icons)
├── iJIRATests/
└── KONZEPT.md  (dieses Dokument)
```

---

## 12. Roadmap / Meilensteine

| M | Inhalt | Ergebnis |
| --- | --- | --- |
| **M0** | Xcode-Projekt, AppKit-Hülle (`NSStatusItem` + `NSPopover` + `LSUIElement`), erster SwiftUI-View via `NSHostingController`, Settings (Site/E-Mail/Token), Keychain, `JiraClient` mit `/myself`-Check | App startet als Menüleisten-Agent, verbindet, zeigt „verbunden als …" |
| **M1** | `RestSource` + `SyncEngine` + `NotificationStore`, JQL-Delta-Erkennung, Timeline-UI (read-only) | Notifications erscheinen in der App, auto-refresh |
| **M2** | `PushPresenter` (Notification Center) + Menüleisten-Badge + Actions (Open/Mark read), Anti-Spam-Baseline | Echte macOS-Pushes + Badge bei Neuem |
| **M3** | Messenger-Feinschliff: Konversations-Gruppierung, ADF-Rendering, Avatare, „alle gelesen", Backoff/Offline | Rundes Phase-1-Erlebnis |
| **M4** *(optional)* | OAuth + `BellFeedSource` hinter Feature-Flag | Näher am echten Glocken-Feed |
| **später** | Quick-Reply (Kommentar aus Notification), „Meine Issues"/JQL, Transitions | Phase 2 |

---

## 13. Offene Punkte & Risiken

1. **`mentioned`-JQL-Feld:** Verfügbarkeit/Genauigkeit für Mentions prüfen;
   ggf. über Kommentar-Body-Scan auf eigenen accountId ergänzen.
2. **Bell-Feed-Zugänglichkeit:** undokumentiert + cookie-gebunden → Machbarkeit
   per Spike testen, bevor M4 eingeplant wird. App darf nie davon abhängen.
3. **ADF-Rendering:** Atlassian Document Format ist verschachtelt; für Phase 1
   reicht ein robuster „ADF → Plain/AttributedString"-Reduzierer.
4. **Rate-Limits:** Bei vielen betroffenen Issues Comment-Fetch bündeln/drosseln.
5. **Erststart-Backlog:** Baseline-Sync ohne Push (sonst Benachrichtigungsflut).
6. **Self-Authored-Events:** eigene Kommentare/Änderungen nicht als Push zeigen.

---

## 14. Nächster Schritt

Wenn das Konzept passt, schlage ich vor, mit **M0** zu starten: Xcode-Projekt
anlegen, `MenuBarExtra`-Gerüst + Settings + Keychain + `JiraClient`/`/myself`-
Verbindungstest. Sag Bescheid, dann lege ich los (oder passe vorher einzelne
Punkte an).
```

Quellen zur Verifikation der API-Lage:
- [Jira Cloud REST – Issue Search](https://developer.atlassian.com/cloud/jira/platform/rest/v3/api-group-issue-search/)
- [In-app notifications (Atlassian Support)](https://support.atlassian.com/atlassian-cloud/kb/overview-of-in-app-notifications-in-atlassian-cloud-products/)
- [„Is there an API for the notifications within Jira?" (Dev Community)](https://community.developer.atlassian.com/t/is-there-an-api-for-the-notifications-within-jira/37659)
```
