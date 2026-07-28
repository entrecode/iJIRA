import Foundation
import Observation

/// Datenquelle für „Review & Plan": meine Issues des laufenden Sprints, des
/// nächsten Sprints und die gar nicht eingeplanten — jeweils nach **Thema**
/// (Epic) gruppiert.
///
/// Zwei Eigenheiten prägen den Aufbau:
///
/// 1. **Thema = Epic.** Über einer Sub-Task steht aber eine Story, das Epic ist
///    erst deren Parent. `fields.parent` liefert nur eine Ebene, die
///    Großeltern werden daher gezielt nachgeladen (`Hierarchy`).
/// 2. **Zeit kommt aus Harvest, wenn Harvest konfiguriert ist** — dort wird
///    dann tatsächlich erfasst und die Jira-Worklogs sind nichtssagend. Ohne
///    Harvest sind die Jira-Worklogs die Quelle (bei uns aus Tempo
///    gespiegelt) — in beiden Fällen begrenzt auf den Sprintzeitraum, nie
///    `timespent`: das wäre die Gesamtzeit über alle Sprints.
///
/// Kein Hintergrund-Loop: Die Ansicht lädt beim Öffnen (bzw. per ⌘R) — sie ist
/// deutlich teurer als das Board und wird punktuell im Sprint Review gebraucht.
@MainActor
@Observable
final class ReviewStore {

    // MARK: - Anzeigemodell

    /// Eine Zeile innerhalb eines Themas. Sub-Tasks bekommen keine eigene
    /// Zeile, sondern hängen an ihrem Parent — ihre Zeit rollt mit hoch.
    struct Row: Codable, Identifiable, Sendable {
        var key: String
        var summary: String
        var typeName: String?
        var statusName: String?
        var statusCategoryKey: String?
        /// Status liegt in einer der beiden hintersten Board-Spalten.
        var isDone: Bool
        var seconds: Int
        /// Das Issue gehört selbst zur Auswahl. `false` bei Parents, die nur
        /// als Sammelzeile für ihre Sub-Tasks auftauchen (mir nicht zugewiesen
        /// oder nicht im Sprint).
        var isMine: Bool
        var subtasks: [Subtask]

        var id: String { key }

        struct Subtask: Codable, Identifiable, Sendable {
            var key: String
            var summary: String
            var statusName: String?
            var statusCategoryKey: String?
            var isDone: Bool
            var seconds: Int

            var id: String { key }
        }
    }

    /// Ein Thema = ein Epic (oder „Ohne Thema" für Issues ohne Epic).
    struct Theme: Codable, Identifiable, Sendable {
        var epicKey: String?
        var name: String
        var seconds: Int
        var rows: [Row]

        var id: String { epicKey ?? "__ohne__" }

        var doneRows: [Row] { rows.filter(\.isDone) }
        var openRows: [Row] { rows.filter { !$0.isDone } }
        var issueCount: Int { rows.reduce(0) { $0 + 1 + $1.subtasks.count } }
    }

    /// Woher die angezeigten Zeiten stammen — gehört in die Ansicht, damit im
    /// Review niemand über die Zahlen rätselt.
    enum TimeSource: String, Codable, Sendable {
        /// Harvest-Einträge im Sprintzeitraum (bevorzugt, wenn konfiguriert).
        case harvest
        /// Jira-Worklogs im Sprintzeitraum.
        case jiraWorklogs
        /// Sprintzeitraum unbekannt → Gesamtzeit am Issue (`timespent`).
        case jiraTotals
        /// Keine belastbare Quelle (z. B. Harvest aktiv, aber kein Sprint).
        case none

        var label: String {
            switch self {
            case .harvest: return "Harvest"
            case .jiraWorklogs: return "Jira-Worklogs"
            case .jiraTotals: return "Jira, Gesamtzeit"
            case .none: return "keine Zeitquelle"
            }
        }
    }

    struct Snapshot: Codable {
        var boardId: Int
        var sprintName: String?
        var sprintStart: Date?
        var sprintEnd: Date?
        var timeSource: TimeSource
        /// Kanban-Board: kennt keine Sprints, die Sprint-Blöcke bleiben leer.
        var supportsSprints: Bool
        /// Namen der beiden hintersten Board-Spalten („fertig").
        var doneColumnNames: [String]
        var currentThemes: [Theme]
        var nextSprintName: String?
        var nextThemes: [Theme]
        var unplannedThemes: [Theme]
        var fetchedAt: Date

