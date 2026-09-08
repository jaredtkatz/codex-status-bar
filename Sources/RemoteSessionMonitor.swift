import Foundation

/// Mirrors lifecycle-only state from Codex Desktop's configured SSH projects.
///
/// Codex runs remote SSH threads on the remote host, so their rollout files never appear in this
/// Mac's ~/.codex/sessions directory. This monitor reads the host aliases Codex already stores in
/// .codex-global-state.json, then uses non-interactive SSH to inspect only session metadata and
/// task lifecycle event names. It never reads prompt or response bodies and never starts another
/// Codex app-server.
final class RemoteSessionMonitor {
    struct Host: Equatable {
        let id: String
        let alias: String
        let label: String
    }

    typealias SnapshotProvider = (_ host: Host) -> Data?

    private let globalStateURL: URL
    private let stateRoot: URL
    private let customSnapshotProvider: SnapshotProvider?
    private let queue = DispatchQueue(label: "com.nickxma.codexstatusbar.remote-monitor", qos: .utility)
    private let lock = NSLock()
    private var nextPoll: TimeInterval = 0
    private var pollInFlight = false
    private var retryAfter: [String: TimeInterval] = [:]
    private var activeProcesses: [pid_t: Process] = [:]
    private var cachedConfiguration = Configuration(hosts: [], assignments: [:])
    private var configurationModifiedAt: Date?
    private var configurationSize: UInt64?
    private let pollInterval: TimeInterval
    private let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let isoBasic = ISO8601DateFormatter()

    init(
        globalStateURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/.codex-global-state.json"),
        stateRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/statusbar/state.d", isDirectory: true),
        pollInterval: TimeInterval = 5,
        snapshotProvider: SnapshotProvider? = nil
    ) {
        self.globalStateURL = globalStateURL
        self.stateRoot = stateRoot
        self.pollInterval = pollInterval
        self.customSnapshotProvider = snapshotProvider
    }

