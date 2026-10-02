import Foundation
import Observation

@MainActor
@Observable
final class DashboardStore {
    /// Repositories shown on the dashboard, chosen by the user.
    private(set) var repos: [Repo]
    /// Everything the user could choose from; loaded when the picker opens.
    private(set) var availableRepos: [Repo] = []
    private(set) var isLoadingAvailableRepos = false
    private(set) var availableReposError: String?
    /// True when GitHub hid organisations the token is not authorised for.
    private(set) var availableReposHiddenBySSO = false

    private(set) var myPullRequests: [PullRequest] = []
    private(set) var reviewRequests: [PullRequest] = []
    private(set) var pendingRuns: [WorkflowRun] = []
    private(set) var lastUpdated: Date?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    @ObservationIgnored private var refreshQueued = false
    /// Ids of the things waiting on the user after the last load, and the
    /// repositories that load covered; nil until the first load.
    @ObservationIgnored private var knownAttention: (ids: Set<String>, repos: [Repo])?
    private static let reposKey = "selectedRepos"
    /// Demo mode shows `DemoData` and never touches GitHub or the saved selection.
    private let isDemo: Bool
    /// Where the GitHub token comes from: the GitHub CLI on the Mac, the
    /// personal access token the user signed in with on iOS.
    private let token: @Sendable () async throws -> String

    /// Posts a notification about a new item; unset means no notifications.
    @ObservationIgnored var postNotification: ((_ title: String, _ subtitle: String, _ body: String, _ url: URL?) -> Void)?
    /// Called when GitHub rejects the token.
    @ObservationIgnored var onUnauthorized: (() -> Void)?

    init(demo: Bool = false, token: @escaping @Sendable () async throws -> String) {
        isDemo = demo
        self.token = token
        guard !demo else {
            repos = DemoData.repos
            return
        }
        let stored = UserDefaults.standard.stringArray(forKey: Self.reposKey) ?? []
        repos = stored.compactMap(Repo.init(fullName:))
    }

    // MARK: Repository selection

    func setRepo(_ repo: Repo, selected: Bool) {
        if selected {
            guard !repos.contains(repo) else { return }
            repos.append(repo)
            repos.sort { $0.fullName.localizedStandardCompare($1.fullName) == .orderedAscending }
        } else {
            repos.removeAll { $0 == repo }
            myPullRequests.removeAll { $0.repoFullName == repo.fullName }
            reviewRequests.removeAll { $0.repoFullName == repo.fullName }
            pendingRuns.removeAll { $0.repo == repo }
        }
        if !isDemo {
            UserDefaults.standard.set(repos.map(\.fullName), forKey: Self.reposKey)
        }
    }

    func loadAvailableRepos() async {
        guard !isDemo else {
            availableRepos = DemoData.repos
            return
        }
        guard !isLoadingAvailableRepos else { return }
        isLoadingAvailableRepos = true
        defer { isLoadingAvailableRepos = false }
        do {
            (availableRepos, availableReposHiddenBySSO) = try await GitHubClient(token: token()).fetchAccessibleRepos()
            availableReposError = nil
        } catch {
            availableReposError = error.localizedDescription
        }
    }

    /// Forgets everything loaded, e.g. after signing out.
    func clear() {
        myPullRequests = []
        reviewRequests = []
        pendingRuns = []
        availableRepos = []
        availableReposHiddenBySSO = false
        lastUpdated = nil
        errorMessage = nil
        knownAttention = nil
    }

    // MARK: Counts

    func pullRequests(_ pullRequests: [PullRequest], in repo: Repo?) -> [PullRequest] {
        guard let repo else { return pullRequests }
        return pullRequests.filter { $0.repoFullName == repo.fullName }
    }

    /// Rows the dashboard shows for `repo` (nil for all repositories).
    func itemCount(in repo: Repo?, filter: PullRequestFilter) -> Int {
        pullRequests(myPullRequests, in: repo).filter(filter.shows).count
            + pullRequests(reviewRequests, in: repo).filter(filter.shows).count
            + pendingRuns.filter { repo == nil || $0.repo == repo }.count
    }

    /// Things waiting on the user in `repo` (nil for all repositories): visible
    /// review requests, their own visible pull requests that need fixing, and
    /// deployments they can approve.
    func waitingOnMeCount(in repo: Repo?, filter: PullRequestFilter) -> Int {
        pullRequests(reviewRequests, in: repo).filter(filter.shows).count
            + pullRequests(myPullRequests, in: repo).filter(filter.shows).filter(\.needsAuthorAttention).count
            + pendingRuns.filter { $0.canApprove && (repo == nil || $0.repo == repo) }.count
    }

    // MARK: Refreshing