        var currentSeconds: Int { currentThemes.reduce(0) { $0 + $1.seconds } }
    }

    // MARK: - Zustand

    private(set) var snapshots: [Int: Snapshot] = [:]
    private(set) var isLoading = false
    private(set) var lastError: String?

    /// Board-Auswahl wird mit dem Board-Tab geteilt.
    var selectedSnapshot: Snapshot? {
        boardStore.selectedBoardId.flatMap { snapshots[$0] }
    }

    /// Trigger für `.task(id:)` der Ansicht. Die Verbindung muss mit rein: beim
    /// Start ist der Tab da, bevor `AppState.restore()` durch ist — ohne den
    /// Verbindungs-Anteil würde der erste (erfolglose) Versuch nie wiederholt.
    var loadTrigger: String {
        "\(boardStore.selectedBoardId ?? -1)|\(appState.isConnected)"
    }

    private let appState: AppState
    let boardStore: BoardStore

    /// Ab wie vielen Minuten ein Snapshot beim Öffnen neu geladen wird.
    private static let staleAfter: TimeInterval = 300
    /// Obergrenze für Worklog-Nachschläge pro Lauf (Issues mit >20 Einträgen).
    private static let maxWorklogTopUps = 30

    init(appState: AppState, boardStore: BoardStore) {
        self.appState = appState
        self.boardStore = boardStore
        loadFromDisk()
    }

    // MARK: - Laden

    /// Beim Öffnen des Tabs: lädt, wenn nichts oder nur Veraltetes da ist.
    func loadIfNeeded() async {
        guard let boardId = boardStore.selectedBoardId else { return }
        if let snapshot = snapshots[boardId],
           Date().timeIntervalSince(snapshot.fetchedAt) < Self.staleAfter {
            return
        }
        await load()
    }

    func kickRefresh() {
        Task { await load(force: true) }
    }

