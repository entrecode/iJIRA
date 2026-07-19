# M5 — Hauptfenster, Navigation, Menüleiste, Einstellungs-Fenster

## Ziel

Ein echtes Hauptfenster mit zwei Tabs (**Board** | **Issue**), umschaltbar
über einen Segmented Control ganz oben. Board ist die Start-Ansicht. Dazu
eine richtige macOS-Menüleiste und ein eigenständiges Einstellungs-Fenster
(Jira-Verbindung raus aus dem Menüleisten-Popover).

## 1. Aktivierungs-Policy (Kernproblem zuerst)

Die App ist `LSUIElement` (Accessory) — Accessory-Apps haben **keine**
System-Menüleiste und kein Dock-Icon. Lösung: dynamische Policy.

```swift
// App/ActivationPolicy.swift
@MainActor enum ActivationPolicy {
    /// Hauptfenster/Settings sichtbar → .regular (Menüleiste + Dock-Icon).
    static func windowBecameVisible() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
    }
    /// Letztes „richtiges" Fenster zu → zurück zum Menüleisten-Agenten.
    static func windowClosed() {
        let visible = NSApp.windows.contains {
            $0.isVisible && ($0.identifier?.rawValue.hasPrefix("main") == true
                             || $0.identifier?.rawValue.hasPrefix("settings") == true
                             || $0.identifier?.rawValue.hasPrefix("issue-") == true)
        }
        if !visible { NSApp.setActivationPolicy(.accessory) }
    }
}
```

- Aufruf aus `windowWillClose`-Delegates (MainWindow, Settings,
  IssueWindowManager) und beim Öffnen.
- `applicationShouldHandleReopen` (Klick aufs Dock-Icon / App im Finder
  öffnen) → Hauptfenster zeigen.
