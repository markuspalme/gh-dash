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

    private(set) var myPullRequests: [PullRequest] = []
    private(set) var reviewRequests: [PullRequest] = []
    private(set) var pendingRuns: [WorkflowRun] = []
    private(set) var lastUpdated: Date?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    @ObservationIgnored private var refreshQueued = false
    private static let reposKey = "selectedRepos"
    /// Demo mode shows `DemoData` and never touches GitHub or the saved selection.
    private let isDemo: Bool

    init(demo: Bool = false) {
        isDemo = demo
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
            availableRepos = try await GitHubClient.authenticated().fetchAccessibleRepos()
            availableReposError = nil
        } catch {
            availableReposError = error.localizedDescription
        }
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
            client = try await GitHubClient.authenticated()
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        // The two halves load independently so one failing doesn't blank the other.
        async let pullRequests = client.fetchPullRequests(repos: repos)
        async let runs = client.fetchPendingRuns(repos: repos)
        var errors: [String] = []
        do {
            (myPullRequests, reviewRequests) = try await pullRequests
        } catch {
            errors.append("Pull requests: \(error.localizedDescription)")
        }
        do {
            pendingRuns = try await runs
        } catch {
            errors.append("Workflow runs: \(error.localizedDescription)")
        }

        errorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")
        if errors.count < 2 {
            lastUpdated = .now
        }
    }
}