    func load(force: Bool = false) async {
        guard let boardId = boardStore.selectedBoardId, let client = appState.currentClient() else {
            Log.app.info("Review: übersprungen (Board: \(self.boardStore.selectedBoardId != nil), verbunden: \(self.appState.isConnected))")
            return
        }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let started = Date()

        do {
            // Spalten des Boards → „fertig" sind die beiden hintersten.
            let columns = try await client.boardConfiguration(boardId: boardId).columnConfig.columns
            let doneColumns = Array(columns.suffix(2))
            let doneStatusIds = Set(doneColumns.flatMap { $0.statuses.map(\.id) })

            // Sprints: Kanban-Boards haben keine — und Jira antwortet dort auf
            // /board/{id}/sprint mit HTTP 400 statt einer leeren Liste. Deshalb
            // gar nicht fragen; bei Scrum-Boards Fehler tolerieren, damit die
            // Planungs-Blöcke auch dann stehen, wenn die Sprint-Abfrage kippt.
            let supportsSprints = boardStore.boards.first { $0.id == boardId }?.type != "kanban"
            var active: [SprintDTO] = []
            var next: SprintDTO?
            if supportsSprints {
                active = (try? await client.activeSprints(boardId: boardId)) ?? []
                next = try? await client.futureSprints(boardId: boardId).first
                if active.isEmpty {
                    Log.app.info("Review \(boardId): kein aktiver Sprint gefunden")
                }
            }
            let window = Self.window(for: active)

            // Zeitquelle vor den Issues klären: Harvest hat Vorrang, aber nur
            // wenn die Einträge auch wirklich ankommen — sonst holen wir die
            // Jira-Worklogs gleich mit (nachträglich wäre es ein Extra-Request
            // pro Issue).
            let harvest = HarvestState.shared
            let harvestEntries = harvest?.isConfigured == true
                ? await harvest?.timeEntries(force: force)
                : nil
            let useHarvest = harvestEntries != nil

            var current: [BoardIssueDTO] = []
            var seen = Set<String>()
            for sprint in active {
                for issue in try await client.myIssues(sprintId: sprint.id,
                                                       includeWorklogs: !useHarvest)
                where seen.insert(issue.key).inserted {
                    current.append(issue)
                }
            }

            let nextIssues = next == nil
                ? []
                : try await client.myIssues(sprintId: next!.id, includeWorklogs: false)

            let unplanned = try await client.myUnplannedIssues()

            // Themen-Auflösung: Epics über Stories nachladen.
            let hierarchy = await Self.buildHierarchy(client: client,
                                                      groups: [current, nextIssues, unplanned])

            // Zeit pro Issue im Sprintzeitraum.
            let timeSource = Self.timeSource(useHarvest: useHarvest, window: window)
            let seconds: [String: Int]
            if useHarvest {
                seconds = Self.harvestSeconds(entries: harvestEntries ?? [],
                                              issues: current, window: window)
            } else {
                // Worklog-Nachschlag für Issues mit mehr als 20 Einträgen.
                let extra = await Self.topUpWorklogs(client: client, issues: current,
                                                     window: window)
                seconds = Self.worklogSeconds(issues: current, window: window, extra: extra)
            }

            let snapshot = Snapshot(
                boardId: boardId,
                sprintName: active.isEmpty ? nil : active.map(\.name).joined(separator: " + "),
                sprintStart: window?.start,
                sprintEnd: window?.end,
                timeSource: timeSource,
                supportsSprints: supportsSprints,
                doneColumnNames: doneColumns.map(\.name),
                currentThemes: Self.themes(from: current, hierarchy: hierarchy,
                                           doneStatusIds: doneStatusIds, seconds: seconds,
                                           sortByTime: true),
                nextSprintName: next?.name,
                nextThemes: Self.themes(from: nextIssues, hierarchy: hierarchy,
                                        doneStatusIds: doneStatusIds, seconds: [:],
                                        sortByTime: false),
                unplannedThemes: Self.themes(from: unplanned, hierarchy: hierarchy,
                                             doneStatusIds: doneStatusIds, seconds: [:],
                                             sortByTime: false),
                fetchedAt: Date())

            snapshots[boardId] = snapshot
            persist(snapshot, boardId: boardId)
            lastError = nil
            Log.app.info("""
                Review \(boardId): \(current.count) Sprint-Issues in \
                \(snapshot.currentThemes.count) Themen, \(nextIssues.count) geplant, \
                \(unplanned.count) ohne Sprint, Zeit aus \
                \(timeSource.rawValue, privacy: .public) \
                (\(snapshot.currentSeconds / 60) min), \
                \(Date().timeIntervalSince(started), format: .fixed(precision: 1))s
                """)
        } catch is CancellationError {
        } catch {
            lastError = (error as? JiraError)?.userMessage ?? error.localizedDescription
            Log.app.error("Review \(boardId) fehlgeschlagen: \(self.lastError ?? "?", privacy: .public)")
        }
    }

    // MARK: - Sprintzeitraum

