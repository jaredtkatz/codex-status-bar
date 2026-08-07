import Foundation
import SQLite3

/// Reconciles the status menu with Codex Desktop's own cross-host task catalog.
///
/// The catalog supplies stable task identity, title, host, and helper/automation filtering. The
/// desktop log supplies the aggregate active/idle snapshot used by `list_threads`, plus lifecycle
/// edges for Remote Control tasks whose rollout files live on another Mac and cannot be read here.
/// Local and SSH rollout monitors remain the preferred source for detailed state and completion.
final class DesktopTaskRegistryMonitor {
    struct Task: Equatable {
        let id: String
        let hostID: String
        let title: String
        let cwd: String
    }

    struct Snapshot: Equatable {
        let observedAt: TimeInterval
        let statuses: [String: String]
        let tasks: [Task]

        init(observedAt: TimeInterval, statuses: [String: String], tasks: [Task] = []) {
            self.observedAt = observedAt
            self.statuses = statuses
            self.tasks = tasks
        }
    }

    typealias CatalogProvider = () -> [Task]
    typealias SnapshotProvider = () -> Snapshot?

    private let databaseURL: URL
    private let logsRoot: URL
    private let stateRoot: URL
    private let customCatalogProvider: CatalogProvider?
    private let customSnapshotProvider: SnapshotProvider?
    private let queue = DispatchQueue(label: "com.nickxma.codexstatusbar.task-registry", qos: .utility)
    private let lock = NSLock()
    private var pollInFlight = false
    private var nextPoll: TimeInterval = 0
    private var catalog: [String: Task] = [:]
    private var catalogLoadedAt: TimeInterval = 0
    private var logOffsets: [String: UInt64] = [:]
    private var cachedLogFiles: [URL] = []
    private var logFilesLoadedAt: TimeInterval = 0
    private let iso = ISO8601DateFormatter()

    init(
        databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sqlite/codex-dev.db"),
        logsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/com.openai.codex", isDirectory: true),
        stateRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/statusbar/state.d", isDirectory: true),
        catalogProvider: CatalogProvider? = nil,
        snapshotProvider: SnapshotProvider? = nil
    ) {
        self.databaseURL = databaseURL
        self.logsRoot = logsRoot
        self.stateRoot = stateRoot
        self.customCatalogProvider = catalogProvider
        self.customSnapshotProvider = snapshotProvider
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func poll(enabled: Bool, now: TimeInterval = Date().timeIntervalSince1970) {
        guard enabled else { return }
        lock.lock()
        guard !pollInFlight, now >= nextPoll else { lock.unlock(); return }
        pollInFlight = true
        nextPoll = now + 1
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            defer { self.lock.lock(); self.pollInFlight = false; self.lock.unlock() }
            if self.catalog.isEmpty || now - self.catalogLoadedAt >= 30 {
                let tasks = self.customCatalogProvider?() ?? self.loadCatalog()
                self.catalog = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
                self.catalogLoadedAt = now
            }
            if let snapshot = self.customSnapshotProvider?() {
                self.apply(snapshot: snapshot)
            }
            self.consumeDesktopLogs(self.currentLogFiles(now: now))
        }
    }

