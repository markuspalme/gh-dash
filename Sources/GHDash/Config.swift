import Foundation

enum Config {
    static let refreshInterval: Duration = .seconds(180)

    /// Workflow run statuses that count as "pending".
    static let pendingRunStatuses = ["waiting", "action_required", "pending", "queued", "in_progress"]
}
