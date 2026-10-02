import Foundation

enum GitHubError: LocalizedError {
    case http(status: Int, message: String)
    case graphQL(String)
    /// The query asked for something the token's scopes don't cover.
    case insufficientScopes(String)

    var errorDescription: String? {
        switch self {
        case .http(let status, let message):
            "GitHub API error \(status): \(message)"
        case .graphQL(let message), .insufficientScopes(let message):
            "GitHub GraphQL error: \(message)"
        }
    }

    /// The token was rejected: expired, revoked, or never valid.
    var isUnauthorized: Bool {
        if case .http(status: 401, _) = self { return true }
        return false
    }
}

struct GitHubClient: Sendable {
    let token: String

    // MARK: Pull requests

    func fetchPullRequests(repos: [Repo]) async throws -> (mine: [PullRequest], reviewRequested: [PullRequest]) {
        guard !repos.isEmpty else { return ([], []) }
        // A long list of repo: qualifiers can exceed GitHub's search limits, so
        // beyond a handful search everywhere and narrow down locally.
        let qualifiers = repos.count <= 15 ? repos.map { " repo:\($0.fullName)" }.joined() : ""
        let scope = "is:pr is:open archived:false" + qualifiers
        let selected = Set(repos.map { $0.fullName.lowercased() })
        let variables = [
            "mine": "\(scope) author:@me",
            "review": "\(scope) review-requested:@me",
        ]
        // Team names need the read:org scope. A token without it (a personal
        // access token with just `repo`) still gets everything else.
        let data: PullRequestSearch
        do {
            data = try await searchPullRequests(variables, teamNames: true)
        } catch GitHubError.insufficientScopes {
            data = try await searchPullRequests(variables, teamNames: false)
        }
        let pullRequests: ([PullRequestNode]) -> [PullRequest] = { nodes in
            nodes.map(PullRequest.init)
                .filter { selected.contains($0.repoFullName.lowercased()) }
                .sorted { $0.updatedAt > $1.updatedAt }
        }
        return (pullRequests(data.mine.items), pullRequests(data.review.items))
    }

    private func searchPullRequests(_ variables: [String: String], teamNames: Bool) async throws -> PullRequestSearch {
        let body: [String: Any] = [
            "query": Self.pullRequestQuery(teamNames: teamNames),
            "variables": variables,
        ]
        var request = makeRequest(path: "graphql")
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let response: GraphQLResponse<PullRequestSearch> = try await send(request)
        if let data = response.data {
            return data
        }
        let message = response.errors?.first?.message ?? "empty response"
        if response.errors?.contains(where: { $0.type == "INSUFFICIENT_SCOPES" }) == true {
            throw GitHubError.insufficientScopes(message)
        }
        throw GitHubError.graphQL(message)
    }

    private static func pullRequestQuery(teamNames: Bool) -> String {
        """
        fragment PR on PullRequest {
          id number title url isDraft updatedAt mergeable reviewDecision
          headRefName baseRefName
          author { login }
          repository { nameWithOwner }
          reviewRequests(first: 20) {
            nodes { requestedReviewer { __typename ... on User { login } \(teamNames ? "... on Team { name }" : "") } }
          }
          latestOpinionatedReviews(first: 50) { nodes { state author { login } } }
          reviewThreads(first: 100) { nodes { isResolved } }
          commits(last: 1) {
            nodes { commit { statusCheckRollup { contexts(first: 100) { nodes {
              __typename
              ... on CheckRun {
                name status conclusion startedAt
                checkSuite { workflowRun { event workflow { name } } }
              }
              ... on StatusContext { context state }
            } } } } }
          }
        }
        query($mine: String!, $review: String!) {
          mine: search(query: $mine, type: ISSUE, first: 100) { nodes { ...PR } }
          review: search(query: $review, type: ISSUE, first: 100) { nodes { ...PR } }
        }
        """
    }

    // MARK: Account

    /// The login of the account the token belongs to; fails if GitHub rejects the token.
    func fetchViewerLogin() async throws -> String {
        let viewer: ViewerResponse = try await send(makeRequest(path: "user"))
        return viewer.login
    }

    // MARK: Repositories

    /// Every non-archived repository the user has access to, most recently
    /// pushed first. `hiddenBySSO` is true when GitHub left out organisations
    /// because the token is not authorised for their single sign-on.
    func fetchAccessibleRepos() async throws -> (repos: [Repo], hiddenBySSO: Bool) {
        var repos: [Repo] = []
        var hiddenBySSO = false
        for page in 1...20 {
            let request = makeRequest(
                path: "user/repos",
                query: ["per_page": "100", "page": "\(page)", "sort": "pushed"]
            )
            let (batch, response): ([RepoResponse], HTTPURLResponse?) = try await sendReturningResponse(request)
            // e.g. "partial-results; organizations=21955855,20582480"
            if response?.value(forHTTPHeaderField: "X-GitHub-SSO")?.hasPrefix("partial-results") == true {
                hiddenBySSO = true
            }
            repos += batch.filter { !$0.archived }.map { Repo(owner: $0.owner.login, name: $0.name) }
            if batch.count < 100 { break }
        }
        return (repos, hiddenBySSO)
    }

