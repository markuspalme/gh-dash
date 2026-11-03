import SwiftUI

// MARK: - Pull request row

struct PullRequestRow: View {
    let pullRequest: PullRequest
    let showAuthor: Bool
    /// Offered on pull requests the user was asked to review.
    var approval: ApprovalAction?
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// On a phone the badges shrink to icons and numbers so they fit one line.
    private var isCompact: Bool { sizeClass == .compact }

    var body: some View {
        LinkRow(url: pullRequest.url, approval: approval) {
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
                        Badge(
                            waitingOnText,
                            compact: "\(pullRequest.review.waitingOn.count)",
                            symbol: "person", tint: .secondary
                        )
                    }
                    checksBadge
                    if pullRequest.unresolvedThreads > 0 {
                        Badge(
                            "\(pullRequest.unresolvedThreads) unresolved",
                            compact: "\(pullRequest.unresolvedThreads)",
                            symbol: "bubble.left", tint: .orange
                        )
                    }
                    if pullRequest.hasConflicts {
                        Badge("Conflicts", compact: "", symbol: "exclamationmark.triangle.fill", tint: .red)
                    }
                }
            }
        }
    }

    /// Who the pull request is waiting on. iOS has no room for a list of
    /// names, so several reviewers become a count there.
    private var waitingOnText: String {
        let reviewers = pullRequest.review.waitingOn
        #if os(iOS)
        if reviewers.count > 1 {
            return "Waiting on \(reviewers.count) reviewers"
        }
        #endif
        return "Waiting on \(reviewers.joined(separator: ", "))"
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
        // The compact symbols differ from the checks badge's, which they
        // would otherwise be mistaken for once the words are gone.
        case .approved:
            Badge("Approved", compact: "", symbol: "checkmark.circle.fill", compactSymbol: "checkmark.seal.fill", tint: .green)
        case .changesRequested:
            Badge("Changes requested", compact: "", symbol: "xmark.circle.fill", compactSymbol: "hand.thumbsdown.fill", tint: .red)
                .help("Changes requested by \(review.changesRequestedBy.joined(separator: ", "))")
        case .reviewRequired:
            Badge("Review required", compact: "", symbol: "eye", tint: .orange)
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private var approvalsBadge: some View {
        let approvers = pullRequest.review.approvedBy
        if approvers.isEmpty {
            if !isCompact {
                Badge("0 approvals", symbol: "hand.thumbsup", tint: .secondary)
            }
        } else {
            Badge(
                approvers.count == 1 ? "1 approval" : "\(approvers.count) approvals",
                compact: "\(approvers.count)",
                symbol: "hand.thumbsup.fill", tint: .green
            )
            .help("Approved by \(approvers.joined(separator: ", "))")
        }
    }

    @ViewBuilder
    private var checksBadge: some View {
        let checks = pullRequest.checks
        if checks.total == 0 {
            if !isCompact {
                Badge("No checks", symbol: "circle.dashed", tint: .secondary)
            }
        } else if !checks.failedNames.isEmpty {
            Badge(
                "\(checks.failedNames.count) of \(checks.total) checks failing",
                compact: "\(checks.failedNames.count)/\(checks.total)",
                symbol: "xmark.circle.fill", tint: .red
            )
            .help("Failing: \(checks.failedNames.joined(separator: ", "))")
        } else if !checks.pendingNames.isEmpty {
            Badge(
                "\(checks.pendingNames.count) of \(checks.total) checks running",
                compact: "\(checks.pendingNames.count)/\(checks.total)",
                symbol: "clock", tint: .orange
            )
            .help("Running: \(checks.pendingNames.joined(separator: ", "))")
        } else {
            Badge("\(checks.total) checks passed", compact: "\(checks.total)", symbol: "checkmark.circle.fill", tint: .green)
        }
    }
}

// MARK: - Workflow run row

struct WorkflowRunRow: View {
    let run: WorkflowRun
    /// Offered on deployments the user may approve and on held runs.
    var approval: ApprovalAction?

