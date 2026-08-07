import Foundation

enum StatusPolicy {
    static let recentSessionRetention: TimeInterval = 15 * 60
    // Codex can interrupt a turn without appending task_cancelled/turn_aborted to the rollout.
    // Stop presenting an old working marker as live after a generous period with no lifecycle
    // activity. Normal thinking/tool streams refresh `ts` continuously.
    static let activeInactivityTimeout: TimeInterval = 30 * 60
    static let maximumRecentSessions = 5

    static func isWorking(_ state: String) -> Bool {
        state == "thinking" || state == "tool" || state == "subagent"
    }

    static func priority(of state: String) -> Int {
        switch state {
        case "permission": return 2
        case "thinking", "tool", "subagent": return 1
        default: return 0
        }
    }

    static func effectiveState(rawState: String, age: Double) -> String {
        if (isWorking(rawState) || rawState == "permission"), age > activeInactivityTimeout {
            return "idle"
        }
        guard rawState == "done" else { return rawState }
        return age < 0.84 ? "done" : "idle"
    }

    static func shouldShowSessionTimer(showTimer: Bool, state: String, startedAt: Double) -> Bool {
        showTimer && isWorking(state) && startedAt > 0
    }
}
