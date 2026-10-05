import SwiftUI

struct MobileContentView: View {
    let store: DashboardStore
    /// Signs the user out; nil in demo mode, where there is no account.
    let signOut: (() -> Void)?
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(PullRequestFilter.hideDraftsKey) private var hideDrafts = true
    @AppStorage(PullRequestFilter.hideFailingDependabotKey) private var hideFailingDependabot = true
    @AppStorage(PullRequestFilter.hideDependabotKey) private var hideDependabot = false
    /// Full name of the selected repository, "" for all of them, and nil
    /// while an iPhone is showing the repository list.
    @State private var selection: String? = ""
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
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await store.refreshIfStale() }
            }
        }
    }

    private var filter: PullRequestFilter {
        PullRequestFilter(hideDrafts: hideDrafts, hideFailingDependabot: hideFailingDependabot, hideDependabot: hideDependabot)
    }

    private var scope: Repo? {
        store.repos.first { $0.fullName == selection }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Label("All Repositories", systemImage: "square.stack")
                .badge(store.itemCount(in: nil, filter: filter))
                .tag("")
            Section("Repositories") {
                ForEach(store.repos) { repo in
                    Label(repo.name, systemImage: "book.closed")
                        .badge(store.itemCount(in: repo, filter: filter))
                        .tag(repo.fullName)
                }
            }
        }
        .navigationTitle("GHDash")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Choose Repositories…", systemImage: "books.vertical") {
                        isChoosingRepos = true
                    }
                    if let signOut {
                        Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive, action: signOut)
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
    }

    private var dashboard: some View {
        DashboardView(store: store, scope: scope, filter: filter) {
            isChoosingRepos = true
        }
        .refreshable { await store.refresh() }
        .navigationTitle(scope?.name ?? "All Repositories")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("Hide Drafts", isOn: $hideDrafts)
                    Toggle("Hide Failing Dependabot", isOn: $hideFailingDependabot)
                    Toggle("Hide All Dependabot", isOn: $hideDependabot)
                } label: {
                    Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
        }
    }
}
