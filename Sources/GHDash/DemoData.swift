import Foundation

/// Made-up data for `--demo`: lets the app be tried, and screenshots taken,
/// without a GitHub login or real repositories.
enum DemoData {
    private static let viewer = "alex"
    private static let apiServer = Repo(owner: "acme", name: "api-server")
    private static let designSystem = Repo(owner: "acme", name: "design-system")
    private static let mobileApp = Repo(owner: "acme", name: "mobile-app")
    private static let webApp = Repo(owner: "acme", name: "web-app")

    static let repos = [apiServer, designSystem, mobileApp, webApp]

    static var myPullRequests: [PullRequest] {
        [
            pullRequest(
                webApp, 1207, "Migrate checkout flow to the new payment SDK", branch: "feature/payment-sdk",
                hoursAgo: 2, conflicts: true, waitingOn: ["tomasz-k"], passed: 9
            ),
            pullRequest(
                apiServer, 482, "Add rate limiting to public API endpoints", branch: "feature/rate-limiting",
                hoursAgo: 5, unresolved: 2, decision: .changesRequested, approvedBy: ["dana-lee"],
                changesRequestedBy: ["priya-n"], passed: 12
            ),
            pullRequest(
                apiServer, 479, "Fix flaky date parsing in report export", branch: "fix/report-date-parsing",
                hoursAgo: 20, passed: 9, failed: ["integration-tests", "lint"]
            ),
            pullRequest(
                designSystem, 88, "Add dark mode tokens for charts", branch: "feature/chart-tokens",
                hoursAgo: 26, decision: .approved, approvedBy: ["priya-n", "jonas-w"], passed: 6
            ),
            pullRequest(
                webApp, 1215, "Spike: streaming responses for search", branch: "spike/search-streaming",
                draft: true, hoursAgo: 49, passed: 6, pending: ["e2e-chrome", "e2e-safari", "bundle-size"]
            ),
            pullRequest(
                apiServer, 476, "Add CSV export to the audit log", branch: "feature/audit-log-csv",
                hoursAgo: 30, waitingOn: ["priya-n", "tomasz-k"], passed: 12
            ),
        ]
    }

    static var reviewRequests: [PullRequest] {
        [
            pullRequest(
                apiServer, 485, "Cache the user permissions lookup", branch: "perf/permissions-cache",
                author: "dana-lee", hoursAgo: 1, waitingOn: [viewer, "tomasz-k"], passed: 12
            ),
            pullRequest(
                mobileApp, 311, "Redesign the onboarding carousel", branch: "feature/onboarding-redesign",
                author: "jonas-w", hoursAgo: 7, approvedBy: ["priya-n"], waitingOn: [viewer], passed: 7,
                pending: ["ui-tests"]
            ),
            pullRequest(
                webApp, 1211, "Bump axios from 1.7.2 to 1.8.0", branch: "dependabot/npm/axios-1.8.0",
                author: "dependabot", hoursAgo: 29, waitingOn: [viewer], passed: 7, failed: ["unit-tests", "e2e-chrome"]
            ),
        ]
    }

    static var pendingRuns: [WorkflowRun] {
        [
            run(
                webApp, 90_001, "Deploy", 1874, "Migrate settings page to the new layout (#1198)",
                status: "waiting", actor: "dana-lee", minutesAgo: 25,
                environments: [.init(name: "Production", currentUserCanApprove: true)]
            ),
            run(
                webApp, 90_002, "Deploy", 1875, "Fix avatar upload on Safari (#1204)",
                status: "in_progress", actor: viewer, minutesAgo: 4
            ),
            run(
                apiServer, 90_003, "Deploy", 642, "Return 429 with a Retry-After header (#471)",
                status: "waiting", actor: viewer, minutesAgo: 190,
                environments: [
                    .init(name: "Production", currentUserCanApprove: true),
                    .init(name: "Staging", currentUserCanApprove: true),
                ]
            ),
            run(
                apiServer, 90_005, "CodeQL", 2051, "Add CSV export to the audit log",
                status: "queued", event: "pull_request", branch: "feature/audit-log-csv", actor: viewer, minutesAgo: 1
            ),
        ]
    }

    private static func pullRequest(
        _ repo: Repo, _ number: Int, _ title: String, branch: String, author: String = viewer,
        draft: Bool = false, hoursAgo: Double, conflicts: Bool = false, unresolved: Int = 0,
        decision: ReviewSummary.Decision = .reviewRequired, approvedBy: [String] = [],
        changesRequestedBy: [String] = [], waitingOn: [String] = [],
        passed: Int, failed: [String] = [], pending: [String] = []
    ) -> PullRequest {
        PullRequest(
            id: "\(repo.fullName)#\(number)",
            number: number,
            title: title,
            url: repo.url.appending(path: "pull/\(number)"),
            repoFullName: repo.fullName,
            author: author,
            isDraft: draft,
            headRef: branch,
            baseRef: "main",
            updatedAt: Date.now.addingTimeInterval(-hoursAgo * 3600),
            hasConflicts: conflicts,
            unresolvedThreads: unresolved,
            review: ReviewSummary(
                decision: decision, approvedBy: approvedBy,
                changesRequestedBy: changesRequestedBy, waitingOn: waitingOn
            ),
            checks: CheckSummary(passed: passed, failedNames: failed, pendingNames: pending)
        )
    }

    private static func run(
        _ repo: Repo, _ id: Int, _ workflow: String, _ number: Int, _ title: String, status: String,
        event: String = "push", branch: String = "main", actor: String, minutesAgo: Double,
        environments: [WorkflowRun.PendingEnvironment] = []
    ) -> WorkflowRun {
        WorkflowRun(
            id: id,
            repo: repo,
            workflowName: workflow,
            title: title,
            runNumber: number,
            status: status,
            event: event,
            branch: branch,
            actor: actor,
            createdAt: Date.now.addingTimeInterval(-minutesAgo * 60),
            url: repo.actionsURL.appending(path: "runs/\(id)"),
            pendingEnvironments: environments
        )
    }
}
