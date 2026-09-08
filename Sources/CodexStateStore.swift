import Foundation

/// The local, remote, and registry producers must not replay older activity over completion.
enum CodexStateStore {
    private static let lock = NSLock()
    private static var latest: [String: (time: Double, state: String)] = [:]
    static func write(_ state: [String: Any], to url: URL) {
        lock.lock(); defer { lock.unlock() }
        let newTime = state["ts"] as? Double ?? 0
        let newState = state["state"] as? String ?? ""
        if let prior = latest[url.path] {
            if prior.time > newTime { return }
            if prior.time == newTime, ["done", "idle"].contains(prior.state),
               StatusPolicy.shouldShowInMenu(newState) { return }
        }
        if let data = try? Data(contentsOf: url),
           let old = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let oldTime = old["ts"] as? Double, let newTime = state["ts"] as? Double {
            if oldTime > newTime { return }
            if oldTime == newTime,
               ["done", "idle"].contains(old["state"] as? String ?? ""),
               StatusPolicy.shouldShowInMenu(state["state"] as? String ?? "") { return }
        }
        latest[url.path] = (newTime, newState)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
