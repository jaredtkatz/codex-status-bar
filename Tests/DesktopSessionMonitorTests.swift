import Foundation

@main
struct DesktopSessionMonitorTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("codex-status-monitor-\(UUID().uuidString)")
        let sessions = root.appendingPathComponent("sessions")
        let states = root.appendingPathComponent("states")
        let titleIndex = root.appendingPathComponent("session_index.jsonl")
        defer { try? fm.removeItem(at: root) }

        let now = Date()
        let parts = Calendar(identifier: .gregorian).dateComponents(in: TimeZone.current, from: now)
        let day = sessions
            .appendingPathComponent(String(format: "%04d", parts.year!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", parts.month!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", parts.day!), isDirectory: true)
        try fm.createDirectory(at: day, withIntermediateDirectories: true)

        let sessionID = "desktop-monitor-test"
        try Data("{\"id\":\"\(sessionID)\",\"thread_name\":\"Trace Will the Real X\"}\n".utf8).write(to: titleIndex)
        let log = day.appendingPathComponent("rollout-test-\(sessionID).jsonl")
        let initial = """
        {"timestamp":"2026-08-05T12:00:00.123Z","type":"session_meta","payload":{"id":"\(sessionID)","cwd":"/tmp/example","thread_source":"user"}}
        {"timestamp":"2026-08-05T12:00:01Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"old-turn"}}

        """
        try Data(initial.utf8).write(to: log)

        let monitor = DesktopSessionMonitor(
            sessionsRoot: sessions, stateRoot: states, titleIndexURL: titleIndex, pidProvider: { 4242 }
        )
        monitor.poll(now: now.timeIntervalSince1970)
        let state = states.appendingPathComponent(sessionID + ".json")
        let discoveryDeadline = Date().addingTimeInterval(0.75)
        while Date() < discoveryDeadline, readState(state)?["state"] as? String != "done" {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard readState(state)?["state"] as? String == "done" else {
            fatalError("initial Desktop state was not discovered")
        }
        guard readState(state)?["project"] as? String == "Trace Will the Real X" else {
            fatalError("Codex thread title was not used")
        }
        guard readState(state)?["indexedTitle"] as? Bool == true,
              readState(state)?["threadSource"] as? String == "user" else {
            fatalError("user-thread metadata was not preserved")
        }

        let started = Date()
        let event = "{\"timestamp\":\"2026-08-05T12:00:02.456Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"new-turn\"}}\n"
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(event.utf8))
        try handle.close()

        let deadline = Date().addingTimeInterval(0.75)
        while Date() < deadline, readState(state)?["state"] as? String != "thinking" {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard let result = readState(state), result["state"] as? String == "thinking" else {
            fatalError("filesystem event did not surface task_started within 750 ms")
        }
        let expectedFormatter = ISO8601DateFormatter()
        expectedFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expectedTimestamp = expectedFormatter.date(from: "2026-08-05T12:00:02.456Z")!.timeIntervalSince1970
        guard abs((result["ts"] as? Double ?? 0) - expectedTimestamp) < 0.01 else {
            fatalError("fractional lifecycle timestamps were not parsed")
        }
        guard result["pid"] as? Int == 4242 else { fatalError("Desktop host PID was not preserved") }
        guard StatusPolicy.recentSessionRetention == 900 else { fatalError("recent-session retention changed") }
        guard StatusPolicy.shouldShowInMenu("thinking"),
              StatusPolicy.shouldShowInMenu("permission"),
              !StatusPolicy.shouldShowInMenu("done"),
              !StatusPolicy.shouldShowInMenu("idle") else {
            fatalError("menu visibility was not limited to active tasks")
        }
        guard StatusPolicy.effectiveState(rawState: "tool", age: 60) == "tool" else {
            fatalError("fresh working state was expired")
        }
        guard StatusPolicy.effectiveState(
            rawState: "tool", age: StatusPolicy.activeInactivityTimeout + 1
        ) == "idle" else {
            fatalError("stale working state was not expired")
        }
        guard StatusPolicy.shouldShowSessionTimer(showTimer: true, state: "thinking", startedAt: 1),
              !StatusPolicy.shouldShowSessionTimer(showTimer: false, state: "thinking", startedAt: 1),
              !StatusPolicy.shouldShowSessionTimer(showTimer: true, state: "idle", startedAt: 1) else {
            fatalError("session timer did not follow the Show timer preference")
        }
        let renamed = "{\"id\":\"\(sessionID)\",\"thread_name\":\"Renamed Thread\"}\n"
        try Data(renamed.utf8).write(to: titleIndex)
        let renameDeadline = Date().addingTimeInterval(0.75)
        while Date() < renameDeadline, readState(state)?["project"] as? String != "Renamed Thread" {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard readState(state)?["project"] as? String == "Renamed Thread" else {
            fatalError("thread rename was not propagated within 750 ms")
        }

        // Old-origin tasks must be rediscovered from their current modification time, not only
        // from today's date bucket. This models a July task that is still active in August.
        let oldSessions = root.appendingPathComponent("old-sessions")
        let oldDay = oldSessions.appendingPathComponent("2026/07/15", isDirectory: true)
        let oldStates = root.appendingPathComponent("old-states")
        try fm.createDirectory(at: oldDay, withIntermediateDirectories: true)
        let oldID = "old-origin-local-active"
        let oldLog = oldDay.appendingPathComponent("rollout-2026-07-15T00-00-00-(oldID).jsonl")
        let oldLifecycle = """
        {"timestamp":"2026-08-06T12:00:00.123Z","type":"session_meta","payload":{"id":"\(oldID)","cwd":"/tmp/old","thread_source":"user"}}
        {"timestamp":"2026-08-06T12:00:01.456Z","type":"event_msg","payload":{"type":"task_started","turn_id":"old-active-turn"}}

        """
        try Data(oldLifecycle.utf8).write(to: oldLog)
        try fm.setAttributes([.modificationDate: now], ofItemAtPath: oldLog.path)
        let oldIndex = root.appendingPathComponent("old-session-index.jsonl")
        try Data("{\"id\":\"\(oldID)\",\"thread_name\":\"Long-running July task\"}\n".utf8).write(to: oldIndex)
        let oldMonitor = DesktopSessionMonitor(
            sessionsRoot: oldSessions, stateRoot: oldStates, titleIndexURL: oldIndex, pidProvider: { 4242 }
        )
        oldMonitor.poll(now: now.timeIntervalSince1970)
        let oldState = oldStates.appendingPathComponent(oldID + ".json")
        waitUntil(oldState, state: "thinking")
        guard readState(oldState)?["project"] as? String == "Long-running July task" else {
            fatalError("old-origin active local task was not rediscovered with its exact title")
        }

        let remoteGlobalState = root.appendingPathComponent("global-state.json")
        let remoteStates = root.appendingPathComponent("remote-states")
        let remoteID = "019fd2bf-c246-7ec2-bd10-06c1a303f036"
        let remoteConfig: [String: Any] = [
            "codex-managed-remote-connections": [[
                "hostId": "remote-ssh-discovered:fallback",
                "displayName": "Fallback", "alias": "fallback",
            ]],
            "thread-project-assignments": [remoteID: [
                "projectKind": "remote", "hostId": "remote-ssh-discovered:fallback",
            ]],
        ]
        try JSONSerialization.data(withJSONObject: remoteConfig).write(to: remoteGlobalState)
        let remoteSnapshot = """
        __CODEX_STATUS_INDEX__
        {"id":"\(remoteID)","thread_name":"Remote validator maintenance"}
        __CODEX_STATUS_SESSIONS__
        __CODEX_STATUS_FILE__/home/nuck/.codex/sessions/2026/08/06/rollout-test-\(remoteID).jsonl
        {"timestamp":"2026-08-06T12:00:00.123Z","type":"session_meta","payload":{"id":"\(remoteID)","cwd":"/home/nuck/staking","thread_source":"subagent"}}
        {"timestamp":"2026-08-06T12:00:01.456Z","type":"event_msg","payload":{"type":"task_started","turn_id":"remote-turn"}}

        """
        let remoteMonitor = RemoteSessionMonitor(
            globalStateURL: remoteGlobalState, stateRoot: remoteStates, pollInterval: 0,
            snapshotProvider: { host in
                guard host.alias == "fallback", host.label == "Fallback" else { return nil }
                return Data(remoteSnapshot.utf8)
            }
        )
        remoteMonitor.poll(enabled: true)
        let remoteState = remoteStates.appendingPathComponent(remoteID + ".json")
        let remoteDeadline = Date().addingTimeInterval(0.75)
        while Date() < remoteDeadline, readState(remoteState)?["state"] as? String != "thinking" {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard let remoteResult = readState(remoteState),
              remoteResult["state"] as? String == "thinking",
              remoteResult["project"] as? String == "Remote validator maintenance",
              remoteResult["remoteHost"] as? String == "Fallback",
              remoteResult["threadSource"] as? String == "subagent" else {
            fatalError("SSH remote lifecycle state was not mirrored correctly")
        }

        // Codex Desktop's registry snapshot is the cross-host acceptance source. No active-task
        // cap is applied: this exact set must surface local, SSH, and Remote Control together.
        let registryStates = root.appendingPathComponent("registry-states")
        let localRegistryID = "019fd200-3fee-7853-bcba-4619873a2079"
        let sshRegistryID = "019fc3bd-0000-7000-8000-000000000001"
        let controlRegistryID = "019f9a5f-0000-7000-8000-000000000002"
        let registryTasks = [
            DesktopTaskRegistryMonitor.Task(id: localRegistryID, hostID: "local", title: "CodexStatusBar", cwd: "/local"),
            DesktopTaskRegistryMonitor.Task(id: sshRegistryID, hostID: "remote-ssh-discovered:validator", title: "Upgrade validator", cwd: "/ssh"),
            DesktopTaskRegistryMonitor.Task(id: controlRegistryID, hostID: "remote-control:april", title: "My Wolves & Ally", cwd: "/control"),
        ]
        let registryMonitor = DesktopTaskRegistryMonitor(
            databaseURL: root.appendingPathComponent("unused.db"),
            logsRoot: root.appendingPathComponent("unused-logs"),
            stateRoot: registryStates,
            catalogProvider: { registryTasks },
            snapshotProvider: {
                DesktopTaskRegistryMonitor.Snapshot(
                    observedAt: now.timeIntervalSince1970,
                    statuses: [localRegistryID: "active", sshRegistryID: "active", controlRegistryID: "active"]
                )
            }
        )
        registryMonitor.poll(enabled: true, now: now.timeIntervalSince1970)
        for id in [localRegistryID, sshRegistryID, controlRegistryID] {
            waitUntil(registryStates.appendingPathComponent(id + ".json"), state: "thinking")
        }
        let stateFiles = try fm.contentsOfDirectory(at: registryStates, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        guard Set(stateFiles.map { $0.deletingPathExtension().lastPathComponent })
                == Set([localRegistryID, sshRegistryID, controlRegistryID]) else {
            fatalError("exact live three-task registry acceptance set did not match")
        }
        guard readState(registryStates.appendingPathComponent(sshRegistryID + ".json"))?["remoteHost"] as? String == "validator",
              readState(registryStates.appendingPathComponent(controlRegistryID + ".json"))?["remoteHost"] as? String == "Remote Control" else {
            fatalError("SSH and Remote Control surfaces were not labeled correctly")
        }

        // Exercise the real nested JSON shape written by Codex Desktop rather than relying only
        // on the injected snapshot seam.
        let logStates = root.appendingPathComponent("desktop-log-states")
        let desktopLogs = root.appendingPathComponent("desktop-logs")
        try fm.createDirectory(at: desktopLogs, withIntermediateDirectories: true)
        let listing: [String: Any] = [
            "schemaVersion": 4,
            "pinnedThreads": [],
            "threads": [[
                "id": controlRegistryID, "kind": "codex", "status": "active",
                "hostId": "remote-control:april", "cwd": "/control", "title": "My Wolves & Ally",
            ]],
        ]
        let listingText = String(data: try JSONSerialization.data(withJSONObject: listing), encoding: .utf8)!
        let response = ["contentItems": [["type": "inputText", "text": listingText]]]
        let responseText = String(data: try JSONSerialization.data(withJSONObject: response), encoding: .utf8)!
        let desktopLog = desktopLogs.appendingPathComponent("codex-desktop.log")
        try Data("2026-08-06T12:00:00.000Z info test response=\(responseText)\n".utf8).write(to: desktopLog)
        let logMonitor = DesktopTaskRegistryMonitor(
            databaseURL: root.appendingPathComponent("unused-2.db"), logsRoot: desktopLogs,
            stateRoot: logStates, catalogProvider: { [] }
        )
        logMonitor.poll(enabled: true, now: now.timeIntervalSince1970)
        waitUntil(logStates.appendingPathComponent(controlRegistryID + ".json"), state: "thinking")
        guard readState(logStates.appendingPathComponent(controlRegistryID + ".json"))?["project"] as? String == "My Wolves & Ally" else {
            fatalError("Codex Desktop aggregate log task identity was not parsed")
        }

        // Codex 0.149 no longer logs the schema-v4 aggregate payload. Exact titles still come from
        // the catalog, while successful turn/start responses and terminal lifecycle lines carry
        // enough lifecycle information to keep the menu mapped to Desktop.
        let modernStates = root.appendingPathComponent("modern-log-states")
        let modernLogs = root.appendingPathComponent("modern-logs")
        try fm.createDirectory(at: modernLogs, withIntermediateDirectories: true)
        let modernID = "01a02bf9-cf4b-7880-91b1-305db4fe8ddd"
        let modernLog = modernLogs.appendingPathComponent("codex-desktop-modern.log")
        let modernStart = "2026-08-06T12:00:02.456Z info [AppServerConnection] response_routed conversationId=\(modernID) errorCode=null method=turn/start\n"
        try Data(modernStart.utf8).write(to: modernLog)
        let modernTask = DesktopTaskRegistryMonitor.Task(
            id: modernID, hostID: "remote-control:april", title: "Exact Mac app title",
            cwd: "/remote", updatedAt: expectedTimestamp - 1
        )
        let modernMonitor = DesktopTaskRegistryMonitor(
            databaseURL: root.appendingPathComponent("unused-3.db"), logsRoot: modernLogs,
            stateRoot: modernStates, catalogProvider: { [modernTask] }
        )
        modernMonitor.poll(enabled: true, now: expectedTimestamp)
        let modernState = modernStates.appendingPathComponent(modernID + ".json")
        waitUntil(modernState, state: "thinking")
        guard readState(modernState)?["project"] as? String == "Exact Mac app title" else {
            fatalError("modern Desktop title did not match the catalog")
        }
        let modernComplete = "2026-08-06T12:00:03.456Z error Received turn/completed for unknown conversation conversationId=\(modernID)\n"
        let modernHandle = try FileHandle(forWritingTo: modernLog)
        try modernHandle.seekToEnd()
        try modernHandle.write(contentsOf: Data(modernComplete.utf8))
        try modernHandle.close()
        modernMonitor.poll(enabled: true, now: expectedTimestamp + 2)
        waitUntil(modernState, state: "done")

        let catalogOnlyStates = root.appendingPathComponent("catalog-only-states")
        let catalogOnlyID = "01a02c00-0000-7000-8000-000000000001"
        let catalogOnlyMonitor = DesktopTaskRegistryMonitor(
            databaseURL: root.appendingPathComponent("unused-4.db"), logsRoot: root.appendingPathComponent("none"),
            stateRoot: catalogOnlyStates,
            catalogProvider: { [DesktopTaskRegistryMonitor.Task(
                id: catalogOnlyID, hostID: "local", title: "Renamed exactly in Codex",
                cwd: "/local", updatedAt: expectedTimestamp - 2
            )] }
        )
        catalogOnlyMonitor.poll(enabled: true, now: expectedTimestamp)
        let catalogOnlyState = catalogOnlyStates.appendingPathComponent(catalogOnlyID + ".json")
        waitUntil(catalogOnlyState, state: "done")
        guard readState(catalogOnlyState)?["project"] as? String == "Renamed exactly in Codex" else {
            fatalError("recent catalog title was not mirrored exactly")
        }
        let latency = Date().timeIntervalSince(started)
        print(String(format: "DesktopSessionMonitorTests: event latency %.0f ms", latency * 1_000))
    }

    private static func waitUntil(_ url: URL, state: String) {
        let deadline = Date().addingTimeInterval(0.75)
        while Date() < deadline, readState(url)?["state"] as? String != state {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard readState(url)?["state"] as? String == state else {
            fatalError("timed out waiting for \(url.lastPathComponent) to become \(state)")
        }
    }

    private static func readState(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