    // MARK: Workflow runs

    /// All workflow runs in `repos` that have not completed, newest first.
    func fetchPendingRuns(repos: [Repo]) async throws -> [WorkflowRun] {
        var runsByID: [Int: WorkflowRun] = [:]
        try await withThrowingTaskGroup(of: [WorkflowRun].self) { group in
            for repo in repos {
                for status in Config.pendingRunStatuses {
                    group.addTask { try await fetchRuns(repo: repo, status: status) }
                }
            }
            for try await runs in group {
                for run in runs { runsByID[run.id] = run }
            }
        }

        // Runs that wait on a deployment approval: find out which environments.
        await withTaskGroup(of: (Int, [WorkflowRun.PendingEnvironment]).self) { group in
            for run in runsByID.values where run.status == "waiting" {
                group.addTask { (run.id, (try? await fetchPendingEnvironments(for: run)) ?? []) }
            }
            for await (id, environments) in group {
                runsByID[id]?.pendingEnvironments = environments
            }
        }

        return runsByID.values.sorted { $0.createdAt > $1.createdAt }
    }

    private func fetchRuns(repo: Repo, status: String) async throws -> [WorkflowRun] {
        let request = makeRequest(
            path: "repos/\(repo.fullName)/actions/runs",
            query: ["status": status, "per_page": "100"]
        )
        let response: RunsResponse = try await send(request)
        return response.workflowRuns.map { run in
            WorkflowRun(
                id: run.id,
                repo: repo,
                workflowName: run.name ?? "Workflow",
                title: run.displayTitle ?? "",
                runNumber: run.runNumber,
                status: run.status ?? status,
                event: run.event,
                branch: run.headBranch,
                actor: run.triggeringActor?.login ?? run.actor?.login,
                createdAt: run.createdAt,
                url: run.htmlUrl
            )
        }
    }

    private func fetchPendingEnvironments(for run: WorkflowRun) async throws -> [WorkflowRun.PendingEnvironment] {
        let request = makeRequest(path: "repos/\(run.repo.fullName)/actions/runs/\(run.id)/pending_deployments")
        let response: [PendingDeployment] = try await send(request)
        return response
            .map { .init(name: $0.environment.name, currentUserCanApprove: $0.currentUserCanApprove) }
            .sorted { $0.name < $1.name }
    }

    // MARK: Transport

    private func makeRequest(path: String, query: [String: String] = [:]) -> URLRequest {
        var components = URLComponents(string: "https://api.github.com/\(path)")!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        try await sendReturningResponse(request).0
    }

    private func sendReturningResponse<T: Decodable>(_ request: URLRequest) async throws -> (T, HTTPURLResponse?) {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        guard (200..<300).contains(status) else {
            let message = (try? decoder.decode(APIErrorBody.self, from: data))?.message
            throw GitHubError.http(status: status, message: message ?? "request failed")
        }
        return (try decoder.decode(T.self, from: data), response as? HTTPURLResponse)
    }
}

// MARK: - Wire formats

private struct APIErrorBody: Decodable {
    let message: String
}

private struct GraphQLResponse<T: Decodable>: Decodable {
    struct Failure: Decodable {
        let message: String
        let type: String?
    }

    let data: T?
    let errors: [Failure]?
}

private struct Connection<Node: Decodable>: Decodable {
    let nodes: [Node?]?

    var items: [Node] { (nodes ?? []).compactMap { $0 } }
}

private struct PullRequestSearch: Decodable {
    let mine: Connection<PullRequestNode>
    let review: Connection<PullRequestNode>
}

private struct PullRequestNode: Decodable {
    struct Actor: Decodable {
        let login: String
    }
    struct Repository: Decodable {
        let nameWithOwner: String
    }
    struct ReviewRequest: Decodable {
        struct Reviewer: Decodable {
            let typename: String
            let login: String?
            let name: String?

            enum CodingKeys: String, CodingKey {
                case typename = "__typename"
                case login, name
            }

            /// A user's login or a team's name; a team whose name the token may not read is just "a team".
            var label: String? {
                login ?? name ?? (typename == "Team" ? "a team" : nil)
            }
        }
        let requestedReviewer: Reviewer?
    }
    struct Review: Decodable {
        let state: String
        let author: Actor?
    }
    struct Thread: Decodable {
        let isResolved: Bool
    }
    struct CommitNode: Decodable {
        struct Commit: Decodable {
            struct Rollup: Decodable {
                let contexts: Connection<Check>
            }
            let statusCheckRollup: Rollup?
        }
        let commit: Commit
    }
    struct Check: Decodable {
        struct Suite: Decodable {
            struct WorkflowRun: Decodable {
                struct Workflow: Decodable {
                    let name: String
                }
                let event: String
                let workflow: Workflow
            }
            let workflowRun: WorkflowRun?
        }

