import SwiftUI

/// The scrolling dashboard: pull request sections followed by pending workflow runs.
struct DashboardView: View {
    let store: DashboardStore
    /// The repository to show, or nil for all selected ones.
    let scope: Repo?
    let filter: PullRequestFilter
    let chooseRepos: () -> Void
    /// Newline-separated ids of the sections the user has collapsed.
    @AppStorage("collapsedSections") private var collapsedSections = ""

    var body: some View {
        // A plain stack, not a List: in a split view's detail column, List
        // clipped rows to their first line when the data arrived after launch.
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
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
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Keyed on the stored value: a change that arrives through
            // AppStorage does not carry a withAnimation transaction.
            .animation(.easeInOut(duration: 0.2), value: collapsedSections)
        }
        .overlay {
            if store.repos.isEmpty {
                ContentUnavailableView {
                    Label("No Repositories", systemImage: "books.vertical")
                } description: {
                    Text("Choose the repositories to show on the dashboard.")
                } actions: {
                    Button("Choose Repositories…", action: chooseRepos)
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
        let pullRequests = store.pullRequests(all, in: scope)
        let visible = pullRequests.filter(filter.shows)
        return DashboardSection(
            title: title,
            count: visible.count,
            isExpanded: isExpanded(id),
            note: filter.hiddenNote(for: pullRequests)
        ) {
            if visible.isEmpty {
                EmptyRow(text: "None")
            }
            ForEach(visible) { pullRequest in
                PullRequestRow(pullRequest: pullRequest, showAuthor: showAuthor)
                Divider()
            }
        }
    }

    @ViewBuilder
    private var pendingRunSections: some View {
        let repos = scope.map { [$0] } ?? store.repos
        if !store.pendingRuns.contains(where: { repos.contains($0.repo) }) {
            DashboardSection(title: "Pending actions", count: 0, isExpanded: isExpanded("runs")) {
                EmptyRow(text: "No pending workflow runs")
            }
        }
        ForEach(repos) { repo in
            let runs = store.pendingRuns.filter { $0.repo == repo }
            if !runs.isEmpty {
                DashboardSection(
                    title: "Pending actions · \(repo.name)",
                    count: runs.count,
                    isExpanded: isExpanded("runs:\(repo.fullName)"),
                    link: repo.actionsURL
                ) {
                    ForEach(runs) { run in
                        WorkflowRunRow(run: run)
                        Divider()
                    }
                }
            }
        }
    }
}

/// A collapsible group of rows under a header.
private struct DashboardSection<Rows: View>: View {
    let title: String
    let count: Int
    @Binding var isExpanded: Bool
    var note: String?
    var link: URL?
    @ViewBuilder var rows: Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: title, count: count, isExpanded: $isExpanded, note: note, link: link)
            Divider()
            // Collapsed rows stay in the hierarchy at zero height, so the
            // section folds shut instead of popping out of the layout.
            VStack(alignment: .leading, spacing: 0) {
                rows
            }
            .frame(height: isExpanded ? nil : 0, alignment: .top)
            .clipped()
            .opacity(isExpanded ? 1 : 0)
            .allowsHitTesting(isExpanded)
            .accessibilityHidden(!isExpanded)
        }
        .padding(.bottom, 22)
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
                isExpanded.toggle()
            } label: {
                // On a narrow screen the "hidden" note is the first thing to go.
                ViewThatFits(in: .horizontal) {
                    label(note: note)
                    label(note: nil)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Collapse section" : "Expand section")
            Spacer(minLength: 8)
            if let link {
                Link(destination: link) {
                    Label("Open on GitHub", systemImage: "arrow.up.right")
                        .font(.caption)
                        #if os(iOS)
                        .labelStyle(.iconOnly)
                        #endif
                }
                #if os(macOS)
                .pointerStyle(.link)
                #endif
            }
        }
        .padding(.vertical, 8)
    }

    private func label(note: String?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 12)
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(verbatim: "\(count)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
            if let note {
                Text("· \(note)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }
}

private struct EmptyRow: View {
    let text: String

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
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
