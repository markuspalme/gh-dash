import Foundation

/// Which Jira site and projects to watch.
struct JiraConfig: Equatable, Sendable {
    /// e.g. https://example.atlassian.net
    var site: URL?
    /// Project keys, e.g. ["INTEL"].
    var projects: [String] = []
    /// Board columns in order. Each entry is a column name, optionally
    /// followed by the statuses it collects, separated by slashes:
    /// "In Progress / Rework". Empty means one column per status, by category.
    var boardColumns: [String] = []

    var isComplete: Bool { site != nil && !projects.isEmpty }
}

struct JiraIssue: Identifiable, Sendable {
    enum StatusCategory: String, Sendable {
        case new, indeterminate, done, unknown
    }

    struct Sprint: Hashable, Sendable {
        let name: String
        /// "active", "future" or "closed".
        let state: String
    }

    let key: String
    let summary: String
    let status: String
    let statusCategory: StatusCategory
    let type: String
    let priority: String?
    let assignee: String?
    let created: Date
    let updated: Date
    let url: URL
    var sprint: Sprint?

    var id: String { key }
    var projectKey: String { String(key.prefix { $0 != "-" }) }
}

/// One thing that happened on an issue: the project's activity feed is a list of these.
struct JiraEvent: Identifiable, Sendable {
    enum Kind: Sendable {
        case created
        case commented(excerpt: String)
        case statusChanged(from: String, to: String)
        case assigned(to: String)
    }

    let id: String
    let date: Date
    let actor: String
    let kind: Kind
    let issue: JiraIssue

    /// The words before the issue key: "Dana commented on WEB-412".
    var verb: String {
        switch kind {
        case .created: "created"
        case .commented: "commented on"
        case .statusChanged: "moved"
        case .assigned: "assigned"
        }
    }

    /// The words after the issue key: "moved WEB-412 to In Review".
    var suffix: String? {
        switch kind {
        case .created, .commented: nil
        case .statusChanged(_, let to): "to \(to)"
        case .assigned(let to): "to \(to)"
        }
    }
}
