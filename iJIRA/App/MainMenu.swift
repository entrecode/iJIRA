import AppKit

/// Baut die vollständige macOS-Hauptmenüleiste. Sichtbar, sobald die App
/// via `ActivationPolicy` zur regulären App wird (Hauptfenster offen).
@MainActor
enum MainMenu {
    static func install(target: AppDelegate) {
        let main = NSMenu()

        // MARK: iJIRA
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Über iJIRA",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: "Einstellungen …",
                                  action: #selector(AppDelegate.openSettings(_:)),
                                  keyEquivalent: ",")
        settings.target = target
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "iJIRA ausblenden",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Andere ausblenden",
                                         action: #selector(NSApplication.hideOtherApplications(_:)),
                                         keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Alle einblenden",
                        action: #selector(NSApplication.unhideAllApplications(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "iJIRA beenden",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        // MARK: Ablage
        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: "Ablage")
        let newIssue = NSMenuItem(title: "Neues Issue …",
                                  action: #selector(AppDelegate.newIssue(_:)), keyEquivalent: "n")
        newIssue.target = target
        fileMenu.addItem(newIssue)
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Fenster schließen",
                         action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu

        // MARK: Bearbeiten — Standard-Key-Equivalents über die Responder-Chain.
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Bearbeiten")
        editMenu.addItem(withTitle: "Widerrufen", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Wiederholen", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Ausschneiden", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Kopieren", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Einsetzen", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Alles auswählen", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        // Wirkt aufs vorderste Issue (Einzelfenster oder Issue-Tab); der
        // AppDelegate graut den Eintrag sonst über validateMenuItem aus.
        let copyLink = NSMenuItem(title: "Link zum Issue kopieren",
                                  action: #selector(AppDelegate.copyIssueLink(_:)),
                                  keyEquivalent: "c")
        copyLink.keyEquivalentModifierMask = [.command, .shift]
        copyLink.target = target
        editMenu.addItem(copyLink)
        editItem.submenu = editMenu

        // MARK: Ansicht
        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: "Ansicht")
        let board = NSMenuItem(title: "Board",
                               action: #selector(AppDelegate.showBoardTab(_:)), keyEquivalent: "1")
        board.target = target
        viewMenu.addItem(board)
        let issue = NSMenuItem(title: "Issue",
                               action: #selector(AppDelegate.showIssueTab(_:)), keyEquivalent: "2")
        issue.target = target
        viewMenu.addItem(issue)
        let review = NSMenuItem(title: "Review & Plan",
                                action: #selector(AppDelegate.showReviewTab(_:)), keyEquivalent: "3")
        review.target = target
        viewMenu.addItem(review)
        viewMenu.addItem(.separator())
        let refresh = NSMenuItem(title: "Aktualisieren",
                                 action: #selector(AppDelegate.refreshCurrentTab(_:)), keyEquivalent: "r")
        refresh.target = target
        viewMenu.addItem(refresh)
        viewItem.submenu = viewMenu

        // MARK: Fenster
        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Fenster")
        windowMenu.addItem(withTitle: "Im Dock ablegen",
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        let mainWindow = NSMenuItem(title: "Hauptfenster",
                                    action: #selector(AppDelegate.showMainWindow(_:)), keyEquivalent: "0")
        mainWindow.target = target
        windowMenu.addItem(mainWindow)
        windowMenu.addItem(.separator())
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        // MARK: Hilfe
        let helpItem = NSMenuItem()
        main.addItem(helpItem)
        let helpMenu = NSMenu(title: "Hilfe")
        helpItem.submenu = helpMenu
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = main
    }
}
