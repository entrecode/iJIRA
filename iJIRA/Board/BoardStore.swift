import Foundation
import Observation

/// Hält Boards, Board-Snapshots (Spalten + eigene Issues) und die
/// Backlog-Liste. Cache-first: alles wird als JSON persistiert und beim
/// Start sofort gerendert; Refreshes laufen still im Hintergrund.
/// Alle Boards werden vorab geladen — der Dropdown-Wechsel trifft dadurch
/// immer einen fertigen Snapshot (keine Ladezeit).
@MainActor
@Observable
final class BoardStore {
    struct ColumnSnapshot: Codable, Identifiable {
        var name: String
        var statusIds: [String]
        var issues: [BoardIssueDTO]
        var id: String { name }
    }

    struct BoardSnapshot: Codable {
        var boardId: Int
        var columns: [ColumnSnapshot]
        var sprintName: String?
        var sprintIds: [Int]
        var fetchedAt: Date
    }

    private(set) var boards: [BoardDTO] = []
    private(set) var snapshots: [Int: BoardSnapshot] = [:]
    private(set) var backlog: [BoardIssueDTO] = []
    private(set) var lastError: String?
    private(set) var isRefreshing = false

    var selectedBoardId: Int? {
        didSet {
            if let selectedBoardId {
                UserDefaults.standard.set(selectedBoardId, forKey: Self.selectedKey)
            }
        }
    }

    var selectedSnapshot: BoardSnapshot? {
        selectedBoardId.flatMap { snapshots[$0] }
    }

    var selectedBoard: BoardDTO? {
        boards.first { $0.id == selectedBoardId }
    }

    /// Anzeigenamen fürs Dropdown: nur der Boardname; bei Duplikaten wird
    /// der Projekt-Key angehängt, damit sie unterscheidbar bleiben.
    var boardDisplayNames: [Int: String] {
        var counts: [String: Int] = [:]
        for board in boards { counts[board.name, default: 0] += 1 }
        var names: [Int: String] = [:]
        for board in boards {
            if counts[board.name, default: 0] > 1, let key = board.location?.projectKey {
                names[board.id] = "\(board.name) · \(key)"
            } else {
                names[board.id] = board.name
            }
        }
        return names
    }

    private let appState: AppState
    private var loopTask: Task<Void, Never>?

    private static let selectedKey = "selectedBoardId"
    private static let activeInterval: TimeInterval = 60
    private static let fullInterval: TimeInterval = 600

    init(appState: AppState) {
        self.appState = appState
        let stored = UserDefaults.standard.integer(forKey: Self.selectedKey)
        selectedBoardId = stored == 0 ? nil : stored
        loadFromDisk()
    }

