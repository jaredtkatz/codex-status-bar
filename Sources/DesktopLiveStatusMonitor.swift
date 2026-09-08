import Foundation
import Darwin

/// Read-only follower of Codex Desktop's cross-window runtime status stream.
/// Never starts/resumes a task or claims ownership. Conversation content in frames is discarded;
/// only runtime status and stream revision are retained. All socket work runs on the registry queue.
final class DesktopLiveStatusMonitor {
    struct Entry {
        var state: String
        var revision: Int
        var owner: String
    }
    private let socketURL: URL
    private let queue = DispatchQueue(label: "com.nickxma.codexstatusbar.live-status", qos: .utility)
    private var reader: DispatchSourceRead?
    private var socketFD: Int32 = -1
    private var buffer = Data()
    private var initialized = false
    private var subscribed: [String: String] = [:]
    private var lastSubscribe: TimeInterval = 0
    private var nextConnect: TimeInterval = 0
    private var entries: [String: Entry] = [:]
    private let lock = NSLock()
    private var published: [String: String] = [:]
    private var connected = false
    private static let maxFrame = 32 * 1024 * 1024

    init(socketURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/ipc/ipc.sock")) {
        self.socketURL = socketURL
    }
    deinit { reader?.cancel(); if socketFD >= 0 { Darwin.close(socketFD) } }

