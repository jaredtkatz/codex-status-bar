import Foundation
import AppKit
import Darwin

/// Converts Codex Desktop's local lifecycle stream into small local state files.
/// Only event names and session metadata are inspected; message content is ignored.
final class DesktopSessionMonitor {
    private struct Cursor {
        var offset: UInt64
        var sessionID: String
        var cwd: String
        var threadSource: String
        var state: [String: Any]
    }

    private let sessionsRoot: URL
    private let stateRoot: URL
    private let titleIndexURL: URL
    private let pidProvider: () -> pid_t
    private var titles: [String: String] = [:]
    private var titleWatcher: DispatchSourceFileSystemObject?
    private var cursors: [String: Cursor] = [:]
    private var fileWatchers: [String: DispatchSourceFileSystemObject] = [:]
    private var directoryWatchers: [String: DispatchSourceFileSystemObject] = [:]
    private var lastDirectoryRefresh: TimeInterval = 0
    private var lastHistoricalRefresh: TimeInterval = 0
    private var nextRefreshRequest: TimeInterval = 0
    private let refreshRequestLock = NSLock()
    private let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let isoBasic = ISO8601DateFormatter()
    private let queue = DispatchQueue(label: "com.nickxma.codexstatusbar.desktop-monitor", qos: .utility)

