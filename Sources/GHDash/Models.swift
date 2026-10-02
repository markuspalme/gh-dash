import Foundation

struct Repo: Hashable, Identifiable, Sendable {
    let owner: String
    let name: String

    var id: String { fullName }
    var fullName: String { "\(owner)/\(name)" }
    var url: URL { URL(string: "https://github.com/\(owner)/\(name)")! }
    var actionsURL: URL { url.appending(path: "actions") }
}

extension Repo {
    init?(fullName: String) {
        let parts = fullName.split(separator: "/")
        guard parts.count == 2 else { return nil }
        self.init(owner: String(parts[0]), name: String(parts[1]))
    }
}

// MARK: - Pull requests

struct PullRequest: Identifiable, Sendable {
    let id: String
    let number: Int
    let title: String
    let url: URL
    let repoFullName: String
    let author: String?
    let isDraft: Bool
    let headRef: String
    let baseRef: String
    let updatedAt: Date
    let hasConflicts: Bool
    let unresolvedThreads: Int
    let review: ReviewSummary
    let checks: CheckSummary

    var repoName: String { repoFullName.split(separator: "/").last.map(String.init) ?? repoFullName }

    /// What the author has to fix: conflicts, requested changes, failing checks.
    var problems: [String] {
        var problems: [String] = []
        if hasConflicts { problems.append("Merge conflicts") }
        if review.decision == .changesRequested || !review.changesRequestedBy.isEmpty {
            problems.append("Changes requested")
        }
        if !checks.failedNames.isEmpty { problems.append("Checks failing") }
        return problems
    }

    var needsAuthorAttention: Bool { !problems.isEmpty }

    /// Nothing left for the author to do but wait for reviewers.
    var isOnlyAwaitingReview: Bool {
        !isDraft
            && !needsAuthorAttention
            && unresolvedThreads == 0
            && review.decision != .approved
            && (review.decision == .reviewRequired || !review.waitingOn.isEmpty)
    }

    var isFailingDependabot: Bool {
        author?.hasPrefix("dependabot") == true && !checks.failedNames.isEmpty
    }
}

/// The user's "hide" switches, shared by the dashboard and notifications.
struct PullRequestFilter {
    var hideDrafts: Bool
    var hideFailingDependabot: Bool

    static let hideDraftsKey = "hideDrafts"
    static let hideFailingDependabotKey = "hideFailingDependabot"

    /// The switches as last saved; both default to on.
    static var saved: PullRequestFilter {
        let defaults = UserDefaults.standard
        return PullRequestFilter(
            hideDrafts: defaults.object(forKey: hideDraftsKey) as? Bool ?? true,
            hideFailingDependabot: defaults.object(forKey: hideFailingDependabotKey) as? Bool ?? true
        )
    }

    func shows(_ pullRequest: PullRequest) -> Bool {
        !(hideDrafts && pullRequest.isDraft) && !(hideFailingDependabot && pullRequest.isFailingDependabot)
    }
}

struct ReviewSummary: Sendable {
    enum Decision: Sendable {
        case approved, changesRequested, reviewRequired, none
    }

    let decision: Decision
    let approvedBy: [String]
    let changesRequestedBy: [String]
    /// Reviewers (users or teams) who were asked and have not reviewed yet.
    let waitingOn: [String]
}

struct CheckSummary: Sendable {
    let passed: Int
    let failedNames: [String]
    let pendingNames: [String]

    var total: Int { passed + failedNames.count + pendingNames.count }
}

// MARK: - Workflow runs

struct WorkflowRun: Identifiable, Sendable {
    struct PendingEnvironment: Sendable {
        let name: String
        let currentUserCanApprove: Bool
    }

    let id: Int
    let repo: Repo
    let workflowName: String
    let title: String
    let runNumber: Int
    let status: String
    let event: String
    let branch: String?
    let actor: String?
    let createdAt: Date
    let url: URL
    /// Environments this run is waiting on for a deployment approval.
    var pendingEnvironments: [PendingEnvironment] = []

    var canApprove: Bool { pendingEnvironments.contains(where: \.currentUserCanApprove) }
}
