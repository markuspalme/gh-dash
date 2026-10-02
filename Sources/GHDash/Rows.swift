import SwiftUI

// MARK: - Pull request row

struct PullRequestRow: View {
    let pullRequest: PullRequest
    let showAuthor: Bool

    var body: some View {
        LinkRow(url: pullRequest.url) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(pullRequest.title)
                        .fontWeight(.medium)
                        .lineLimit(2)
                    Spacer(minLength: 12)
                    RelativeTime(date: pullRequest.updatedAt)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                FlowLayout(spacing: 6) {
                    if pullRequest.isDraft {
                        Badge("Draft", symbol: "pencil", tint: .secondary)
                    }
                    reviewBadge
                    approvalsBadge
                    if !pullRequest.review.waitingOn.isEmpty {
                        Badge("Waiting on \(pullRequest.review.waitingOn.joined(separator: ", "))", symbol: "person", tint: .secondary)
                    }
                    checksBadge
                    if pullRequest.unresolvedThreads > 0 {
                        Badge("\(pullRequest.unresolvedThreads) unresolved", symbol: "bubble.left", tint: .orange)
                    }
                    if pullRequest.hasConflicts {
                        Badge("Conflicts", symbol: "exclamationmark.triangle.fill", tint: .red)
                    }
                }
            }
        }
    }

    private var detail: String {
        var parts = ["\(pullRequest.repoName) #\(pullRequest.number)"]
        if showAuthor, let author = pullRequest.author {
            parts.append(author)
        }
        parts.append("\(pullRequest.headRef) → \(pullRequest.baseRef)")
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var reviewBadge: some View {
        let review = pullRequest.review
        switch review.decision {
        case .approved:
            Badge("Approved", symbol: "checkmark.circle.fill", tint: .green)
        case .changesRequested:
            Badge("Changes requested", symbol: "xmark.circle.fill", tint: .red)
                .help("Changes requested by \(review.changesRequestedBy.joined(separator: ", "))")
        case .reviewRequired:
            Badge("Review required", symbol: "eye", tint: .orange)
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private var approvalsBadge: some View {
        let approvers = pullRequest.review.approvedBy
        if approvers.isEmpty {
            Badge("0 approvals", symbol: "hand.thumbsup", tint: .secondary)
        } else {
            Badge(approvers.count == 1 ? "1 approval" : "\(approvers.count) approvals", symbol: "hand.thumbsup.fill", tint: .green)
                .help("Approved by \(approvers.joined(separator: ", "))")
        }
    }

    @ViewBuilder
    private var checksBadge: some View {
        let checks = pullRequest.checks
        if checks.total == 0 {
            Badge("No checks", symbol: "circle.dashed", tint: .secondary)
        } else if !checks.failedNames.isEmpty {
            Badge("\(checks.failedNames.count) of \(checks.total) checks failing", symbol: "xmark.circle.fill", tint: .red)
                .help("Failing: \(checks.failedNames.joined(separator: ", "))")
        } else if !checks.pendingNames.isEmpty {
            Badge("\(checks.pendingNames.count) of \(checks.total) checks running", symbol: "clock", tint: .orange)
                .help("Running: \(checks.pendingNames.joined(separator: ", "))")
        } else {
            Badge("\(checks.total) checks passed", symbol: "checkmark.circle.fill", tint: .green)
        }
    }
}

// MARK: - Workflow run row

struct WorkflowRunRow: View {
    let run: WorkflowRun

    var body: some View {
        LinkRow(url: run.url) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(run.workflowName)
                        .fontWeight(.medium)
                    Text(verbatim: "#\(run.runNumber)")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    RelativeTime(date: run.createdAt)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                FlowLayout(spacing: 6) {
                    statusBadge
                    if run.canApprove {
                        Badge("You can approve", symbol: "checkmark.shield", tint: .blue)
                    }
                    if let branch = run.branch {
                        Badge(branch, symbol: "arrow.triangle.branch", tint: .secondary)
                    }
                }
            }
        }
    }

    private var detail: String {
        [run.title, run.actor, run.event]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch run.status {
        case "waiting":
            let environments = run.pendingEnvironments.map(\.name).joined(separator: ", ")
            Badge(environments.isEmpty ? "Awaiting approval" : "Awaiting approval: \(environments)", symbol: "hand.raised.fill", tint: .orange)
        case "action_required":
            Badge("Action required", symbol: "exclamationmark.circle.fill", tint: .red)
        case "in_progress":
            Badge("In progress", symbol: "play.circle.fill", tint: .blue)
        case "queued":
            Badge("Queued", symbol: "hourglass", tint: .secondary)
        default:
            Badge(run.status.replacingOccurrences(of: "_", with: " ").capitalized, symbol: "clock", tint: .secondary)
        }
    }
}

// MARK: - Building blocks

/// A list row that opens `url` in the browser when clicked.
struct LinkRow<Content: View>: View {
    let url: URL
    @ViewBuilder var content: Content
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            openURL(url)
        } label: {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .contextMenu {
            Button("Open in Browser") { openURL(url) }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
        }
    }
}

struct Badge: View {
    let text: String
    let symbol: String
    let tint: Color

    init(_ text: String, symbol: String, tint: Color) {
        self.text = text
        self.symbol = symbol
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(text)
                .lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tint.opacity(0.14), in: Capsule())
    }
}

struct RelativeTime: View {
    let date: Date

    var body: some View {
        Text(date, format: .relative(presentation: .named))
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(date.formatted(date: .abbreviated, time: .shortened))
    }
}

/// Lays subviews out left to right, wrapping onto new lines when out of width.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let origins = arrange(width: bounds.width, subviews: subviews).origins
        for (subview, origin) in zip(subviews, origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            usedWidth = max(usedWidth, x + size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: usedWidth, height: y + rowHeight), origins)
    }
}