- **Startverhalten:** `applicationDidFinishLaunching` öffnet das
  Hauptfenster, AUSSER `UserDefaults` `startInMenuBarOnly == true`
  (Default: an, sobald Login-Item aktiv — Setting „Beim Start nur in der
  Menüleiste" im Allgemein-Tab). So bleibt der Autostart unsichtbar,
  manuelles Öffnen zeigt das Fenster.

## 2. MainWindowController + Navigation

Neue Dateien unter `iJIRA/MainWindow/`:

### `MainWindowController.swift`
- Singleton analog `IssueWindowManager` (`configure(appState:)`,
  `show()`, `showBoard()`, `showIssue(key:)`).
- `NSWindow` wie Issue-Fenster (transparente Titlebar,
  `fullSizeContentView`), `setFrameAutosaveName("MainWindow")`,
  Mindestgröße 900×640, identifier `main`.
- Hält `MainWindowModel`.

### `MainWindowModel.swift` (@MainActor @Observable)
```swift
enum MainTab: String { case board, issue }
final class MainWindowModel {
    var tab: MainTab                       // persistiert: "mainTab"
    var currentIssueKey: String?           // persistiert: "lastIssueKey"
    private var issueModels: [String: IssueDetailModel]  // LRU, max 8
    func openIssue(_ key: String)          // Model holen/erzeugen, tab = .issue
    func issueModel(for key: String) -> IssueDetailModel
}
```
- LRU verhindert unbegrenztes Wachsen; Modelle behalten Thumbnails etc. →
  Issue-Wechsel ist sofort.

### `MainWindowView.swift`
```
┌──────────────────────────────────────────────────────────────┐
│ ●●●   [ Board | Issue ]        [Suchfeld………………]  ⟳  ⚙︎        │  ← Header
├──────────────────────────────────────────────────────────────┤
│ Tab-Inhalt: BoardView  ODER  IssueDetailContent               │
└──────────────────────────────────────────────────────────────┘
```
- Header: 66 pt Ampel-Abstand, `Picker(.segmented)` mit ⌘1/⌘2-Shortcuts,
  dann **immer sichtbares** `IssueSearchField` (bestehend — öffnet ab jetzt
  via `MainWindowModel.openIssue` statt neuem Fenster), Refresh, Settings-
  Zahnrad (öffnet Einstellungs-Fenster).
- Tab „Issue" ohne je geöffnetes Issue → Empty-State: zentriertes großes
  Suchfeld + Hinweistext („Key oder Link einfügen …").
- Tab „Issue" mit `currentIssueKey` → `IssueDetailContent(model:)`.

### Refactor `IssueDetailView`
- Aufteilen in `IssueDetailContent` (Scroll-Inhalt + Sektionen + DnD,
  ohne eigenen Header/Backdrop) und dünnen Fenster-Wrapper
  `IssueDetailWindowView` (Backdrop + bisheriger Header) für die
  weiterhin möglichen Einzelfenster.
- Der Fenster-Header entfällt im Hauptfenster; Key-Chip + Status-Badge +
  Web-Link wandern in eine schmale Zeile ÜBER dem Titel im
  `IssueDetailContent` (Key bleibt kopierbar — Anforderung).

### Routing-Änderung `IssueWindowManager`
```swift
func open(issueKey: String, preferWindow: Bool = false) {
    if preferWindow { /* bisheriger Einzelfenster-Pfad */ }
    else { MainWindowController.shared.showIssue(key: key) }
}
```
- Alle bestehenden Aufrufer (Menüleiste, Ticket-Karten, Suche, Deep-Link)
  laufen damit automatisch ins Hauptfenster.
- ⌥-Klick auf Issue-Karten/Links → `preferWindow: true` (Einzelfenster).

## 3. macOS-Menüleiste

Neue Datei `App/MainMenu.swift`, ersetzt `installMainMenu()` im AppDelegate:

- **iJIRA**: Über iJIRA (Standard-Panel) · Einstellungen … ⌘, ·
  iJIRA ausblenden ⌘H · Andere ausblenden ⌥⌘H · iJIRA beenden ⌘Q
- **Ablage**: Neues Issue-Fenster … ⇧⌘N (öffnet Suchfeld-Empty-State in
  Einzelfenster) · Fenster schließen ⌘W
- **Bearbeiten**: Standard (Widerrufen/Wiederholen/Ausschneiden/Kopieren/
  Einsetzen/Alles auswählen — bestehender Code)
- **Ansicht**: Board ⌘1 · Issue ⌘2 · Aktualisieren ⌘R ·
  Nächstes Board ⌃⇥ (optional M6)
- **Fenster**: Im Dock ablegen ⌘M · Hauptfenster ⌘0 · (System-Fensterliste)
- **Hilfe**: iJIRA-Hilfe (öffnet README/Repo)

Target-Actions gehen an `MainWindowController.shared` bzw. First Responder;
`validateMenuItem` deaktiviert Board/Issue-Einträge, wenn kein Hauptfenster
offen ist.

## 4. Einstellungs-Fenster

Neue Dateien `Settings/SettingsWindowController.swift`,
`Settings/SettingsView.swift`:

- `NSWindow` (Toolbar-Stil `.preference`, nicht resizable, identifier
  `settings`), SwiftUI `TabView`:
  - **Verbindung** — 1:1 der bisherige `settingsForm` aus `RootView`
    (Site-URL, E-Mail, API-Token, Verbinden/Trennen, Status-Banner).
  - **Harvest** — siehe [04-harvest.md](04-harvest.md).
  - **Allgemein** — Login-Item-Toggle (bestehend), „Beim Start nur in der
    Menüleiste", Purge-Fenster (Tage) optional.
- `RootView` (Menüleisten-Popover): Settings-Bereich ersetzen durch
  Status-Banner + Button „Einstellungen öffnen …" →
  `SettingsWindowController.shared.show()`. Das Zahnrad im Popover-Header
  bleibt, zeigt aber das Fenster.
- `AppState` bleibt die eine Quelle der Verbindungs-Wahrheit — das
  Settings-Fenster bindet an dieselben `@Bindable`-Felder.

## 5. Geänderte/neue Dateien (Übersicht)

| Datei | Änderung |
|---|---|
| `App/ActivationPolicy.swift` | neu |
| `App/MainMenu.swift` | neu (ersetzt installMainMenu) |
| `App/AppDelegate.swift` | MainWindow/Settings konfigurieren, Reopen-Handling, Startverhalten |
| `MainWindow/MainWindowController.swift` | neu |
| `MainWindow/MainWindowModel.swift` | neu |
| `MainWindow/MainWindowView.swift` | neu |
| `IssueView/IssueDetailView.swift` | Split in Content/WindowWrapper |
| `IssueView/IssueWindowManager.swift` | Routing ins Hauptfenster, ⌥-Fenster |
| `Settings/SettingsWindowController.swift` | neu |
| `Settings/SettingsView.swift` | neu (Form aus RootView extrahiert) |
| `Views/RootView.swift` | Settings-Form raus, Button rein |

## 6. Edge-Cases

- Popover offen + Hauptfenster öffnet → Popover schließen
  (`popover.performClose`), sonst kämpfen zwei Key-Windows.
- ⌘W im Hauptfenster schließt das Fenster, App läuft als Agent weiter
  (kein Quit) — Policy-Rückfall prüfen.
- Deep-Link bei geschlossenem Hauptfenster → Fenster öffnen, Tab Issue.
- Verbindung getrennt: Board-Tab zeigt Empty-State mit Button
  „Einstellungen öffnen".

## 7. Verifikation

- `open "ijira://issue/KEY"` → Log „Hauptfenster: Tab issue, KEY"
  (neue Log-Zeile in `MainWindowModel.openIssue`).
- `osascript`-frei prüfbar: Policy-Wechsel loggen
  („ActivationPolicy → regular/accessory").
- Manuell: ⌘1/⌘2, ⌘,, ⌘W, Dock-Klick, Popover-Zahnrad.
