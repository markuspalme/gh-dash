import Foundation

/// One line of the terminal dashboard.
enum DashboardRow {
    case header(id: String, title: String, count: Int, note: String?, isExpanded: Bool, link: URL?)
    case pullRequest(PullRequest, showAuthor: Bool, sectionID: String)
    case run(WorkflowRun, sectionID: String)
    case empty(String, sectionID: String)
    case blank

    /// Rows the cursor can rest on.
    var isSelectable: Bool {
        switch self {
        case .header, .pullRequest, .run: true
        case .empty, .blank: false
        }
    }

    var url: URL? {
        switch self {
        case .header(_, _, _, _, _, let link): link
        case .pullRequest(let pullRequest, _, _): pullRequest.url
        case .run(let run, _): run.url
        case .empty, .blank: nil
        }
    }

    /// The section the row belongs to.
    var sectionID: String? {
        switch self {
        case .header(let id, _, _, _, _, _): id
        case .pullRequest(_, _, let id), .run(_, let id), .empty(_, let id): id
        case .blank: nil
        }
    }
}

/// Builds the dashboard's rows: the same sections, order and filtering as
/// the apps' `DashboardView`, as plain data the terminal view can draw.
enum DashboardRows {
    @MainActor
    static func build(
        store: DashboardStore, scope: Repo?, filter: PullRequestFilter, collapsed: Set<String>
    ) -> [DashboardRow] {
        var rows: [DashboardRow] = []
        rows += pullRequestSection(
            "My open pull requests", id: "mine",
            store.pullRequests(store.myPullRequests.filter { !$0.isOnlyAwaitingReview }, in: scope),
            showAuthor: false, filter: filter, collapsed: collapsed
        )
        rows += pullRequestSection(
            "Awaiting your review", id: "review",
            store.pullRequests(store.reviewRequests, in: scope),
            showAuthor: true, filter: filter, collapsed: collapsed
        )
        rows += pullRequestSection(
            "My pull requests waiting on reviewers", id: "waiting",
            store.pullRequests(store.myPullRequests.filter(\.isOnlyAwaitingReview), in: scope),
            showAuthor: false, filter: filter, collapsed: collapsed
        )

        let repos = scope.map { [$0] } ?? store.repos
        if !store.pendingRuns.contains(where: { repos.contains($0.repo) }) {
            let isExpanded = !collapsed.contains("runs")
            rows.append(.header(id: "runs", title: "Pending actions", count: 0, note: nil, isExpanded: isExpanded, link: nil))
            if isExpanded {
                rows.append(.empty("No pending workflow runs", sectionID: "runs"))
            }
            rows.append(.blank)
        }
        for repo in repos {
            let runs = store.pendingRuns.filter { $0.repo == repo }
            guard !runs.isEmpty else { continue }
            let id = "runs:\(repo.fullName)"
            let isExpanded = !collapsed.contains(id)
            rows.append(.header(
                id: id, title: "Pending actions · \(repo.name)", count: runs.count,
                note: nil, isExpanded: isExpanded, link: repo.actionsURL
            ))
            if isExpanded {
                rows += runs.map { .run($0, sectionID: id) }
            }
            rows.append(.blank)
        }
        if rows.last.map({ if case .blank = $0 { true } else { false } }) == true {
            rows.removeLast()
        }
        return rows
    }

    private static func pullRequestSection(
        _ title: String, id: String, _ pullRequests: [PullRequest],
        showAuthor: Bool, filter: PullRequestFilter, collapsed: Set<String>
    ) -> [DashboardRow] {
        let visible = pullRequests.filter(filter.shows)
        let isExpanded = !collapsed.contains(id)
        var rows: [DashboardRow] = [
            .header(
                id: id, title: title, count: visible.count,
                note: filter.hiddenNote(for: pullRequests),
                isExpanded: isExpanded, link: nil
            ),
        ]
        if isExpanded {
            if visible.isEmpty {
                rows.append(.empty("None", sectionID: id))
            }
            rows += visible.map { .pullRequest($0, showAuthor: showAuthor, sectionID: id) }
        }
        rows.append(.blank)
        return rows
    }
}

/// Short relative times for a one-line row: "5m", "3h", "2d", "3w".
func shortAge(of date: Date, now: Date = .now) -> String {
    let seconds = max(0, now.timeIntervalSince(date))
    switch seconds {
    case ..<60: return "now"
    case ..<3600: return "\(Int(seconds / 60))m"
    case ..<86400: return "\(Int(seconds / 3600))h"
    case ..<(86400 * 14): return "\(Int(seconds / 86400))d"
    default: return "\(Int(seconds / (86400 * 7)))w"
    }
}