    private func loadCatalog() -> [Task] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else { return [] }
        defer { sqlite3_close(database) }
        let sql = """
        SELECT c.thread_id, c.host_id, c.display_title, c.cwd
        FROM local_thread_catalog c
        LEFT JOIN automation_runs a ON a.thread_id = c.thread_id
        WHERE c.missing_candidate = 0 AND a.thread_id IS NULL
          AND c.display_title <> ''
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        var tasks: [Task] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func text(_ column: Int32) -> String {
                guard let value = sqlite3_column_text(statement, column) else { return "" }
                return String(cString: value)
            }
            let task = Task(id: text(0), hostID: text(1), title: text(2), cwd: text(3))
            if !task.id.isEmpty, task.hostID == "local" || task.hostID.hasPrefix("remote-") {
                tasks.append(task)
            }
        }
        return tasks
    }

    private func currentLogFiles(now: TimeInterval) -> [URL] {
        if logFilesLoadedAt > 0, now - logFilesLoadedAt < 5 { return cachedLogFiles }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: logsRoot, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            cachedLogFiles = []
            logFilesLoadedAt = now
            return []
        }
        let cutoff = Date(timeIntervalSince1970: now - 36 * 60 * 60)
        cachedLogFiles = enumerator.compactMap { item -> URL? in
            guard let url = item as? URL, url.pathExtension == "log",
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  (values.contentModificationDate ?? .distantPast) >= cutoff else { return nil }
            return url
        }
        logFilesLoadedAt = now
        return cachedLogFiles
    }

    private func parseAggregateLine(_ line: String) -> Snapshot? {
        guard let responseRange = line.range(of: " response="),
              let responseData = String(line[responseRange.upperBound...]).data(using: .utf8),
              let response = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let items = response["contentItems"] as? [[String: Any]],
              let text = items.first?["text"] as? String,
              let data = text.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              payload["schemaVersion"] as? Int == 4,
              let rows = payload["threads"] as? [[String: Any]] else { return nil }
        let pinned = payload["pinnedThreads"] as? [[String: Any]] ?? []
        var statuses: [String: String] = [:]
        var tasks: [Task] = []
        for row in pinned + rows where row["kind"] as? String == "codex" {
            guard let id = row["id"] as? String, let status = row["status"] as? String else { continue }
            let summary = row["summary"] as? String ?? ""
            guard !summary.contains("Automation ID:") else { continue }
            statuses[id] = status
            if let hostID = row["hostId"] as? String,
               let title = row["title"] as? String,
               !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                tasks.append(Task(id: id, hostID: hostID, title: title, cwd: row["cwd"] as? String ?? ""))
            }
        }
        return Snapshot(
            observedAt: timestamp(from: line) ?? Date().timeIntervalSince1970,
            statuses: statuses,
            tasks: tasks
        )
    }

    private func apply(snapshot: Snapshot) {
        for task in snapshot.tasks { catalog[task.id] = task }
        for (id, status) in snapshot.statuses {
            guard let task = catalog[id] else { continue }
            if status == "active" {
                upsert(task: task, state: "thinking", timestamp: snapshot.observedAt, preserveWorking: true)
            } else if status == "idle" || status == "notLoaded" {
                finishIfOlder(task: task, timestamp: snapshot.observedAt)
            }
        }
    }

    private func consumeDesktopLogs(_ logFiles: [URL]) {
        var latestSnapshot: Snapshot?
        for url in logFiles {
            let path = url.path
            guard let handle = try? FileHandle(forReadingFrom: url),
                  let size = try? handle.seekToEnd() else { continue }
            defer { try? handle.close() }
            let initialWindow: UInt64 = 12 * 1024 * 1024
            let offset = logOffsets[path] ?? (size > initialWindow ? size - initialWindow : 0)
            if size < offset { logOffsets[path] = 0; continue }
            try? handle.seek(toOffset: offset)
            guard let data = try? handle.readToEnd() else { continue }
            logOffsets[path] = size
            for raw in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                let line = String(raw)
                if line.contains("\\\"schemaVersion\\\":4"), line.contains("\\\"threads\\\""),
                   let snapshot = parseAggregateLine(line),
                   latestSnapshot == nil || snapshot.observedAt > latestSnapshot!.observedAt {
                    latestSnapshot = snapshot
                }
                guard let id = field("conversationId", in: line), let task = catalog[id],
                      task.hostID.hasPrefix("remote-control:") else { continue }
                let eventTime = timestamp(from: line) ?? Date().timeIntervalSince1970
                if line.contains("Reasoning summary turn-start config resolved") {
                    upsert(task: task, state: "thinking", timestamp: eventTime, preserveWorking: false)
                } else if line.contains("IAB_LIFECYCLE ended browser use session activity") {
                    finishIfOlder(task: task, timestamp: eventTime)
                }
            }
        }
        if let latestSnapshot { apply(snapshot: latestSnapshot) }
    }

    private func upsert(task: Task, state: String, timestamp: TimeInterval, preserveWorking: Bool) {
        let url = stateURL(task.id)
        if let old = readState(url) {
            if let oldTime = old["ts"] as? Double, oldTime > timestamp { return }
            if preserveWorking, let oldState = old["state"] as? String,
               ["thinking", "tool", "subagent", "permission"].contains(oldState) { return }
        }
        var startedAt = timestamp
        if let old = readState(url), let oldStarted = old["startedAt"] as? Double, oldStarted > 0,
           let oldState = old["state"] as? String,
           ["thinking", "tool", "subagent", "permission"].contains(oldState) {
            startedAt = oldStarted
        }
        write(task: task, state: state, timestamp: timestamp, startedAt: startedAt)
    }

    private func finishIfOlder(task: Task, timestamp: TimeInterval) {
        let url = stateURL(task.id)
        guard let old = readState(url), let oldTime = old["ts"] as? Double, oldTime <= timestamp,
              let oldState = old["state"] as? String,
              ["thinking", "tool", "subagent", "permission"].contains(oldState) else { return }
        write(task: task, state: "done", timestamp: timestamp, startedAt: 0)
    }

    private func write(task: Task, state: String, timestamp: TimeInterval, startedAt: TimeInterval) {
        try? FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)
        let hostLabel: String
        if task.hostID == "local" { hostLabel = "" }
        else if task.hostID.hasPrefix("remote-control:") { hostLabel = "Remote Control" }
        else { hostLabel = String(task.hostID.split(separator: ":").last ?? "Remote") }
        let payload: [String: Any] = [
            "state": state, "label": state == "done" ? "Done" : "Thinking…",
            "project": task.title, "indexedTitle": true, "threadSource": "registry",
            "cwd": task.cwd, "sessionId": task.id, "turnId": "", "remoteHost": hostLabel,
            "transcript": "", "surface": "codex-desktop", "term_program": "",
            "pid": 0, "started": true, "startedAt": startedAt, "ts": timestamp,
            "activeAgents": [String](), "tool": "",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
        try? data.write(to: stateURL(task.id), options: .atomic)
    }

    private func stateURL(_ id: String) -> URL {
        let safe = id.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "_" }
        return stateRoot.appendingPathComponent(String(safe) + ".json")
    }

    private func readState(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func field(_ name: String, in line: String) -> String? {
        guard let range = line.range(of: "\(name)=") else { return nil }
        let tail = line[range.upperBound...]
        return tail.prefix { !$0.isWhitespace }.isEmpty ? nil : String(tail.prefix { !$0.isWhitespace })
    }

    private func timestamp(from line: String) -> TimeInterval? {
        guard let token = line.split(separator: " ").first else { return nil }
        return iso.date(from: String(token))?.timeIntervalSince1970
    }
}
