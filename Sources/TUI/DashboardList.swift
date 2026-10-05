import Foundation
import TermKit

/// The scrolling dashboard: section headers and one line per pull request
/// or workflow run, drawn from `rows`. It knows nothing about the store;
/// `DashboardScreen` feeds it rows and reacts to its callbacks.
final class DashboardList: View {
    var rows: [DashboardRow] = [] {
        didSet {
            if rows.indices.contains(selected), rows[selected].isSelectable {
                // keep the cursor where it was
            } else {
                selected = rows.firstIndex(where: \.isSelectable) ?? 0
            }
            clampScroll()
            setNeedsDisplay()
        }
    }
    /// Shown instead of rows while nothing has loaded yet.
    var placeholder = "Loading…" {
        didSet { setNeedsDisplay() }
    }
    private(set) var selected = 0
    private var top = 0

    var onOpen: ((DashboardRow) -> Void)?
    var onToggleSection: ((String) -> Void)?

    override init() {
        super.init()
        canFocus = true
    }

    var selectedRow: DashboardRow? {
        rows.indices.contains(selected) ? rows[selected] : nil
    }

    // MARK: Drawing

    override func redraw(region: Rect, painter: Painter) {
        painter.attribute = Style.normal.attribute(selected: false)
        painter.clear()
        let width = bounds.width
        guard !rows.isEmpty else {
            painter.attribute = Style.dim.attribute(selected: false)
            painter.goto(col: 1, row: 0)
            painter.add(str: placeholder)
            return
        }
        for line in 0..<bounds.height {
            let index = top + line
            guard index < rows.count else { break }
            let isSelected = index == selected && hasFocus
            let segments = segments(for: rows[index], width: width - 2)
            painter.attribute = Style.normal.attribute(selected: isSelected)
            painter.goto(col: 0, row: line)
            painter.add(str: String(repeating: " ", count: width))
            painter.goto(col: 1, row: line)
            var column = 1
            for segment in segments {
                let room = width - 1 - column
                guard room > 0 else { break }
                let text = segment.text.count > room ? String(segment.text.prefix(max(0, room - 1))) + "…" : segment.text
                painter.attribute = segment.style.attribute(selected: isSelected)
                painter.add(str: text)
                column += text.count
            }
        }
    }

    /// The pieces of one line, laid out for `width` columns.
    private func segments(for row: DashboardRow, width: Int) -> [Segment] {
        switch row {
        case .header(_, let title, let count, let note, let isExpanded, _):
            var segments = [Segment(isExpanded ? "▾ " : "▸ ", .dim), Segment(title, .bold), Segment("  \(count)", .dim)]
            if let note {
                segments.append(Segment(" · \(note)", .dim))
            }
            return segments
        case .pullRequest(let pullRequest, let showAuthor, _):
            var prefix = "  \(pullRequest.repoName) #\(pullRequest.number)"
            if showAuthor, let author = pullRequest.author {
                prefix += " · \(author)"
            }
            return line(prefix: prefix, title: pullRequest.title, badges: Badges.forPullRequest(pullRequest), age: pullRequest.updatedAt, width: width)
        case .run(let run, _):
            let prefix = "  \(run.workflowName) #\(run.runNumber)"
            return line(prefix: prefix, title: run.title, badges: Badges.forRun(run), age: run.createdAt, width: width)
        case .empty(let text, _):
            return [Segment("  \(text)", .dim)]
        case .blank:
            return []
        }
    }

    /// prefix · title (truncated to fit)   badge badge   age
    private func line(prefix: String, title: String, badges: [Segment], age: Date, width: Int) -> [Segment] {
        let ageText = shortAge(of: age)
        let badgeWidth = badges.reduce(0) { $0 + $1.text.count + 2 }
        let fixed = prefix.count + 3 + badgeWidth + 2 + ageText.count
        let titleRoom = max(8, width - fixed)
        let shownTitle = title.count > titleRoom ? String(title.prefix(titleRoom - 1)) + "…" : title
        var segments = [Segment(prefix, .dim), Segment(" · ", .dim), Segment(shownTitle, .normal)]
        for badge in badges {
            segments.append(Segment("  ", .normal))
            segments.append(badge)
        }
        let used = prefix.count + 3 + shownTitle.count + badgeWidth
        let gap = max(1, width - used - ageText.count)
        segments.append(Segment(String(repeating: " ", count: gap) + ageText, .dim))
        return segments
    }

    // MARK: Keys

    override func processKey(event: KeyEvent) -> Bool {
        switch event.key {
        case .cursorDown, .letter("j"):
            move(by: 1)
        case .cursorUp, .letter("k"):
            move(by: -1)
        case .pageDown:
            move(by: max(1, bounds.height - 1))
        case .pageUp:
            move(by: -max(1, bounds.height - 1))
        case .home, .letter("g"):
            jump(to: rows.firstIndex(where: \.isSelectable) ?? 0)
        case .end, .letter("G"):
            jump(to: rows.lastIndex(where: \.isSelectable) ?? 0)
        case .controlJ, .controlM:
            guard let row = selectedRow else { return true }
            if case .header(let id, _, _, _, _, _) = row {
                onToggleSection?(id)
            } else {
                onOpen?(row)
            }
        case .letter(" "), .letter("c"):
            if let id = selectedRow?.sectionID {
                onToggleSection?(id)
            }
        case .letter("o"):
            if let row = selectedRow, row.url != nil {
                onOpen?(row)
            }
        default:
            return super.processKey(event: event)
        }
        return true
    }

    private func move(by delta: Int) {
        guard !rows.isEmpty else { return }
        var index = selected
        let step = delta > 0 ? 1 : -1
        var remaining = abs(delta)
        while remaining > 0 {
            var next = index + step
            while rows.indices.contains(next), !rows[next].isSelectable {
                next += step
            }
            guard rows.indices.contains(next) else { break }
            index = next
            remaining -= 1
        }
        jump(to: index)
    }

    private func jump(to index: Int) {
        selected = index
        clampScroll()
        setNeedsDisplay()
    }

    private func clampScroll() {
        let height = max(1, bounds.height)
        if selected < top {
            top = selected
        } else if selected >= top + height {
            top = selected - height + 1
        }
        top = max(0, min(top, max(0, rows.count - height)))
    }

    override func positionCursor() {
        moveTo(col: 0, row: max(0, selected - top))
    }
}
