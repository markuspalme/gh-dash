import SwiftUI

struct ContentView: View {
    let store: DashboardStore
    @Environment(\.openURL) private var openURL
    @AppStorage("hideDrafts") private var hideDrafts = true
    @AppStorage("hideFailingDependabot") private var hideFailingDependabot = true
    /// Full name of the repository the dashboard is scoped to; empty for all.
    @AppStorage("scopedRepo") private var scopedRepoName = ""
    /// Newline-separated ids of the sections the user has collapsed.
    @AppStorage("collapsedSections") private var collapsedSections = ""
    @State private var isChoosingRepos = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            dashboard
        }
        .sheet(isPresented: $isChoosingRepos) {
            Task { await store.refresh() }
        } content: {
            RepoPicker(store: store)
        }
        .task { await store.runAutoRefresh() }
        .onChange(of: waitingOnMeCount(in: nil), initial: true) { _, count in
            NSApplication.shared.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await store.refreshIfStale() }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: scopeSelection) {
            Label("All Repositories", systemImage: "square.stack")
                .badge(itemCount(in: nil))
                .tag("")
            Section("Repositories") {
                ForEach(store.repos) { repo in
                    Label(repo.name, systemImage: "book.closed")
                        .badge(itemCount(in: repo))
                        .tag(repo.fullName)
                        .help(repo.fullName)
                        .contextMenu {
                            Button("Open on GitHub") { openURL(repo.url) }
                            Button("Open Actions on GitHub") { openURL(repo.actionsURL) }
                        }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 190, ideal: 240, max: 360)
        .safeAreaInset(edge: .bottom) {
            Button {
                isChoosingRepos = true
            } label: {
                Label("Choose Repositories…", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(12)
        }
    }

    /// The repository the dashboard is scoped to, or nil for all of them.
    private var scope: Repo? {
        store.repos.first { $0.fullName == scopedRepoName }
    }

    private var scopeSelection: Binding<String?> {
        Binding(
            get: { scope?.fullName ?? "" },
            set: { scopedRepoName = $0 ?? "" }
        )
    }

    // MARK: Dashboard

    private var dashboard: some View {
        List {
            if store.lastUpdated != nil {
                pullRequestSection(
                    "My open pull requests", id: "mine",
                    store.myPullRequests.filter { !$0.isOnlyAwaitingReview },
                    showAuthor: false
                )
                pullRequestSection(
                    "Awaiting your review", id: "review",
                    store.reviewRequests,
                    showAuthor: true
                )
                pullRequestSection(
                    "My pull requests waiting on reviewers", id: "waiting",
                    store.myPullRequests.filter(\.isOnlyAwaitingReview),
                    showAuthor: false
                )
                pendingRunSections
            }
        }
        .listStyle(.inset)
        .overlay {
            if store.repos.isEmpty {
                ContentUnavailableView {
                    Label("No Repositories", systemImage: "books.vertical")
                } description: {
                    Text("Choose the repositories to show on the dashboard.")
                } actions: {
                    Button("Choose Repositories…") { isChoosingRepos = true }
                }
                .background()
            } else if store.lastUpdated == nil, store.isLoading {
                ProgressView("Loading…")
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let message = store.errorMessage {
                ErrorBanner(message: message)
            }
        }
        .navigationTitle(scope?.name ?? "All Repositories")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem {
                ToolbarSwitch(title: "Hide Drafts", isOn: $hideDrafts)
                    .help("Hide draft pull requests")
            }
            ToolbarItem {
                ToolbarSwitch(title: "Hide Failing Dependabot", isOn: $hideFailingDependabot)
                    .help("Hide Dependabot pull requests with a failing check")
            }
            ToolbarItem {
                Menu {
                    ForEach(store.repos) { repo in
                        Button(repo.fullName) { openURL(repo.url) }
                    }
                    Divider()
                    Button("Choose Repositories…") { isChoosingRepos = true }
                } label: {
                    Label("Repositories", systemImage: "books.vertical")
                }
                .help("Open a repository on GitHub, or choose which ones to show")
            }
            ToolbarItem {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r")
                .disabled(store.isLoading)
                .help("Refresh (⌘R)")
            }
        }
    }

    private var subtitle: String {
        if store.isLoading { return "Refreshing…" }
        guard let lastUpdated = store.lastUpdated else { return "" }
        return "Updated \(lastUpdated.formatted(date: .omitted, time: .shortened))"
    }

    private func visible(_ pullRequests: [PullRequest]) -> [PullRequest] {
        pullRequests.filter {
            !(hideDrafts && $0.isDraft) && !(hideFailingDependabot && $0.isFailingDependabot)
        }
    }

    private func pullRequests(_ pullRequests: [PullRequest], in repo: Repo?) -> [PullRequest] {
        guard let repo else { return pullRequests }
        return pullRequests.filter { $0.repoFullName == repo.fullName }
    }

    /// Rows the dashboard shows for `repo` (nil for all repositories), shown
    /// as the sidebar badge.
    private func itemCount(in repo: Repo?) -> Int {
        visible(pullRequests(store.myPullRequests, in: repo)).count
            + visible(pullRequests(store.reviewRequests, in: repo)).count
            + store.pendingRuns.filter { repo == nil || $0.repo == repo }.count
    }

    /// Things waiting on the user in `repo` (nil for all repositories): visible
    /// review requests, their own visible PRs that need fixing, and deployments
    /// they can approve. The total is the Dock badge.
    private func waitingOnMeCount(in repo: Repo?) -> Int {
        visible(pullRequests(store.reviewRequests, in: repo)).count
            + visible(pullRequests(store.myPullRequests, in: repo)).filter(\.needsAuthorAttention).count
            + store.pendingRuns.filter { $0.canApprove && (repo == nil || $0.repo == repo) }.count
    }

    private func isExpanded(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedSections.split(separator: "\n").contains(Substring(id)) },
            set: { expanded in
                var collapsed = collapsedSections.split(separator: "\n").map(String.init).filter { $0 != id }
                if !expanded { collapsed.append(id) }
                collapsedSections = collapsed.joined(separator: "\n")
            }
        )
    }

    private func pullRequestSection(
        _ title: String, id: String, _ all: [PullRequest], showAuthor: Bool
    ) -> some View {
        let isExpanded = isExpanded(id)
        let pullRequests = pullRequests(all, in: scope)
        let visible = visible(pullRequests)
        let hiddenDrafts = hideDrafts ? pullRequests.filter(\.isDraft).count : 0
        let hiddenDependabot = pullRequests.count - visible.count - hiddenDrafts
        var notes: [String] = []
        if hiddenDrafts > 0 {
            notes.append("\(hiddenDrafts) \(hiddenDrafts == 1 ? "draft" : "drafts") hidden")
        }
        if hiddenDependabot > 0 {
            notes.append("\(hiddenDependabot) failing Dependabot hidden")
        }
        return Section(isExpanded: isExpanded) {
            if visible.isEmpty {
                EmptyRow(text: "None")
            }
            ForEach(visible) { pullRequest in
                PullRequestRow(pullRequest: pullRequest, showAuthor: showAuthor)
            }
        } header: {
            SectionHeader(
                title: title,
                count: visible.count,
                isExpanded: isExpanded,
                note: notes.isEmpty ? nil : notes.joined(separator: ", ")
            )
        }
    }

    @ViewBuilder
    private var pendingRunSections: some View {
        let repos = scope.map { [$0] } ?? store.repos
        if !store.pendingRuns.contains(where: { repos.contains($0.repo) }) {
            let isExpanded = isExpanded("runs")
            Section(isExpanded: isExpanded) {
                EmptyRow(text: "No pending workflow runs")
            } header: {
                SectionHeader(title: "Pending actions", count: 0, isExpanded: isExpanded)
            }
        }
        ForEach(repos) { repo in
            let runs = store.pendingRuns.filter { $0.repo == repo }
            if !runs.isEmpty {
                let isExpanded = isExpanded("runs:\(repo.fullName)")
                Section(isExpanded: isExpanded) {
                    ForEach(runs) { run in
                        WorkflowRunRow(run: run)
                    }
                } header: {
                    SectionHeader(
                        title: "Pending actions · \(repo.name)",
                        count: runs.count,
                        isExpanded: isExpanded,
                        link: repo.actionsURL
                    )
                }
            }
        }
    }
}

private struct ToolbarSwitch: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
        .padding(.horizontal, 6)
    }
}

private struct SectionHeader: View {
    let title: String
    let count: Int
    @Binding var isExpanded: Bool
    var note: String?
    var link: URL?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12)
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(verbatim: "\(count)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if let note {
                        Text("· \(note)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Collapse section" : "Expand section")
            Spacer()
            if let link {
                Link(destination: link) {
                    Label("Open on GitHub", systemImage: "arrow.up.right")
                        .font(.caption)
                }
                .pointerStyle(.link)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct EmptyRow: View {
    let text: String

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
    }
}

private struct ErrorBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.orange.opacity(0.2))
    }
}
