import Foundation
import TermKit

/// "All repositories" plus one line per repository, each with its item count.
final class Sidebar: ListView, ListViewDataSource, ListViewDelegate {
    struct Entry {
        let repo: Repo?
        let count: Int

        var title: String { repo?.name ?? "All repositories" }
    }

    private var entries: [Entry] = []
    /// Set while `update` moves the selection itself, so that doesn't count as the user choosing.
    private var isUpdating = false
    var onSelect: ((Repo?) -> Void)?

    override init() {
        let placeholder = Placeholder()
        super.init(dataSource: placeholder, renderWith: { _, _ in "" })
        dataSource = self
        delegate = self
        allowMarking = false
        allowsMultipleSelection = false
        canFocus = true
    }

    /// Replaces the entries, keeping the selection on the same repository where possible.
    func update(entries: [Entry], scope: Repo?) {
        isUpdating = true
        defer { isUpdating = false }
        self.entries = entries
        reload()
        if let index = entries.firstIndex(where: { $0.repo == scope }) {
            selectedItem = index
        }
        setNeedsDisplay()
    }

    /// j and k move like the arrows, as they do in the dashboard.
    override func processKey(event: KeyEvent) -> Bool {
        switch event.key {
        case .letter("j"): return moveSelectionDown() || true
        case .letter("k"): return moveSelectionUp() || true
        default: return super.processKey(event: event)
        }
    }

    // MARK: ListViewDataSource

    func getCount(listView: ListView) -> Int { entries.count }
    func isMarked(listView: ListView, item: Int) -> Bool { false }
    func setMark(listView: ListView, item: Int, state: Bool) {}

    // MARK: ListViewDelegate

    func render(listView: ListView, painter: Painter, selected: Bool, item: Int, col: Int, line: Int, width: Int) {
        guard entries.indices.contains(item) else { return }
        let entry = entries[item]
        let highlighted = selected && listView.hasFocus
        painter.attribute = Style.normal.attribute(selected: highlighted)
        painter.goto(col: col, row: line)
        painter.add(str: String(repeating: " ", count: width))
        let count = entry.count > 0 ? "\(entry.count)" : ""
        let titleRoom = max(1, width - count.count - 2)
        let title = entry.title.count > titleRoom ? String(entry.title.prefix(titleRoom - 1)) + "…" : entry.title
        painter.goto(col: col + 1, row: line)
        painter.attribute = (entry.repo == nil ? Style.bold : Style.normal).attribute(selected: highlighted)
        painter.add(str: title)
        painter.goto(col: col + width - count.count - 1, row: line)
        painter.attribute = Style.dim.attribute(selected: highlighted)
        painter.add(str: count)
    }

    func selectionChanged(listView: ListView) {
        guard !isUpdating, entries.indices.contains(selectedItem) else { return }
        onSelect?(entries[selectedItem].repo)
    }

    func activate(listView: ListView, item: Int) -> Bool {
        guard entries.indices.contains(item) else { return false }
        onSelect?(entries[item].repo)
        return true
    }

    /// Stands in until `dataSource` is pointed at the sidebar itself.
    private final class Placeholder: ListViewDataSource {
        func getCount(listView: ListView) -> Int { 0 }
        func isMarked(listView: ListView, item: Int) -> Bool { false }
        func setMark(listView: ListView, item: Int, state: Bool) {}
    }
}