    /// Fenster über alle laufenden Sprints — auf **ganze Tage in Europe/Berlin**
    /// gedehnt. Grund: Jira-Sprints starten und enden mitten am Tag (Sprint 54
    /// begann am 22.07. um 16:58), Tempo bucht Zeiten aber teilweise
    /// tagesgenau um 00:00. Ohne das Dehnen fiele die Arbeit vom Starttag des
    /// Sprints heraus. `nil`, wenn Jira keine Sprintdaten liefert — dann zählt
    /// die Gesamtzeit am Issue (siehe `timesAreTotals`).
    private static func window(for sprints: [SprintDTO]) -> DateInterval? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .current
        let starts = sprints.compactMap(\.start).map { calendar.startOfDay(for: $0) }
        // Eine Sekunde vor dem Ende normalisieren: Sprints enden gern exakt auf
        // 00:00 Berlin (Sprint 54: 28.07. 22:00 UTC) — sonst zöge das Fenster
        // den kompletten Folgetag mit hinein.
        let ends = sprints.compactMap(\.end).compactMap {
            calendar.date(byAdding: .day, value: 1,
                          to: calendar.startOfDay(for: $0.addingTimeInterval(-1)))
        }
        guard let start = starts.min(), let end = ends.max(), start < end else { return nil }
        // Bis zur letzten Sekunde des Endtags (nicht 00:00 des Folgetags).
        return DateInterval(start: start, end: end.addingTimeInterval(-1))
    }

    // MARK: - Hierarchie (Thema = Epic)

    /// Index aller bekannten Issues — nötig, weil die Themen-Zuordnung die
    /// Hierarchie nach oben laufen muss (Sub-Task → Story → Epic).
    struct Hierarchy {
        struct Node {
            var key: String
            var summary: String
            var status: BoardIssueDTO.Status?
            var type: IssueTypeDTO?
            var parentKey: String?
            /// Ist das Parent dieses Knotens bekannt? Knoten, die nur aus
            /// `fields.parent` eines Kindes stammen, kennen ihr eigenes Parent
            /// (also das Epic) nicht — die müssen nachgeladen werden.
            var parentKnown: Bool
        }

        private(set) var nodes: [String: Node] = [:]

        /// Vollständig geladenes Issue: überschreibt einen etwaigen
        /// Platzhalter und registriert sein Parent als Platzhalter.
        mutating func add(_ issue: BoardIssueDTO) {
            nodes[issue.key] = Node(key: issue.key,
                                    summary: issue.fields.summary,
                                    status: issue.fields.status,
                                    type: issue.fields.issuetype,
                                    parentKey: issue.fields.parent?.key,
                                    parentKnown: true)
            if let parent = issue.fields.parent { addPlaceholder(parent) }
        }

        /// Parent aus `fields.parent`: genug für Anzeige und Typ-Erkennung,
        /// aber ohne eigenes Parent. Überschreibt nie einen geladenen Knoten.
        private mutating func addPlaceholder(_ parent: ParentRefDTO) {
            guard nodes[parent.key] == nil else { return }
            nodes[parent.key] = Node(key: parent.key,
                                     summary: parent.fields?.summary ?? parent.key,
                                     status: parent.fields?.status,
                                     type: parent.fields?.issuetype,
                                     parentKey: nil,
                                     parentKnown: false)
        }

        /// Knoten, deren Parent wir noch nicht kennen und die selbst kein Epic
        /// sind — genau die verstecken ein Thema.
        var keysNeedingLookup: [String] {
            nodes.values
                .filter { !$0.parentKnown && $0.type?.isEpicLevel != true }
                .map(\.key)
        }

        func node(_ key: String) -> Node? { nodes[key] }

        /// Erstes Issue auf Epic-Ebene, von `key` aus nach oben gesucht.
        func epicKey(for key: String) -> String? {
            var current: String? = key
            for _ in 0..<8 {
                guard let step = current, let node = nodes[step] else { return nil }
                if node.type?.isEpicLevel == true { return step }
                current = node.parentKey
            }
            return nil
        }

        /// Zeile, in der ein Issue erscheint: Sub-Tasks rollen in ihr Parent —
        /// außer das Parent ist selbst schon das Epic (dann wäre die Zeile das
        /// Thema selbst).
        func anchorKey(for issue: BoardIssueDTO) -> String {
            guard issue.fields.issuetype?.isSubtask == true,
                  let parentKey = issue.fields.parent?.key,
                  nodes[parentKey]?.type?.isEpicLevel != true
            else { return issue.key }
            return parentKey
        }
    }

    private static func buildHierarchy(client: JiraClient,
                                       groups: [[BoardIssueDTO]]) async -> Hierarchy {
        var hierarchy = Hierarchy()
        for group in groups {
            for issue in group { hierarchy.add(issue) }
        }
        // Eine Runde pro Hierarchie-Ebene. `attempted` verhindert Endlosschleifen,
        // wenn ein Key nicht (mehr) lesbar ist und deshalb ungelöst bleibt.
        var attempted = Set<String>()
        for _ in 0..<3 {
            let missing = hierarchy.keysNeedingLookup.filter { !attempted.contains($0) }
            guard !missing.isEmpty else { break }
            attempted.formUnion(missing)
            guard let fetched = try? await client.issues(keys: missing) else { break }
            for issue in fetched { hierarchy.add(issue) }
        }
        return hierarchy
    }

    // MARK: - Worklogs

    /// Für Issues, deren Worklog-Liste in der Suche abgeschnitten wurde, die
    /// Einträge ab Sprintbeginn nachladen.
    private static func topUpWorklogs(client: JiraClient, issues: [BoardIssueDTO],
                                      window: DateInterval?) async -> [String: [WorklogEntryDTO]] {
        guard let window else { return [:] }
        let truncated = issues.filter { $0.fields.worklog?.isTruncated == true }
        var result: [String: [WorklogEntryDTO]] = [:]
        for issue in truncated.prefix(maxWorklogTopUps) {
            // Ein paar Sekunden Luft nach vorn, damit Rundungen am Rand nicht
            // ausgerechnet den ersten Eintrag verschlucken.
            let after = window.start.addingTimeInterval(-1)
            if let entries = try? await client.worklogs(issueKey: issue.key, startedAfter: after) {
                result[issue.key] = entries
            }
        }
        if truncated.count > maxWorklogTopUps {
            Log.app.info("Review: \(truncated.count - maxWorklogTopUps) Worklog-Nachschläge übersprungen (Limit)")
        }
        return result
    }

    private static func worklogSeconds(issues: [BoardIssueDTO], window: DateInterval?,
                                       extra: [String: [WorklogEntryDTO]]) -> [String: Int] {
        var result: [String: Int] = [:]
        for issue in issues {
            // Ohne Sprintfenster gibt es keine sinnvolle Eingrenzung — dann
            // zählt die Gesamtzeit am Issue (die Ansicht weist darauf hin).
            guard let window else {
                result[issue.key] = issue.fields.timespent ?? 0
                continue
            }
            let entries = extra[issue.key] ?? issue.fields.worklog?.worklogs ?? []
            result[issue.key] = entries.reduce(0) { sum, entry in
                guard let started = entry.startedDate, window.contains(started) else { return sum }
                return sum + (entry.timeSpentSeconds ?? 0)
            }
        }
        return result
    }

    // MARK: - Harvest als Zeitquelle

    private static func timeSource(useHarvest: Bool, window: DateInterval?) -> TimeSource {
        switch (useHarvest, window != nil) {
        case (true, true): return .harvest
        case (true, false): return .none    // Harvest ohne Sprintzeitraum ⇒ nichts zu summieren
        case (false, true): return .jiraWorklogs
        case (false, false): return .jiraTotals
        }
    }

    /// Erkennt Jira-Keys in Harvest-Notizen (`ONE-1234`).
    private static let issueKeyRegex =
        try? NSRegularExpression(pattern: "\\b[A-Za-z][A-Za-z0-9]*-[0-9]+\\b")

    /// Harvest-Zeit pro Issue im Sprintzeitraum. Zuordnung wie beim
    /// Zeit-Button in der Issue-Ansicht: `external_reference.id` (von iJIRA
    /// bzw. dem offiziellen Plugin gesetzt) oder ein Jira-Key in den Notizen —
    /// so zählt auch direkt in Harvest erfasste Zeit.
    ///
    /// Anders als dort wird ein Eintrag hier **genau einem** Issue zugeordnet
    /// (dem ersten in den Notizen erwähnten bekannten Key). Sonst würde ein
    /// Eintrag, der mehrere Keys nennt, in jedem Thema mitzählen und die
    /// Summen aufblasen.
    private static func harvestSeconds(entries: [HarvestTimeEntry],
                                       issues: [BoardIssueDTO],
                                       window: DateInterval?) -> [String: Int] {
        guard let window else { return [:] }
        var keyByExternalId: [String: String] = [:]
        var knownKeys = Set<String>()
        for issue in issues {
            keyByExternalId[issue.id] = issue.key
            knownKeys.insert(issue.key.uppercased())
        }

        // Harvest datiert tagesgenau (`spent_date`), das Fenster ist ebenfalls
        // auf ganze Tage normalisiert — ISO-Datumsstrings lassen sich direkt
        // vergleichen, das erspart erneutes Zeitzonen-Rechnen.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Europe/Berlin")
        formatter.dateFormat = "yyyy-MM-dd"
        let fromDay = formatter.string(from: window.start)
        let toDay = formatter.string(from: window.end)

        var result: [String: Int] = [:]
        for entry in entries {
            guard let day = entry.spentDate, day >= fromDay, day <= toDay,
                  let hours = entry.hours
            else { continue }
            let seconds = Int((hours * 3600).rounded())
            if let id = entry.externalReference?.id, let key = keyByExternalId[id] {
                result[key, default: 0] += seconds
            } else if let key = firstKnownKey(in: entry.notes, knownKeys: knownKeys) {
                result[key, default: 0] += seconds
            }
        }
        return result
    }

    private static func firstKnownKey(in notes: String?, knownKeys: Set<String>) -> String? {
        guard let notes, let regex = issueKeyRegex else { return nil }
        let range = NSRange(notes.startIndex..., in: notes)
        for match in regex.matches(in: notes, range: range) {
            guard let matchRange = Range(match.range, in: notes) else { continue }
            let candidate = notes[matchRange].uppercased()
            if knownKeys.contains(candidate) { return candidate }
        }
        return nil
    }

    // MARK: - Gruppierung

    private static func themes(from issues: [BoardIssueDTO],
                               hierarchy: Hierarchy,
                               doneStatusIds: Set<String>,
                               seconds secondsByKey: [String: Int],
                               sortByTime: Bool) -> [Theme] {
        // 1. Zeilen bauen — Sub-Tasks rollen in ihr Parent.
        var rows: [String: Row] = [:]
        var rowOrder: [String] = []
        for issue in issues {
            let anchor = hierarchy.anchorKey(for: issue)
            guard let node = hierarchy.node(anchor) else { continue }
            let seconds = secondsByKey[issue.key] ?? 0

            if rows[anchor] == nil {
                rows[anchor] = Row(key: node.key,
                                   summary: node.summary,
                                   typeName: node.type?.name,
                                   statusName: node.status?.name,
                                   statusCategoryKey: node.status?.statusCategory?.key,
                                   isDone: doneStatusIds.contains(node.status?.id ?? ""),
                                   seconds: 0,
                                   isMine: false,
                                   subtasks: [])
                rowOrder.append(anchor)
            }
            rows[anchor]?.seconds += seconds
            if anchor == issue.key {
                rows[anchor]?.isMine = true
            } else {
                rows[anchor]?.subtasks.append(Row.Subtask(
                    key: issue.key,
                    summary: issue.fields.summary,
                    statusName: issue.fields.status?.name,
                    statusCategoryKey: issue.fields.status?.statusCategory?.key,
                    isDone: doneStatusIds.contains(issue.fields.status?.id ?? ""),
                    seconds: seconds))
            }
        }

        // 2. Zeilen nach Thema bündeln (Reihenfolge = Board-Rang).
        var themes: [String: Theme] = [:]
        var themeOrder: [String] = []
        for key in rowOrder {
            guard let row = rows[key] else { continue }
            let epicKey = hierarchy.epicKey(for: key)
            let id = epicKey ?? "__ohne__"
            if themes[id] == nil {
                themes[id] = Theme(epicKey: epicKey,
                                   name: epicKey.flatMap { hierarchy.node($0)?.summary } ?? "Ohne Thema",
                                   seconds: 0,
                                   rows: [])
                themeOrder.append(id)
            }
            themes[id]?.rows.append(row)
            themes[id]?.seconds += row.seconds
        }

        // 3. Sortieren: im Review nach geloggter Zeit, in der Planung nach
        //    Umfang. „Ohne Thema" ist ein Sammelbecken und bleibt unten, auch
        //    wenn es das größte ist.
        return themeOrder.compactMap { themes[$0] }.sorted { a, b in
            if (a.epicKey == nil) != (b.epicKey == nil) { return b.epicKey == nil }
            if sortByTime, a.seconds != b.seconds { return a.seconds > b.seconds }
            if a.issueCount != b.issueCount { return a.issueCount > b.issueCount }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    // MARK: - Persistenz

    private var cacheDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iJIRA/review", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func persist(_ snapshot: Snapshot, boardId: Int) {
        let url = cacheDirectory.appendingPathComponent("review-\(boardId).json")
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: url)
        }
    }

    private func loadFromDisk() {
        let decoder = JSONDecoder()
        let dir = cacheDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for file in files where file.hasPrefix("review-") && file.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(file)),
                  let snapshot = try? decoder.decode(Snapshot.self, from: data)
            else { continue }
            snapshots[snapshot.boardId] = snapshot
        }
        if !snapshots.isEmpty {
            Log.app.info("Review-Cache geladen: \(self.snapshots.count) Boards")
        }
    }
}

// MARK: - Zeitformat

extension Int {
    /// Sekunden als „4h 15m" / „3h" / „45m" / „–".
    var asWorkDuration: String {
        guard self > 0 else { return "–" }
        let minutes = (self / 60) % 60
        let hours = self / 3600
        if hours == 0 { return "\(minutes)m" }
        if minutes == 0 { return "\(hours)h" }
        return "\(hours)h \(minutes)m"
    }
}
