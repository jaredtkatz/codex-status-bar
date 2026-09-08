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
        let updatedAt: TimeInterval

        init(id: String, hostID: String, title: String, cwd: String, updatedAt: TimeInterval = 0) {
            self.id = id
            self.hostID = hostID
            self.title = title
            self.cwd = cwd
            self.updatedAt = updatedAt
        }
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
    private var observationTime: TimeInterval = 0
    private var latestEventTimes: [String: TimeInterval] = [:]
    private var catalog: [String: Task] = [:]
    private var catalogLoadedAt: TimeInterval = 0
    private var logOffsets: [String: UInt64] = [:]
    private var pendingStates: [String: (state: String, timestamp: TimeInterval)] = [:]
    private var cachedLogFiles: [URL] = []
    private var logFilesLoadedAt: TimeInterval = 0
    let liveMonitor: DesktopLiveStatusMonitor?
    private let iso = ISO8601DateFormatter()

    init(
        databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sqlite/codex-dev.db"),
        logsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/com.openai.codex", isDirectory: true),
        stateRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/statusbar/state.d", isDirectory: true),
        catalogProvider: CatalogProvider? = nil,
        snapshotProvider: SnapshotProvider? = nil,
        liveMonitor: DesktopLiveStatusMonitor? = nil
    ) {
        self.databaseURL = databaseURL
        self.logsRoot = logsRoot
        self.stateRoot = stateRoot
        self.customCatalogProvider = catalogProvider
        self.customSnapshotProvider = snapshotProvider
        self.liveMonitor = liveMonitor
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
            self.observationTime = now
            if self.catalog.isEmpty || now - self.catalogLoadedAt >= 5 {
                let tasks = self.customCatalogProvider?() ?? self.loadCatalog()
                self.catalog = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
                self.catalogLoadedAt = now
                self.reconcileCatalog(now: now)
                self.applyPendingStates()
            }
            if let snapshot = self.customSnapshotProvider?() {
                self.apply(snapshot: snapshot)
            }
            self.consumeDesktopLogs(self.currentLogFiles(now: now))
            let candidates = self.catalog.values.filter { task in
                if now - task.updatedAt <= 48 * 60 * 60 { return true }
                guard let old = self.readState(self.stateURL(task.id)),
                      let state = old["state"] as? String else { return false }
                return StatusPolicy.shouldShowInMenu(state)
            }
            if let states = self.liveMonitor?.poll(tasks: candidates, now: now) {
                for (id, state) in states {
                    guard let task = self.catalog[id], state != "unknown" else { continue }
                    if state == "idle" {
                        self.finishIfOlder(task: task, timestamp: now)
                    } else {
                        self.upsert(task: task, state: state, timestamp: now, preserveWorking: true)
                    }
                }
            }
        }
    }

    private func loadCatalog() -> [Task] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else { return [] }
        defer { sqlite3_close(database) }
        let sql = """
        SELECT c.thread_id, c.host_id, c.display_title, c.cwd, c.source_updated_at
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
            let task = Task(
                id: text(0), hostID: text(1), title: text(2), cwd: text(3),
                updatedAt: sqlite3_column_double(statement, 4)
            )
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
                guard let id = field("conversationId", in: line) else { continue }
                let eventTime = timestamp(from: line) ?? Date().timeIntervalSince1970
                if line.contains("response_routed"), line.contains("method=turn/start"),
                   line.contains("errorCode=null") {
                    remember(id: id, state: "thinking", timestamp: eventTime)
                } else if line.contains("Received turn/completed") {
                    remember(id: id, state: "done", timestamp: eventTime)
                }
            }
        }
        if let latestSnapshot { apply(snapshot: latestSnapshot) }
    }

    /// Codex 0.149 stopped logging the old schema-v4 aggregate `list_threads` payload. The catalog
    /// remains the exact title source, and its source_updated_at supplies recent-history recency.
    /// Reconcile that durable metadata with lifecycle edges from Desktop logs and rollout monitors
    /// so title changes never depend on the retired aggregate log shape.
    private func reconcileCatalog(now: TimeInterval) {
        for task in catalog.values {
            let url = stateURL(task.id)
            guard let old = readState(url) else {
                continue
            }
            refreshMetadata(task: task, old: old, url: url)
        }
        pendingStates = pendingStates.filter { now - $0.value.timestamp <= StatusPolicy.activeInactivityTimeout }
    }

    private func remember(id: String, state: String, timestamp: TimeInterval) {
        if state == "thinking", observationTime - timestamp > StatusPolicy.activeInactivityTimeout { return }
        if let old = latestEventTimes[id], old >= timestamp { return }
        latestEventTimes[id] = timestamp
        pendingStates[id] = (state, timestamp)
        guard let task = catalog[id] else { return }
        applyPendingState(id: id, task: task)
    }

    private func applyPendingStates() {
        for (id, task) in catalog where pendingStates[id] != nil {
            applyPendingState(id: id, task: task)
        }
    }

    private func applyPendingState(id: String, task: Task) {
        guard let pending = pendingStates[id] else { return }
        pendingStates[id] = nil
        if pending.state == "thinking" {
            upsert(task: task, state: "thinking", timestamp: pending.timestamp, preserveWorking: false)
        } else {
            finishIfOlder(task: task, timestamp: pending.timestamp)
        }
    }

    private func refreshMetadata(task: Task, old: [String: Any], url: URL) {
        let oldProject = old["project"] as? String ?? ""
        let oldCwd = old["cwd"] as? String ?? ""
        let oldHost = old["remoteHost"] as? String ?? ""
        let host = hostLabel(task.hostID)
        guard oldProject != task.title || oldCwd != task.cwd || oldHost != host
                || old["indexedTitle"] as? Bool != true else { return }
        var updated = old
        updated["project"] = task.title
        updated["cwd"] = task.cwd
        updated["remoteHost"] = host
        updated["indexedTitle"] = true
        updated["threadSource"] = "registry"
        CodexStateStore.write(updated, to: url)
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
        let hostLabel = hostLabel(task.hostID)
        let payload: [String: Any] = [
            "state": state, "label": state == "done" ? "Done" : "Thinking…",
            "project": task.title, "indexedTitle": true, "threadSource": "registry",
            "cwd": task.cwd, "sessionId": task.id, "turnId": "", "remoteHost": hostLabel,
            "transcript": "", "surface": "codex-desktop", "term_program": "",
            "pid": 0, "started": true, "startedAt": startedAt, "ts": timestamp,
            "activeAgents": [String](), "tool": "",
        ]
        CodexStateStore.write(payload, to: stateURL(task.id))
    }

    private func hostLabel(_ hostID: String) -> String {
        if hostID == "local" { return "" }
        if hostID.hasPrefix("remote-control:") { return "Remote Control" }
        return String(hostID.split(separator: ":").last ?? "Remote")
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