        let typename: String
        // CheckRun
        let name: String?
        let status: String?
        let conclusion: String?
        let startedAt: Date?
        let checkSuite: Suite?
        // StatusContext
        let context: String?
        let state: String?

        enum CodingKeys: String, CodingKey {
            case typename = "__typename"
            case name, status, conclusion, startedAt, checkSuite, context, state
        }

        /// Runs of the same job in the same workflow share a key; GitHub
        /// only counts the most recent of them.
        var key: String {
            let run = checkSuite?.workflowRun
            return [typename, run?.workflow.name ?? "", run?.event ?? "", name ?? context ?? ""].joined(separator: "\u{0}")
        }
    }

    let id: String
    let number: Int
    let title: String
    let url: URL
    let isDraft: Bool
    let updatedAt: Date
    let mergeable: String
    let reviewDecision: String?
    let headRefName: String
    let baseRefName: String
    let author: Actor?
    let repository: Repository
    let reviewRequests: Connection<ReviewRequest>
    let latestOpinionatedReviews: Connection<Review>?
    let reviewThreads: Connection<Thread>
    let commits: Connection<CommitNode>
}

private struct ViewerResponse: Decodable {
    let login: String
}

private struct RepoResponse: Decodable {
    struct Owner: Decodable {
        let login: String
    }
    let name: String
    let owner: Owner
    let archived: Bool
}

private struct RunsResponse: Decodable {
    struct Run: Decodable {
        struct Actor: Decodable {
            let login: String
        }
        let id: Int
        let name: String?
        let displayTitle: String?
        let runNumber: Int
        let status: String?
        let event: String
        let headBranch: String?
        let actor: Actor?
        let triggeringActor: Actor?
        let createdAt: Date
        let htmlUrl: URL
    }

    let workflowRuns: [Run]
}

private struct PendingDeployment: Decodable {
    struct Environment: Decodable {
        let name: String
    }
    let environment: Environment
    let currentUserCanApprove: Bool
}

// MARK: - Mapping

private extension PullRequest {
    init(_ node: PullRequestNode) {
        let reviews = node.latestOpinionatedReviews?.items ?? []
        let decision: ReviewSummary.Decision = switch node.reviewDecision {
        case "APPROVED": .approved
        case "CHANGES_REQUESTED": .changesRequested
        case "REVIEW_REQUIRED": .reviewRequired
        default: .none
        }
        let review = ReviewSummary(
            decision: decision,
            approvedBy: reviews.filter { $0.state == "APPROVED" }.compactMap { $0.author?.login },
            changesRequestedBy: reviews.filter { $0.state == "CHANGES_REQUESTED" }.compactMap { $0.author?.login },
            waitingOn: node.reviewRequests.items.compactMap { $0.requestedReviewer?.label }
        )

        var passed = 0
        var failed: [String] = []
        var pending: [String] = []
        // A re-run workflow leaves its earlier check runs on the commit. Keep
        // only the latest run of each check, as GitHub's own UI does.
        var latest: [String: PullRequestNode.Check] = [:]
        var order: [String] = []
        for check in node.commits.items.first?.commit.statusCheckRollup?.contexts.items ?? [] {
            if let existing = latest[check.key] {
                if (check.startedAt ?? .distantPast) >= (existing.startedAt ?? .distantPast) {
                    latest[check.key] = check
                }
            } else {
                latest[check.key] = check
                order.append(check.key)
            }
        }
        for check in order.compactMap({ latest[$0] }) {
            let name = check.name ?? check.context ?? "check"
            if check.typename == "CheckRun" {
                if check.status != "COMPLETED" {
                    pending.append(name)
                } else if ["SUCCESS", "NEUTRAL", "SKIPPED"].contains(check.conclusion ?? "") {
                    passed += 1
                } else {
                    failed.append(name)
                }
            } else {
                switch check.state {
                case "SUCCESS": passed += 1
                case "PENDING", "EXPECTED": pending.append(name)
                default: failed.append(name)
                }
            }
        }

        self.init(
            id: node.id,
            number: node.number,
            title: node.title,
            url: node.url,
            repoFullName: node.repository.nameWithOwner,
            author: node.author?.login,
            isDraft: node.isDraft,
            headRef: node.headRefName,
            baseRef: node.baseRefName,
            updatedAt: node.updatedAt,
            hasConflicts: node.mergeable == "CONFLICTING",
            unresolvedThreads: node.reviewThreads.items.filter { !$0.isResolved }.count,
            review: review,
            checks: CheckSummary(passed: passed, failedNames: failed, pendingNames: pending)
        )
    }
}