    init(
        sessionsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true),
        stateRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/statusbar/state.d", isDirectory: true),
        titleIndexURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/session_index.jsonl"),
        pidProvider: @escaping () -> pid_t = {
            NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.openai.codex" }?.processIdentifier ?? 0
        }
    ) {
        self.sessionsRoot = sessionsRoot
        self.stateRoot = stateRoot
        self.titleIndexURL = titleIndexURL
        self.pidProvider = pidProvider
    }

    deinit {
        for source in fileWatchers.values { source.cancel() }
        for source in directoryWatchers.values { source.cancel() }
        titleWatcher?.cancel()
    }

    func poll(now: TimeInterval = Date().timeIntervalSince1970) {
        refreshRequestLock.lock()
        guard now >= nextRefreshRequest else {
            refreshRequestLock.unlock()
            return
        }
        nextRefreshRequest = now + 5
        refreshRequestLock.unlock()
        queue.async { [weak self] in self?.refreshDirectories(now: now) }
    }

    private func refreshDirectories(now: TimeInterval) {
        guard directoryWatchers.isEmpty || now - lastDirectoryRefresh >= 5 else { return }
        lastDirectoryRefresh = now
        watchTitleIndex()
        var candidates = Set<URL>()
        for zone in [TimeZone.current, TimeZone(secondsFromGMT: 0)!] {
            for dayOffset in [-86_400, 0, 86_400] {
                let components = Calendar(identifier: .gregorian).dateComponents(
                    in: zone,
                    from: Date(timeIntervalSince1970: now + Double(dayOffset))
                )
                guard let year = components.year, let month = components.month, let day = components.day else { continue }
                candidates.insert(sessionsRoot
                    .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
                    .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
                    .appendingPathComponent(String(format: "%02d", day), isDirectory: true))
            }
        }
        for directory in candidates { watchDirectory(directory) }
        // A task can remain active for days or weeks after its rollout file was created. The
        // date-bucket watchers above catch new work cheaply; this bounded modification-time scan
        // reconnects old-origin tasks after app launch without reading old transcript contents.
        if lastHistoricalRefresh == 0 || now - lastHistoricalRefresh >= 5 * 60 {
            lastHistoricalRefresh = now
            discoverRecentlyModifiedFiles(now: now)
        }
    }

    private func discoverRecentlyModifiedFiles(now: TimeInterval) {
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date(timeIntervalSince1970: now - StatusPolicy.activeInactivityTimeout - 5 * 60)
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  (values.contentModificationDate ?? .distantPast) >= cutoff else { continue }
            watchFile(url)
        }
    }

    private func watchTitleIndex() {
        guard titleWatcher == nil, FileManager.default.fileExists(atPath: titleIndexURL.path) else { return }
        reloadTitles()
        let descriptor = Darwin.open(titleIndexURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self, let source = self.titleWatcher else { return }
            let events = source.data
            if events.contains(.delete) || events.contains(.rename) {
                self.reloadTitles()
                source.cancel()
                self.titleWatcher = nil
            } else {
                self.reloadTitles()
            }
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        titleWatcher = source
        source.resume()
    }

    private func reloadTitles() {
        guard let data = try? Data(contentsOf: titleIndexURL),
              let text = String(data: data, encoding: .utf8) else { return }
        var updated: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let object = parse(String(line)),
                  let id = object["id"] as? String,
                  let title = object["thread_name"] as? String,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            updated[id] = title
        }
        guard updated != titles else { return }
        titles = updated
        for path in Array(cursors.keys) {
            guard var cursor = cursors[path], !cursor.state.isEmpty,
                  let title = titles[cursor.sessionID], cursor.state["project"] as? String != title else { continue }
            cursor.state["project"] = title
            cursor.state["indexedTitle"] = true
            cursors[path] = cursor
            write(cursor: cursor, transcript: path)
        }
    }

    private func watchDirectory(_ url: URL) {
        let path = url.path
        guard directoryWatchers[path] == nil,
              FileManager.default.fileExists(atPath: path) else { return }
        discoverFiles(in: url)
        let descriptor = Darwin.open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename],
            queue: queue
        )
        source.setEventHandler { [weak self] in self?.discoverFiles(in: url) }
        source.setCancelHandler { Darwin.close(descriptor) }
        directoryWatchers[path] = source
        source.resume()
    }

    private func discoverFiles(in directory: URL) {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for url in urls where url.pathExtension == "jsonl" { watchFile(url) }
    }

    private func watchFile(_ url: URL) {
        let path = url.path
        guard fileWatchers[path] == nil else { return }
        if let size = fileSize(url), size > 0 {
            consume(url: url, size: size)
        }
        let descriptor = Darwin.open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            guard let source = self.fileWatchers[path] else { return }
            let events = source.data
            if events.contains(.delete) || events.contains(.rename) {
                source.cancel()
                self.fileWatchers[path] = nil
                return
            }
            if let size = self.fileSize(url), size > 0 {
                self.consume(url: url, size: size)
            }
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        fileWatchers[path] = source
        source.resume()
    }

    private func fileSize(_ url: URL) -> UInt64? {
        guard let number = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber else { return nil }
        return number.uint64Value
    }

    private func consume(url: URL, size: UInt64) {
        let path = url.path
        var cursor = cursors[path] ?? initialCursor(url: url, size: size)
        guard size > cursor.offset, let handle = try? FileHandle(forReadingFrom: url) else {
            cursors[path] = cursor
            return
        }
        defer { try? handle.close() }
        try? handle.seek(toOffset: cursor.offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }
        cursor.offset = size
        applyLines(data, to: &cursor, transcript: path)
        cursors[path] = cursor
    }

    private func initialCursor(url: URL, size: UInt64) -> Cursor {
        let fallbackID = url.deletingPathExtension().lastPathComponent.split(separator: "-").suffix(5).joined(separator: "-")
        var cursor = Cursor(offset: 0, sessionID: fallbackID, cwd: "", threadSource: "", state: [:])
        guard let handle = try? FileHandle(forReadingFrom: url) else { return cursor }
        defer { try? handle.close() }
        // Session metadata is the first line and may sit outside the tail window.
        if let head = try? handle.read(upToCount: 128 * 1024),
           let line = String(decoding: head, as: UTF8.self).split(separator: "\n").first,
           let object = parse(String(line)), object["type"] as? String == "session_meta",
           let payload = object["payload"] as? [String: Any] {
            cursor.sessionID = payload["id"] as? String ?? cursor.sessionID
            cursor.cwd = payload["cwd"] as? String ?? cursor.cwd
            cursor.threadSource = payload["thread_source"] as? String ?? cursor.threadSource
        }
        let window: UInt64 = 512 * 1024
        let start = size > window ? size - window : 0
        try? handle.seek(toOffset: start)
        if let data = try? handle.readToEnd() {
            cursor.offset = size
            applyLines(data, to: &cursor, transcript: url.path)
        }
        return cursor
    }

    private func applyLines(_ data: Data, to cursor: inout Cursor, transcript: String) {
        let text = String(decoding: data, as: UTF8.self)
        var changed = false
        for line in text.split(separator: "\n") {
            guard let object = parse(String(line)), let type = object["type"] as? String,
                  let payload = object["payload"] as? [String: Any] else { continue }
            if type == "session_meta" {
                cursor.sessionID = payload["id"] as? String ?? cursor.sessionID
                if let cwd = payload["cwd"] as? String, !cwd.isEmpty { cursor.cwd = cwd }
                cursor.threadSource = payload["thread_source"] as? String ?? cursor.threadSource
                continue
            }
            let timestamp = (object["timestamp"] as? String).flatMap { parseTimestamp($0) }
                ?? Date().timeIntervalSince1970
            if type == "event_msg", let event = payload["type"] as? String {
                switch event {
                case "task_started":
                    cursor.state = makeState(cursor: cursor, state: "thinking", label: "Thinking…",
                                             timestamp: timestamp,
                                             startedAt: timestamp, turnID: payload["turn_id"] as? String ?? "",
                                             transcript: transcript)
                    changed = true
                case "task_complete":
                    cursor.state = makeState(cursor: cursor, state: "done", label: "Done",
                                             timestamp: timestamp, startedAt: 0,
                                             turnID: payload["turn_id"] as? String ?? "", transcript: transcript)
                    changed = true
                case "task_cancelled", "turn_aborted":
                    cursor.state = makeState(cursor: cursor, state: "idle", label: "",
                                             timestamp: timestamp, startedAt: 0,
                                             turnID: payload["turn_id"] as? String ?? "", transcript: transcript)
                    changed = true
                default: break
                }
            } else if type == "response_item", payload["type"] as? String == "custom_tool_call" {
                let name = payload["name"] as? String ?? "tool"
                let startedAt = cursor.state["startedAt"] as? Double ?? timestamp
                cursor.state = makeState(cursor: cursor, state: "tool", label: "Using \(name)",
                                         timestamp: timestamp, startedAt: startedAt,
                                         turnID: cursor.state["turnId"] as? String ?? "", transcript: transcript)
                changed = true
            }
        }
        if changed { write(cursor: cursor, transcript: transcript) }
    }

    private func makeState(cursor: Cursor, state: String, label: String,
                           timestamp: Double, startedAt: Double, turnID: String,
                           transcript: String) -> [String: Any] {
        let pid = pidProvider()
        let fallback = cursor.cwd.isEmpty ? "Codex" : URL(fileURLWithPath: cursor.cwd).lastPathComponent
        let project = titles[cursor.sessionID] ?? fallback
        return [
            "state": state, "label": label, "project": project,
            "indexedTitle": titles[cursor.sessionID] != nil, "threadSource": cursor.threadSource,
            "cwd": cursor.cwd, "sessionId": cursor.sessionID, "turnId": turnID,
            "transcript": transcript, "surface": "codex-desktop", "term_program": "",
            "pid": Int(pid), "started": true, "startedAt": startedAt, "ts": timestamp,
            "activeAgents": [String](), "tool": ""
        ]
    }

    private func write(cursor: Cursor, transcript: String) {
        // Only top-level, user-owned Codex Desktop tasks belong in the status menu. Internal exec
        // sessions, automations, CLI sessions, and titleless helper runs remain entirely invisible.
        guard !cursor.state.isEmpty, cursor.threadSource == "user", titles[cursor.sessionID] != nil else { return }
        try? FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)
        let safeID = cursor.sessionID.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "_" }
        let url = stateRoot.appendingPathComponent(String(safeID) + ".json")
        guard let data = try? JSONSerialization.data(withJSONObject: cursor.state, options: [.sortedKeys]) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func parse(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func parseTimestamp(_ value: String) -> TimeInterval? {
        (isoFractional.date(from: value) ?? isoBasic.date(from: value))?.timeIntervalSince1970
    }
}
