import Foundation
import TermKit

/// A piece of a row with its own colour.
struct Segment {
    let text: String
    let style: Style

    init(_ text: String, _ style: Style = .normal) {
        self.text = text
        self.style = style
    }
}

/// The handful of colours the dashboard uses, resolved to terminal
/// attributes once the driver is up. Plain text is ANSI white on black,
/// which `TerminalColors` turns into the terminal's own defaults.
enum Style: CaseIterable {
    case normal, dim, bold, green, red, yellow, blue, magenta

    /// The attribute for this style, for a normal or a selected row.
    func attribute(selected: Bool) -> Attribute {
        let back: Color = selected ? .blue : .black
        switch self {
        case .normal: return Application.makeAttribute(fore: .gray, back: back)
        case .dim: return Application.makeAttribute(fore: .darkGray, back: back)
        case .bold: return Application.makeAttribute(fore: .white, back: back, flags: .bold)
        case .green: return Application.makeAttribute(fore: .brightGreen, back: back)
        case .red: return Application.makeAttribute(fore: .brightRed, back: back)
        case .yellow: return Application.makeAttribute(fore: .brightYellow, back: back)
        case .blue: return Application.makeAttribute(fore: selected ? .brightCyan : .brightBlue, back: back)
        case .magenta: return Application.makeAttribute(fore: .brightMagenta, back: back)
        }
    }
}

/// The compact badges, one word or symbol each, that follow a row's title.
enum Badges {
    static func forPullRequest(_ pullRequest: PullRequest) -> [Segment] {
        var badges: [Segment] = []
        if pullRequest.isDraft {
            badges.append(Segment("draft", .dim))
        }
        switch pullRequest.review.decision {
        case .approved: badges.append(Segment("approved", .green))
        case .changesRequested: badges.append(Segment("changes requested", .red))
        case .reviewRequired: badges.append(Segment("review", .yellow))
        case .none: break
        }
        let approvals = pullRequest.review.approvedBy.count
        if approvals > 0 {
            badges.append(Segment("+\(approvals)", .green))
        }
        let waiting = pullRequest.review.waitingOn
        if !waiting.isEmpty {
            badges.append(Segment(waiting.count == 1 ? "waiting on \(waiting[0])" : "waiting on \(waiting.count)", .dim))
        }
        let checks = pullRequest.checks
        if !checks.failedNames.isEmpty {
            badges.append(Segment("✗ \(checks.failedNames.count)/\(checks.total)", .red))
        } else if !checks.pendingNames.isEmpty {
            badges.append(Segment("⟳ \(checks.pendingNames.count)/\(checks.total)", .yellow))
        } else if checks.total > 0 {
            badges.append(Segment("✓ \(checks.total)", .green))
        }
        if pullRequest.unresolvedThreads > 0 {
            badges.append(Segment("✎ \(pullRequest.unresolvedThreads)", .yellow))
        }
        if pullRequest.hasConflicts {
            badges.append(Segment("⚠ conflicts", .red))
        }
        return badges
    }

    static func forRun(_ run: WorkflowRun) -> [Segment] {
        var badges: [Segment] = []
        switch run.status {
        case "waiting":
            let environments = run.pendingEnvironments.map(\.name).joined(separator: ", ")
            badges.append(Segment(environments.isEmpty ? "awaiting approval" : "awaiting approval: \(environments)", .yellow))
        case "action_required": badges.append(Segment("action required", .red))
        case "in_progress": badges.append(Segment("in progress", .blue))
        case "queued": badges.append(Segment("queued", .dim))
        default: badges.append(Segment(run.status.replacingOccurrences(of: "_", with: " "), .dim))
        }
        if run.canApprove {
            badges.append(Segment("you can approve", .magenta))
        }
        if let branch = run.branch {
            badges.append(Segment(branch, .dim))
        }
        return badges
    }
}