    // MARK: - Lifecycle

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task {
            await refreshAll()
            var sinceFull: TimeInterval = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.activeInterval * 1_000_000_000))
                if Task.isCancelled { break }
                sinceFull += Self.activeInterval
                if sinceFull >= Self.fullInterval {
                    sinceFull = 0
                    await refreshAll()
                } else {
                    await refreshSelected()
                }
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// Manueller Refresh (⌘R): aktives Board + Backlog sofort.
    func kickRefresh() {
        Task { await refreshSelected(includeBacklog: true) }
    }

    // MARK: - Refresh

    /// Boardliste + Snapshots ALLER Boards + Backlog (Prefetch fürs Dropdown).
    func refreshAll() async {
        guard let client = appState.currentClient(), !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let loaded = try await client.allBoards()
            boards = loaded
            persist(boards, to: "boards.json")
            if selectedBoardId == nil || !loaded.contains(where: { $0.id == selectedBoardId }) {
                selectedBoardId = loaded.first?.id
            }
            Log.app.info("Boards: \(loaded.count) geladen")
            lastError = nil
        } catch {
            lastError = (error as? JiraError)?.userMessage ?? error.localizedDescription
            Log.app.error("Boardliste fehlgeschlagen: \(self.lastError ?? "?", privacy: .public)")
        }

        // Aktives Board zuerst (sichtbar), dann die restlichen, dann Backlog.
        if let selectedBoardId {
            await refreshSnapshot(boardId: selectedBoardId)
        }
        for board in boards where board.id != selectedBoardId {
            guard !Task.isCancelled else { return }
            await refreshSnapshot(boardId: board.id)
            // Sanfte Drosselung gegen Rate-Limits beim Prefetch.
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        await refreshBacklog()
    }

    func refreshSelected(includeBacklog: Bool = false) async {
        if let selectedBoardId {
            await refreshSnapshot(boardId: selectedBoardId)
        }
        if includeBacklog {
            await refreshBacklog()
        }
    }

    private func refreshSnapshot(boardId: Int) async {
        guard let client = appState.currentClient() else { return }
        let started = Date()
        do {
            let config = try await client.boardConfiguration(boardId: boardId)
            let board = boards.first { $0.id == boardId }

            var issues: [BoardIssueDTO] = []
            var sprintName: String?
            var sprintIds: [Int] = []
            if board?.type == "kanban" {
                issues = try await client.myBoardIssues(boardId: boardId)
            } else {
                let sprints = try await client.activeSprints(boardId: boardId)
                sprintIds = sprints.map(\.id)
                sprintName = sprints.isEmpty ? nil : sprints.map(\.name).joined(separator: " + ")
                for sprint in sprints {
                    issues += try await client.mySprintIssues(sprintId: sprint.id)
                }
            }

            var columns = config.columnConfig.columns.map {
                ColumnSnapshot(name: $0.name, statusIds: $0.statuses.map(\.id), issues: [])
            }
            var unmatched: [BoardIssueDTO] = []
            for issue in issues {
                if let index = columns.firstIndex(where: {
                    $0.statusIds.contains(issue.fields.status?.id ?? "")
                }) {
                    columns[index].issues.append(issue)
                } else {
                    unmatched.append(issue)
                }
            }
            if !unmatched.isEmpty {
                columns.append(ColumnSnapshot(name: "Sonstige", statusIds: [], issues: unmatched))
            }

            let snapshot = BoardSnapshot(boardId: boardId, columns: columns,
                                         sprintName: sprintName, sprintIds: sprintIds,
                                         fetchedAt: Date())
            snapshots[boardId] = snapshot
            persist(snapshot, to: "board-\(boardId).json")
            lastError = nil
            let duration = Date().timeIntervalSince(started)
            Log.app.info("Board \(boardId) aktualisiert: \(issues.count) Issues, \(columns.count) Spalten, \(duration, format: .fixed(precision: 1))s")
        } catch is CancellationError {
        } catch {
            lastError = (error as? JiraError)?.userMessage ?? error.localizedDescription
            Log.app.error("Board \(boardId) fehlgeschlagen: \(self.lastError ?? "?", privacy: .public)")
        }
    }

    private func refreshBacklog() async {
        guard let client = appState.currentClient() else { return }
        do {
            backlog = try await client.myOpenIssuesOutsideSprints()
            persist(backlog, to: "backlog.json")
            Log.app.info("Backlog aktualisiert: \(self.backlog.count) Issues")
        } catch is CancellationError {
        } catch {
            lastError = (error as? JiraError)?.userMessage ?? error.localizedDescription
        }
    }

    // MARK: - Drag & Drop (M7)

    /// Verschiebt ein Issue optimistisch in die Zielspalte und führt die
    /// passende Workflow-Transition aus. Rollback bei Fehler.
    func move(issueKey: String, toColumn columnName: String) async {
        guard let boardId = selectedBoardId,
              var snapshot = snapshots[boardId],
              let targetIndex = snapshot.columns.firstIndex(where: { $0.name == columnName }),
              let sourceIndex = snapshot.columns.firstIndex(where: { $0.issues.contains { $0.key == issueKey } }),
              sourceIndex != targetIndex,
              let issueIndex = snapshot.columns[sourceIndex].issues.firstIndex(where: { $0.key == issueKey }),
              let client = appState.currentClient()
        else { return }

        let target = snapshot.columns[targetIndex]
        let original = snapshots[boardId]

        // Optimistisch verschieben.
        let issue = snapshot.columns[sourceIndex].issues.remove(at: issueIndex)
        snapshot.columns[targetIndex].issues.append(issue)
        snapshots[boardId] = snapshot

        do {
            let transitions = try await client.transitions(issueKey: issueKey)
            let candidates = transitions.filter {
                guard let toId = $0.to?.id else { return false }
                return target.statusIds.contains(toId)
            }
            // Bevorzugt der erste Status der Spalte, sonst erster Kandidat.
            let transition = candidates.first { $0.to?.id == target.statusIds.first }
                ?? candidates.first
            guard let transition else {
                throw JiraError.http(status: 0)
            }
            try await client.applyTransition(issueKey: issueKey, transitionId: transition.id)
            Log.app.info("DnD \(issueKey, privacy: .public) → \(columnName, privacy: .public) via Transition \(transition.id, privacy: .public)")
            await refreshSnapshot(boardId: boardId)
        } catch {
            snapshots[boardId] = original
            if case JiraError.http(0) = error {
                lastError = "Kein Workflow-Übergang nach ‚\(columnName)' möglich."
            } else {
                lastError = (error as? JiraError)?.userMessage ?? error.localizedDescription
            }
            Log.app.error("DnD \(issueKey, privacy: .public) → \(columnName, privacy: .public) fehlgeschlagen")
        }
    }

    // MARK: - Persistenz

    private var cacheDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iJIRA/boards", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func persist<T: Encodable>(_ value: T, to filename: String) {
        let url = cacheDirectory.appendingPathComponent(filename)
        if let data = try? JSONEncoder().encode(value) {
            try? data.write(to: url)
        }
    }

    private func loadFromDisk() {
        let decoder = JSONDecoder()
        let dir = cacheDirectory
        if let data = try? Data(contentsOf: dir.appendingPathComponent("boards.json")),
           let loaded = try? decoder.decode([BoardDTO].self, from: data) {
            boards = loaded
        }
        if let data = try? Data(contentsOf: dir.appendingPathComponent("backlog.json")),
           let loaded = try? decoder.decode([BoardIssueDTO].self, from: data) {
            backlog = loaded
        }
        for board in boards {
            if let data = try? Data(contentsOf: dir.appendingPathComponent("board-\(board.id).json")),
               let snapshot = try? decoder.decode(BoardSnapshot.self, from: data) {
                snapshots[board.id] = snapshot
            }
        }
        if !boards.isEmpty {
            Log.app.info("Board-Cache geladen: \(self.boards.count) Boards, \(self.snapshots.count) Snapshots")
        }
        if selectedBoardId == nil { selectedBoardId = boards.first?.id }
    }
}
