# iJIRA

Native macOS-App, die die wichtigsten JIRA-Funktionen messenger-artig auf den Mac bringt.

## Download

**[Neueste Version herunterladen](../../releases/latest)** — notarisierte `.app`, läuft ohne Gatekeeper-Warnung.

Entpacken, in `/Applications` verschieben, starten.

## Features

- **JIRA-Notifications**: Direkte Notifications (neue Kommentare, Zuweisungen, Mentions) in einer Messenger-artigen Timeline.
- **Antworten**: Kommentare direkt aus der App verfassen, mit Markdown-Support (`code`, Code-Blöcke, **fett**, *kursiv*).
- **macOS Integration**: Automatische Aktualisierung mit echten macOS-Push-Benachrichtigungen (Notification Center) und Menüleisten-Icon mit Badge.
- **Leichtgewichtig**: Hybrid-App mit AppKit (`NSStatusItem`, `NSPopover`) für die Hülle und SwiftUI für die Inhalte.

## Entwicklung

Dieses Projekt verwendet [XcodeGen](https://github.com/yonaskolb/XcodeGen), um die Xcode-Projektdatei (`.xcodeproj`) aus der `project.yml` zu generieren.

### Voraussetzungen

- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- Xcode (macOS 14.0+)

### Projekt öffnen

```bash
xcodegen generate
open iJIRA.xcodeproj
```

### Release erstellen

```bash
# 1. Bauen, signieren, notarisieren
./scripts/notarize.sh

# 2. GitHub Release anlegen und .zip hochladen (Semver ohne v-Prefix)
gh release create 1.0.0 .build-release/iJIRA.zip --title "iJIRA 1.0.0"
```

Weitere Details zur Architektur finden sich in der [KONZEPT.md](KONZEPT.md).