    /// Refreshes now and then every `Config.refreshInterval` until the task is cancelled.
    func runAutoRefresh() async {
        // Without this, App Nap stretches the timer while the app is in the
        // background and the Dock badge goes stale.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Periodic GitHub refresh"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: Config.refreshInterval)
        }
    }

    func refreshIfStale(olderThan age: TimeInterval = 60) async {
        guard let lastUpdated, Date.now.timeIntervalSince(lastUpdated) > age else { return }
        await refresh()
    }

    func refresh() async {
        // A request that arrives mid-load (e.g. the repo selection changed) reruns afterwards.
        if isLoading {
            refreshQueued = true
            return
        }
        isLoading = true
        defer { isLoading = false }
        repeat {
            refreshQueued = false
            await load()
        } while refreshQueued
    }

    private func load() async {
        let repos = repos
        guard !isDemo else {
            let selected = Set(repos.map(\.fullName))
            let byRecency: (PullRequest, PullRequest) -> Bool = { $0.updatedAt > $1.updatedAt }
            myPullRequests = DemoData.myPullRequests.filter { selected.contains($0.repoFullName) }.sorted(by: byRecency)
            reviewRequests = DemoData.reviewRequests.filter { selected.contains($0.repoFullName) }.sorted(by: byRecency)
            pendingRuns = DemoData.pendingRuns.filter { repos.contains($0.repo) }.sorted { $0.createdAt > $1.createdAt }
            lastUpdated = .now
            return
        }
        let client: GitHubClient
        do {
            client = try await GitHubClient(token: token())
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        // The two halves load independently so one failing doesn't blank the other.
        async let pullRequests = client.fetchPullRequests(repos: repos)
        async let runs = client.fetchPendingRuns(repos: repos)
        var errors: [String] = []
        var isUnauthorized = false
        do {
            (myPullRequests, reviewRequests) = try await pullRequests
        } catch {
            errors.append("Pull requests: \(error.localizedDescription)")
            isUnauthorized = (error as? GitHubError)?.isUnauthorized ?? false
        }
        do {
            pendingRuns = try await runs
        } catch {
            errors.append("Workflow runs: \(error.localizedDescription)")
            isUnauthorized = isUnauthorized || (error as? GitHubError)?.isUnauthorized ?? false
        }
        if isUnauthorized {
            onUnauthorized?()
        }

        errorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")
        if errors.count < 2 {
            lastUpdated = .now
        }
        if errors.isEmpty {
            notifyAboutNewAttentionItems(in: repos)
        }
    }

    // MARK: Notifications

    private struct AttentionItem {
        let id: String
        var title: String
        let subtitle: String
        let body: String
        let url: URL
        /// False when one of the "hide" switches keeps it off the dashboard.
        let isVisible: Bool
    }

    /// Everything worth a notification when it first appears: review requests,
    /// each reason one of the user's own pull requests needs them again,
    /// pending workflow runs, and deployments the user can approve.
    private var attentionItems: [AttentionItem] {
        let filter = PullRequestFilter.saved
        let reviews = reviewRequests.map { pullRequest in
            AttentionItem(
                id: "review:\(pullRequest.id)",
                title: "Review requested",
                subtitle: pullRequest.title,
                body: "\(pullRequest.repoName) #\(pullRequest.number) by \(pullRequest.author ?? "unknown")",
                url: pullRequest.url,
                isVisible: filter.shows(pullRequest)
            )
        }
        // One item per reason, so a pull request that already had conflicts
        // still notifies when, say, changes are requested on top.
        let fixes = myPullRequests.flatMap { pullRequest in
            pullRequest.reasonsBackWithAuthor.map { reason in
                AttentionItem(
                    id: "mine:\(pullRequest.id):\(reason)",
                    title: reason,
                    subtitle: pullRequest.title,
                    body: "\(pullRequest.repoName) #\(pullRequest.number)",
                    url: pullRequest.url,
                    isVisible: filter.shows(pullRequest)
                )
            }
        }
        let approvals = pendingRuns.filter(\.canApprove).map { run in
            AttentionItem(
                id: "approve:\(run.id)",
                title: "Deployment awaiting your approval",
                subtitle: "\(run.workflowName) #\(run.runNumber)",
                body: "\(run.repo.name) · \(run.pendingEnvironments.map(\.name).joined(separator: ", "))",
                url: run.url,
                isVisible: true
            )
        }
        let runs = pendingRuns.map { run in
            AttentionItem(
                id: "run:\(run.id)",
                title: "New workflow run",
                subtitle: "\(run.workflowName) #\(run.runNumber)",
                body: "\(run.repo.name) · \(run.title)",
                url: run.url,
                isVisible: true
            )
        }
        return reviews + fixes + approvals + runs
    }

    /// Notifies about items that were not there after the previous load.
    private func notifyAboutNewAttentionItems(in repos: [Repo]) {
        let items = attentionItems
        let previous = knownAttention
        knownAttention = (Set(items.map(\.id)), repos)
        // The first load, and the first one after the repository selection
        // changed, only set the baseline: nothing in them is news.
        guard let previous, previous.repos == repos else { return }

        var new = items.filter { $0.isVisible && !previous.ids.contains($0.id) }
        // A run that is new and already awaiting approval gets one notification, not two.
        let newApprovals = Set(new.map(\.id).filter { $0.hasPrefix("approve:") })
        new.removeAll { $0.id.hasPrefix("run:") && newApprovals.contains("approve:" + $0.id.dropFirst(4)) }
        // Several new reasons on one pull request become a single notification.
        new = new.reduce(into: []) { merged, item in
            if let index = merged.firstIndex(where: { $0.url == item.url }) {
                merged[index].title += ", " + item.title
            } else {
                merged.append(item)
            }
        }
        if new.count > 3 {
            postNotification?("\(new.count) new items", "", new.prefix(3).map(\.subtitle).joined(separator: "\n"), nil)
        } else {
            for item in new {
                postNotification?(item.title, item.subtitle, item.body, item.url)
            }
        }
    }
}
