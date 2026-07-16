import os

/// Zentrale `os.Logger`-Instanzen. Feldprobleme („lief 3 Tage, dann nichts
/// mehr") lassen sich damit nachträglich auswerten:
/// `log show --last 3d --predicate 'subsystem == "de.entrecode.iJIRA"'`
enum Log {
    private static let subsystem = "de.entrecode.iJIRA"

    static let sync = Logger(subsystem: subsystem, category: "sync")
    static let store = Logger(subsystem: subsystem, category: "store")
    static let app = Logger(subsystem: subsystem, category: "app")
}
