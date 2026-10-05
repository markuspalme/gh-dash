import SwiftUI

struct ContentView: View {
    let store: DashboardStore
    @Environment(\.openURL) private var openURL
    @AppStorage(PullRequestFilter.hideDraftsKey) private var hideDrafts = true
    @AppStorage(PullRequestFilter.hideFailingDependabotKey) private var hideFailingDependabot = true
    @AppStorage(PullRequestFilter.hideDependabotKey) private var hideDependabot = false
    /// Full name of the repository the dashboard is scoped to; empty for all.
    @AppStorage("scopedRepo") private var scopedRepoName = ""
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
        .onChange(of: store.waitingOnMeCount(in: nil, filter: filter), initial: true) { _, count in
            NSApplication.shared.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await store.refreshIfStale() }
        }
    }

    private var filter: PullRequestFilter {
        PullRequestFilter(hideDrafts: hideDrafts, hideFailingDependabot: hideFailingDependabot, hideDependabot: hideDependabot)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: scopeSelection) {
            Label("All Repositories", systemImage: "square.stack")
                .badge(store.itemCount(in: nil, filter: filter))
                .tag("")
            Section("Repositories") {
                ForEach(store.repos) { repo in
                    Label(repo.name, systemImage: "book.closed")
                        .badge(store.itemCount(in: repo, filter: filter))
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
        DashboardView(store: store, scope: scope, filter: filter) {
            isChoosingRepos = true
        }
        .navigationTitle(scope?.name ?? "All Repositories")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem {
                Menu {
                    Toggle("Hide Drafts", isOn: $hideDrafts)
                    Toggle("Hide Failing Dependabot", isOn: $hideFailingDependabot)
                    Toggle("Hide All Dependabot", isOn: $hideDependabot)
                } label: {
                    // Filled while a filter is hiding something, as in Mail.
                    Label(
                        "Filter",
                        systemImage: hideDrafts || hideFailingDependabot || hideDependabot
                            ? "line.3.horizontal.decrease.circle.fill"
                            : "line.3.horizontal.decrease.circle"
                    )
                }
                .help("Choose which pull requests to hide")
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
}