    func state(for id: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return published[id]
    }
    var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }; return connected
    }

    func poll(tasks: [DesktopTaskRegistryMonitor.Task], now: TimeInterval) -> [String: String] {
        queue.sync { pollOnQueue(tasks: tasks, now: now) }
    }

    private func pollOnQueue(tasks: [DesktopTaskRegistryMonitor.Task], now: TimeInterval) -> [String: String] {
        if socketFD < 0, now >= nextConnect {
            nextConnect = now + 5
            connect()
        }
        guard socketFD >= 0 else { return publish() }
        receive()
        if initialized {
            let wanted = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.hostID) })
            for (id, host) in subscribed where wanted[id] != host {
                follow(id, host: host, following: false)
                entries[id] = nil
            }
            // Reannounce periodically: a task may acquire an owner after our initial subscription.
            for (id, host) in wanted where subscribed[id] != host || ((entries[id] == nil || entries[id]?.state == "unknown") && now - lastSubscribe >= 15) {
                follow(id, host: host, following: true)
            }
            if now - lastSubscribe >= 15 { lastSubscribe = now }
            subscribed = wanted
            receive()
        }
        return publish()
    }

    private func publish() -> [String: String] {
        let states = entries.mapValues(\.state)
        lock.lock(); published = states; connected = initialized; lock.unlock()
        return states
    }

    private func connect() {
        // Connect only to a socket owned by this user; never create Codex's router or alter it.
        var info = stat()
        guard lstat(socketURL.path, &info) == 0,
              info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFSOCK else { return }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketURL.path.utf8) + [UInt8(0)]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { Darwin.close(fd); return }
        socketFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.receive()
            _ = self?.publish()
        }
        reader = source
        source.resume()
        send(["type": "request", "requestId": UUID().uuidString, "method": "initialize",
              "version": 0, "params": ["clientType": "codex-status-bar"]])
    }

    private func disconnect() {
        reader?.cancel(); reader = nil
        if socketFD >= 0 { Darwin.close(socketFD) }
        socketFD = -1; initialized = false; buffer.removeAll(); subscribed.removeAll()
        // A lost connection is not evidence of completion.
        for id in entries.keys { entries[id]?.state = "unknown" }
    }

    private func send(_ object: [String: Any]) {
        guard socketFD >= 0, let body = try? JSONSerialization.data(withJSONObject: object) else { return }
        var length = UInt32(body.count).littleEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }; frame.append(body)
        let count = frame.withUnsafeBytes { Darwin.send(socketFD, $0.baseAddress, $0.count, 0) }
        // Small control frames should fit; reconnect rather than leaving a partial frame on wire.
        if count != frame.count { disconnect() }
    }

    private func follow(_ id: String, host: String, following: Bool) {
        send(["type": "broadcast", "method": "thread-stream-following-changed", "version": 1,
              "params": ["conversationId": id, "hostId": host, "following": following]])
    }

    private func receive() {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        // Bounded work per tick, including when an agent emits large tool output.
        for _ in 0..<1024 where socketFD >= 0 {
            let count = Darwin.recv(socketFD, &chunk, chunk.count, 0)
            if count == 0 { disconnect(); return }
            if count < 0 {
                if errno != EAGAIN && errno != EWOULDBLOCK { disconnect() }
                return
            }
            buffer.append(contentsOf: chunk.prefix(count))
            while buffer.count >= 4 {
                let length = buffer.prefix(4).enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
                guard length > 0, length <= Self.maxFrame else { disconnect(); return }
                guard buffer.count >= length + 4 else { break }
                let data = buffer.subdata(in: 4..<(length + 4))
                buffer = Data(buffer.dropFirst(length + 4))
                if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    handle(object)
                }
            }
        }
    }

    // Internal for protocol regression tests with sanitized fixtures.
    func handle(_ message: [String: Any]) {
        defer { _ = publish() }
        if message["type"] as? String == "client-discovery-request" {
            send(["type": "client-discovery-response", "requestId": message["requestId"] ?? "",
                  "response": ["canHandle": false]])
            return
        }
        if message["method"] as? String == "initialize", message["resultType"] as? String == "success" {
            initialized = true; return
        }
        guard message["type"] as? String == "broadcast", let params = message["params"] as? [String: Any] else { return }
        if message["method"] as? String == "client-status-changed", params["status"] as? String == "disconnected",
           let owner = params["clientId"] as? String {
            for id in entries.keys where entries[id]?.owner == owner { entries[id]?.state = "unknown" }
            return
        }
        guard message["method"] as? String == "thread-stream-state-changed",
              let id = params["conversationId"] as? String else { return }
        guard message["version"] as? Int == 11 else {
            entries[id] = Entry(state: "unknown", revision: 0, owner: message["sourceClientId"] as? String ?? "")
            return
        }
        guard let change = params["change"] as? [String: Any],
              let revision = change["revision"] as? Int else { return }
        let owner = message["sourceClientId"] as? String ?? ""
        if change["type"] as? String == "snapshot",
           let state = change["conversationState"] as? [String: Any] {
            // Only admit user-owned tasks. The catalog supplies the final identity filter.
            if let source = state["threadSource"] as? String, source != "user" { return }
            entries[id] = Entry(state: Self.runtimeState(state["threadRuntimeStatus"]), revision: revision, owner: owner)
        } else if change["type"] as? String == "patches", var entry = entries[id] {
            guard entry.owner == owner, change["baseRevision"] as? Int == entry.revision else {
                entries[id]?.state = "unknown"
                lastSubscribe = 0
                return
            }
            for patch in change["patches"] as? [[String: Any]] ?? [] {
                let path = patch["path"] as? [String] ?? []
                if path == ["threadRuntimeStatus"] {
                    entry.state = Self.runtimeState(patch["value"])
                } else if path.first == "threadRuntimeStatus" {
                    // A changed wire shape needs a fresh full snapshot, not an inferred status.
                    entry.state = "unknown"; lastSubscribe = 0
                }
            }
            entry.revision = revision; entries[id] = entry
        }
    }

    static func runtimeState(_ value: Any?) -> String {
        guard let status = value as? [String: Any], let type = status["type"] as? String else { return "unknown" }
        switch type {
        case "active":
            let flags = status["activeFlags"] as? [String] ?? []
            return flags.contains("waitingOnApproval") || flags.contains("waitingOnUserInput") ? "permission" : "thinking"
        case "idle": return "idle"
        default: return "unknown"
        }
    }
}
