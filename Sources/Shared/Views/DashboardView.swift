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
        container
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
            let messages = [store.approvalError, store.errorMessage].compactMap { $0 }
            if !messages.isEmpty {
                ErrorBanner(message: messages.joined(separator: "\n"))
            }
        }
    }

    private var container: some View {
        // A List, for the system's swipe actions on rows.
        List {
            sections
        }
        .listStyle(.plain)
        // Keyed on the stored value: a change that arrives through
        // AppStorage does not carry a withAnimation transaction.
        .animation(.easeInOut(duration: 0.2), value: collapsedSections)
    }

    @ViewBuilder
    private var sections: some View {
        if store.lastUpdated != nil {
            pullRequestSection(
                "My open pull requests", id: "mine",
                store.myPullRequests.filter { !$0.isOnlyAwaitingReview },
                showAuthor: false
            )
            pullRequestSection(
                "Awaiting your review", id: "review",
                store.reviewRequests,
                showAuthor: true,
                approvable: true
            )
            pullRequestSection(
                "My pull requests waiting on reviewers", id: "waiting",
                store.myPullRequests.filter(\.isOnlyAwaitingReview),
                showAuthor: false
            )
            pendingRunSections
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
        _ title: String, id: String, _ all: [PullRequest], showAuthor: Bool, approvable: Bool = false
    ) -> some View {
        let pullRequests = store.pullRequests(all, in: scope)
        // The approve action marks the review requests, which have a filter of their own.
        let visible = pullRequests.filter(approvable ? filter.showsReviewRequest : filter.shows)
        return DashboardSection(
            title: title,
            count: visible.count,
            isExpanded: isExpanded(id),
            note: filter.hiddenNote(for: pullRequests, reviewRequests: approvable)
        ) {
            if visible.isEmpty {
                EmptyRow(text: "None")
            }
            ForEach(visible) { pullRequest in
                PullRequestRow(
                    pullRequest: pullRequest, showAuthor: showAuthor,
                    approval: approvable ? approval(for: pullRequest) : nil
                )
            }
        }
    }

    private func approval(for pullRequest: PullRequest) -> ApprovalAction {
        ApprovalAction(
            title: "Approve",
            question: "Approve \(pullRequest.repoName) #\(pullRequest.number)?",
            message: "This submits an approving review of “\(pullRequest.title)” on GitHub as you.",
            isInFlight: store.approvalsInFlight.contains(DashboardStore.approvalID(for: pullRequest)),
            perform: { Task { await store.approve(pullRequest) } }
        )
    }

    private func approval(for run: WorkflowRun) -> ApprovalAction? {
        let isInFlight = store.approvalsInFlight.contains(DashboardStore.approvalID(for: run))
        if run.canApprove {
            let environments = run.approvableEnvironments.joined(separator: ", ")
            return ApprovalAction(
                title: "Approve",
                question: "Approve deployment to \(environments)?",
                message: "\(run.workflowName) #\(run.runNumber) in \(run.repo.name) continues and deploys.",
                isInFlight: isInFlight,
                perform: { Task { await store.approve(run) } }
            )
        }
        if run.needsRunApproval {
            return ApprovalAction(
                title: "Approve and Run",
                question: "Run \(run.workflowName) #\(run.runNumber)?",
                message: "GitHub held this run until a maintainer approves it, as it does for first-time contributors.",
                isInFlight: isInFlight,
                perform: { Task { await store.approve(run) } }
            )
        }
        return nil
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
                        WorkflowRunRow(run: run, approval: approval(for: run))
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
        Section {
            if isExpanded {
                rows
            }
        } header: {
            SectionHeader(title: title, count: count, isExpanded: $isExpanded, note: note, link: link)
                .padding(.top, 10)
        }
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
                // Color.primary, not .primary: a List header dims the latter.
                .foregroundStyle(Color.primary)
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
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
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