    var body: some View {
        LinkRow(url: run.url, approval: approval) {
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
                        Badge("You can approve", compact: "", symbol: "checkmark.shield", tint: .blue)
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
            Badge(
                environments.isEmpty ? "Awaiting approval" : "Awaiting approval: \(environments)",
                compact: environments.isEmpty ? "Approval" : environments,
                symbol: "hand.raised.fill", tint: .orange
            )
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

// MARK: - Approving

/// Something the user can approve from the dashboard, and how to ask first.
struct ApprovalAction {
    let title: String
    let question: String
    let message: String
    let isInFlight: Bool
    let perform: () -> Void
}

// MARK: - Building blocks

/// A list row that opens `url` in the browser when clicked. With an
/// `approval`, swiping the row to the left approves it once the user
/// confirms, as in Mail: a finger on iOS, two fingers on a Mac trackpad.
/// The context menu offers the same, for a mouse and for VoiceOver.
struct LinkRow<Content: View>: View {
    let url: URL
    var approval: ApprovalAction?
    @ViewBuilder var content: Content
    @Environment(\.openURL) private var openURL
    @State private var isConfirming = false

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
        #if os(macOS)
        .pointerStyle(.link)
        #endif
        .contextMenu {
            if let approval {
                Button {
                    isConfirming = true
                } label: {
                    Label("\(approval.title)…", systemImage: "checkmark")
                }
                .disabled(approval.isInFlight)
                Divider()
            }
            Button("Open in Browser") { openURL(url) }
            Button("Copy Link") {
                #if os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
                #else
                UIPasteboard.general.string = url.absoluteString
                #endif
            }
        }
        .modifier(SwipeToApprove(
            isEnabled: approval.map { !$0.isInFlight } ?? false,
            isInFlight: approval?.isInFlight ?? false,
            trigger: { isConfirming = true }
        ))
        .confirmationDialog(approval?.question ?? "", isPresented: $isConfirming, titleVisibility: .visible) {
            if let approval {
                Button(approval.title, action: approval.perform)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let approval {
                Text(approval.message)
            }
        }
        .accessibilityActions {
            if let approval {
                Button(approval.title) { isConfirming = true }
            }
        }
    }
}

/// Slides a row left under the finger, or two fingers on a trackpad,
/// uncovering a green check mark. Letting go once the mark has filled in
/// calls `trigger`; letting go earlier puts the row back.
private struct SwipeToApprove: ViewModifier {
    let isEnabled: Bool
    let isInFlight: Bool
    let trigger: () -> Void

    @State private var offset: CGFloat = 0
    /// Whether the current gesture is a sideways swipe; nil until it is clear.
    @State private var isHorizontal: Bool?
    #if os(macOS)
    @State private var monitor: Any?
    @State private var travel = CGSize.zero
    /// Set after a swipe, so the trackpad's momentum does not scroll the page.
    @State private var swallowMomentum = false
    #endif

    private static let threshold: CGFloat = 80

    private var isArmed: Bool { -offset >= Self.threshold }

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .opacity(isInFlight ? 0.5 : 1)
            .background(alignment: .trailing) {
                if offset < 0 {
                    ZStack(alignment: .trailing) {
                        Rectangle()
                            .fill(Color.green.opacity(isArmed ? 1 : 0.5))
                        Image(systemName: "checkmark")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                            .scaleEffect(isArmed ? 1.15 : 0.85)
                            .padding(.trailing, 20)
                    }
                    .frame(width: -offset)
                    .animation(.easeOut(duration: 0.15), value: isArmed)
                }
            }
            .overlay(alignment: .trailing) {
                if isInFlight {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .clipped()
            #if os(iOS)
            .simultaneousGesture(drag, including: isEnabled ? .all : .subviews)
            .sensoryFeedback(.impact, trigger: isArmed) { _, armed in armed }
            #else
            .onHover { hovering in
                if hovering && isEnabled {
                    startMonitoring()
                } else {
                    stopMonitoring()
                }
            }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { stopMonitoring() }
            }
            .onDisappear(perform: stopMonitoring)
            #endif
    }

    /// Follows the swipe; past the threshold it only gives a little more.
    private func follow(_ distance: CGFloat) {
        let pulled = max(0, -distance)
        let limit = Self.threshold * 1.5
        offset = -(pulled <= limit ? pulled : limit + (pulled - limit) * 0.3)
    }

    private func finish() {
        let fire = isArmed
        isHorizontal = nil
        withAnimation(.spring(duration: 0.3)) { offset = 0 }
        if fire { trigger() }
    }

    #if os(iOS)
    private var drag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                if isHorizontal == nil {
                    isHorizontal = abs(value.translation.width) > abs(value.translation.height)
                }
                if isHorizontal == true {
                    follow(value.translation.width)
                }
            }
            .onEnded { _ in finish() }
    }
    #else
    private func startMonitoring() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            handle(event) ? nil : event
        }
    }

    private func stopMonitoring() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        if offset != 0 { finish() }
    }

    /// Uses up the trackpad events of a sideways swipe; anything else,
    /// including mouse wheels, scrolls the page as usual.
    private func handle(_ event: NSEvent) -> Bool {
        guard event.hasPreciseScrollingDeltas else { return false }
        if !event.momentumPhase.isEmpty { return swallowMomentum }
        // The way the fingers moved, whatever the scrolling preference.
        let dx = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        switch event.phase {
        case .began:
            isHorizontal = nil
            swallowMomentum = false
            travel = CGSize(width: dx, height: dy)
            return false
        case .changed:
            if isHorizontal == nil {
                travel.width += dx
                travel.height += dy
                guard abs(travel.width) + abs(travel.height) > 6 else { return false }
                isHorizontal = abs(travel.width) > abs(travel.height) * 1.5
            } else {
                travel.width += dx
            }
            guard isHorizontal == true else { return false }
            follow(travel.width)
            return true
        case .ended, .cancelled:
            guard isHorizontal == true else {
                isHorizontal = nil
                return false
            }
            swallowMomentum = true
            finish()
            return true
        default:
            return false
        }
    }
    #endif
}

struct Badge: View {
    let text: String
    /// What stands beside the icon on a narrow screen: a number or a short
    /// word, "" for the icon alone, nil to keep the full text.
    let compactText: String?
    let symbol: String
    /// Icon to use on a narrow screen, when the usual one would be ambiguous without its text.
    let compactSymbol: String?
    let tint: Color
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(_ text: String, compact: String? = nil, symbol: String, compactSymbol: String? = nil, tint: Color) {
        self.text = text
        self.compactText = compact
        self.symbol = symbol
        self.compactSymbol = compactSymbol
        self.tint = tint
    }

    var body: some View {
        let isCompact = sizeClass == .compact
        let label = isCompact ? compactText ?? text : text
        HStack(spacing: 4) {
            Image(systemName: isCompact ? compactSymbol ?? symbol : symbol)
            if !label.isEmpty {
                Text(label)
                    .lineLimit(1)
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tint.opacity(0.14), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
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
/// A subview wider than the whole line is squeezed to fit, so its text truncates.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(width: bounds.width, subviews: subviews).frames
        for (subview, frame) in zip(subviews, frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            if size.width > width {
                size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            }
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            usedWidth = max(usedWidth, x + size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: usedWidth, height: y + rowHeight), frames)
    }
}