    func poll(enabled: Bool, now: TimeInterval = Date().timeIntervalSince1970) {
        guard enabled else { return }
        lock.lock()
        guard !pollInFlight, now >= nextPoll else {
            lock.unlock()
            return
        }
        pollInFlight = true
        nextPoll = now + pollInterval
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            defer {
                self.lock.lock()
                self.pollInFlight = false
                self.lock.unlock()
            }
            let configuration = self.loadConfiguration()
            for host in configuration.hosts {
                let assignedThreadIDs = configuration.assignments[host.id] ?? []
                guard !assignedThreadIDs.isEmpty else { continue }
                guard now >= self.retryAfter[host.id, default: 0] else { continue }
                let snapshot: Data?
                if let provider = self.customSnapshotProvider {
                    snapshot = provider(host)
                } else {
                    snapshot = self.fetchSnapshot(host: host)
                }
                guard let data = snapshot else {
                    // A 1Password-backed SSH agent may require physical approval. Do not create
                    // recurring approval prompts: after one bounded failure, leave this host alone
                    // until the status app is relaunched.
                    self.retryAfter[host.id] = .greatestFiniteMagnitude
                    continue
                }
                self.retryAfter[host.id] = nil
                self.applySnapshot(data, host: host, assignedThreadIDs: assignedThreadIDs)
            }
        }
    }

    func stop() {
        lock.lock()
        let processes = Array(activeProcesses.values)
        activeProcesses.removeAll()
        lock.unlock()
        for process in processes where process.isRunning { process.terminate() }
    }

    private struct Configuration {
        var hosts: [Host]
        var assignments: [String: Set<String>]
    }

    private func loadConfiguration() -> Configuration {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: globalStateURL.path),
              let modifiedAt = attributes[.modificationDate] as? Date,
              let size = (attributes[.size] as? NSNumber)?.uint64Value else {
            cachedConfiguration = Configuration(hosts: [], assignments: [:])
            configurationModifiedAt = nil
            configurationSize = nil
            return cachedConfiguration
        }
        if configurationModifiedAt == modifiedAt, configurationSize == size {
            return cachedConfiguration
        }
        guard let data = try? Data(contentsOf: globalStateURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return cachedConfiguration
        }

        var hosts: [Host] = []
        if let rows = root["codex-managed-remote-connections"] as? [[String: Any]] {
            for row in rows {
                guard let id = row["hostId"] as? String,
                      id.hasPrefix("remote-ssh-"),
                      let alias = row["alias"] as? String, !alias.isEmpty else { continue }
                let label = (row["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? alias
                hosts.append(Host(id: id, alias: alias, label: label))
            }
        }

        var assignments: [String: Set<String>] = [:]
        if let rows = root["thread-project-assignments"] as? [String: Any] {
            for (threadID, value) in rows {
                guard let row = value as? [String: Any],
                      row["projectKind"] as? String == "remote",
                      let hostID = row["hostId"] as? String else { continue }
                assignments[hostID, default: []].insert(threadID)
            }
        }
        cachedConfiguration = Configuration(hosts: hosts, assignments: assignments)
        configurationModifiedAt = modifiedAt
        configurationSize = size
        return cachedConfiguration
    }

    private func fetchSnapshot(host: Host) -> Data? {
        let fm = FileManager.default
        let controlRoot = fm.homeDirectoryForCurrentUser.appendingPathComponent(".codex/statusbar/ssh", isDirectory: true)
        try? fm.createDirectory(at: controlRoot, withIntermediateDirectories: true)
        let controlPath = controlRoot.appendingPathComponent("%C").path
        let command = #"root="${CODEX_HOME:-$HOME/.codex}"; printf '__CODEX_STATUS_INDEX__\n'; tail -n 2000 "$root/session_index.jsonl" 2>/dev/null || true; printf '__CODEX_STATUS_SESSIONS__\n'; find "$root/sessions" -type f -name 'rollout-*.jsonl' -mmin -35 -print 2>/dev/null | while IFS= read -r f; do printf '__CODEX_STATUS_FILE__%s\n' "$f"; grep -E '"type":"session_meta"|"type":"(task_started|task_complete|task_cancelled|turn_aborted)"' "$f" 2>/dev/null | tail -n 24; done"#

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        let quotedCommand = "'" + command.replacingOccurrences(of: "'", with: "'\\''") + "'"
        process.arguments = [
            "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=4",
            "-o", "ConnectionAttempts=1", "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=1", "-o", "ControlMaster=auto",
            "-o", "ControlPersist=60", "-o", "ControlPath=\(controlPath)",
            host.alias, "sh -c \(quotedCommand)",
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            lock.lock()
            activeProcesses[process.processIdentifier] = process
            lock.unlock()
            defer {
                lock.lock()
                activeProcesses[process.processIdentifier] = nil
                lock.unlock()
            }
            let completed = DispatchSemaphore(value: 0)
            let reader = DispatchGroup()
            let resultLock = NSLock()
            var result = Data()
            reader.enter()
            DispatchQueue.global(qos: .utility).async {
                let data = output.fileHandleForReading.readDataToEndOfFile()
                resultLock.lock()
                result = data
                resultLock.unlock()
                reader.leave()
            }
            process.terminationHandler = { _ in completed.signal() }
            guard completed.wait(timeout: .now() + 10) == .success else {
                process.terminate()
                if completed.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                    Darwin.kill(process.processIdentifier, SIGKILL)
                }
                _ = completed.wait(timeout: .now() + 1)
                reader.wait()
                return nil
            }
            reader.wait()
            resultLock.lock()
            let data = result
            resultLock.unlock()
            return process.terminationStatus == 0 ? data : nil
        } catch {
            return nil
        }
    }

    private struct Cursor {
        var id = ""
        var cwd = ""
        var threadSource = ""
        var state: [String: Any] = [:]
    }

    private func applySnapshot(_ data: Data, host: Host, assignedThreadIDs: Set<String>) {
        let text = String(decoding: data, as: UTF8.self)
        var titles: [String: String] = [:]
        var cursor: Cursor?

        func finish(_ candidate: Cursor?) {
            guard let candidate, !candidate.id.isEmpty, !candidate.state.isEmpty,
                  assignedThreadIDs.contains(candidate.id) else { return }
            write(candidate.state, sessionID: candidate.id)
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line == "__CODEX_STATUS_INDEX__" || line == "__CODEX_STATUS_SESSIONS__" { continue }
            if line.hasPrefix("__CODEX_STATUS_FILE__") {
                finish(cursor)
                let path = String(line.dropFirst("__CODEX_STATUS_FILE__".count))
                cursor = Cursor(id: sessionID(from: path))
                continue
            }
            guard let object = parse(line) else { continue }
            if cursor == nil {
                if let id = object["id"] as? String,
                   let title = object["thread_name"] as? String,
                   !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    titles[id] = title
                }
                continue
            }
            guard var current = cursor, let type = object["type"] as? String,
                  let payload = object["payload"] as? [String: Any] else { continue }
            if type == "session_meta" {
                current.id = payload["id"] as? String ?? current.id
                current.cwd = payload["cwd"] as? String ?? current.cwd
                current.threadSource = payload["thread_source"] as? String ?? current.threadSource
                cursor = current
                continue
            }
            guard type == "event_msg", let event = payload["type"] as? String else { continue }
            let timestamp = (object["timestamp"] as? String).flatMap(parseTimestamp)
                ?? Date().timeIntervalSince1970
            let fallback = remoteDisplayName(host: host, cwd: current.cwd)
            let project = titles[current.id] ?? fallback
            switch event {
            case "task_started":
                current.state = makeState(current, host: host, state: "thinking", label: "Thinking…",
                                          project: project, timestamp: timestamp, startedAt: timestamp,
                                          turnID: payload["turn_id"] as? String ?? "")
            case "task_complete":
                current.state = makeState(current, host: host, state: "done", label: "Done",
                                          project: project, timestamp: timestamp, startedAt: 0,
                                          turnID: payload["turn_id"] as? String ?? "")
            case "task_cancelled", "turn_aborted":
                current.state = makeState(current, host: host, state: "idle", label: "",
                                          project: project, timestamp: timestamp, startedAt: 0,
                                          turnID: payload["turn_id"] as? String ?? "")
            default: break
            }
            cursor = current
        }
        finish(cursor)
    }

    private func makeState(_ cursor: Cursor, host: Host, state: String, label: String,
                           project: String, timestamp: Double, startedAt: Double,
                           turnID: String) -> [String: Any] {
        [
            "state": state, "label": label, "project": project,
            "indexedTitle": project != remoteDisplayName(host: host, cwd: cursor.cwd),
            "threadSource": cursor.threadSource, "cwd": cursor.cwd,
            "sessionId": cursor.id, "turnId": turnID, "remoteHost": host.label,
            "transcript": "", "surface": "codex-desktop", "term_program": "",
            "pid": 0, "started": true, "startedAt": startedAt, "ts": timestamp,
            "activeAgents": [String](), "tool": "",
        ]
    }

    private func remoteDisplayName(host: Host, cwd: String) -> String {
        let folder = cwd.isEmpty ? "Codex" : URL(fileURLWithPath: cwd).lastPathComponent
        return folder.isEmpty || folder == host.label ? host.label : "\(host.label) · \(folder)"
    }

    private func sessionID(from path: String) -> String {
        let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let parts = stem.split(separator: "-")
        guard parts.count >= 6 else { return stem }
        return parts.suffix(5).joined(separator: "-")
    }

    private func write(_ state: [String: Any], sessionID: String) {
        try? FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)
        let safeID = sessionID.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "_" }
        let url = stateRoot.appendingPathComponent(String(safeID) + ".json")
        CodexStateStore.write(state, to: url)
    }

    private func parse(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func parseTimestamp(_ value: String) -> TimeInterval? {
        (isoFractional.date(from: value) ?? isoBasic.date(from: value))?.timeIntervalSince1970
    }
}
