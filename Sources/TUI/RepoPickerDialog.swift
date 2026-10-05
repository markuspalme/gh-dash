import Foundation
import TermKit

/// Dialog for choosing which repositories the dashboard covers: a filter
/// field above a list where Space marks and unmarks repositories.
@MainActor
final class RepoPickerDialog {
    private let store: DashboardStore
    private let onDone: () -> Void
    private let dialog: Dialog
    private let filterField = TextField("")
    private let list: ListView
    private let source = Source()
    private let note = Label("")

    init(store: DashboardStore, onDone: @escaping () -> Void) {
        self.store = store
        self.onDone = onDone
        let size = Application.terminalSize
        let width = min(70, max(50, size.width - 6))
        let height = min(26, max(14, size.height - 4))

        let okButton = Button("OK")
        okButton.isDefault = true
        let cancelButton = Button("Cancel")
        dialog = Dialog(title: "Repositories", width: width, height: height, buttons: [okButton, cancelButton])

        let label = Label("Filter:")
        label.x = Pos.at(1)
        label.y = Pos.at(0)
        filterField.x = Pos.at(9)
        filterField.y = Pos.at(0)
        filterField.width = Dim.fill(1)

        list = ListView(dataSource: source, renderWith: { _, _ in "" })
        list.dataSource = source
        list.delegate = source
        list.allowMarking = true
        list.allowsMultipleSelection = true
        // ListView draws exactly one marker column.
        list.markerStrings = [" ", "✓"]
        list.x = Pos.at(1)
        list.y = Pos.at(2)
        list.width = Dim.fill(1)
        list.height = Dim.fill(3)

        note.x = Pos.at(1)
        note.y = Pos.anchorEnd(margin: 2)
        note.width = Dim.fill(1)

        dialog.addSubviews([label, filterField, list, note])

        source.marked = Set(store.repos.map(\.fullName))
        source.pinned = store.repos
        filterField.textChanged = { [weak self] field, _ in
            self?.source.filter = field.text
            self?.list.reload()
            self?.list.setNeedsDisplay()
        }
        okButton.clicked = { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
            Application.requestStop()
        }
        cancelButton.clicked = { [weak self] _ in
            Application.requestStop()
            MainActor.assumeIsolated { self?.onDone() }
        }
        filterField.onSubmit = { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
            Application.requestStop()
        }
    }

    func present() {
        Application.present(top: dialog)
        // The dialog would otherwise start on its OK button. TermKit only
        // focuses direct children, so walk the chain down to the field.
        var chain: [View] = []
        var current: View? = filterField
        while let view = current, view !== dialog {
            chain.append(view)
            current = view.superview
        }
        for view in chain.reversed() {
            view.superview?.setFocus(view)
        }
        note.text = store.availableRepos.isEmpty ? "Loading repositories…" : ""
        Task { @MainActor in
            await store.loadAvailableRepos()
            source.available = store.availableRepos
            if let error = store.availableReposError {
                note.text = error
            } else if store.availableReposHiddenBySSO {
                note.text = "Some organisations are hidden: authorise the token for their single sign-on."
            } else {
                note.text = "Space marks a repository, Enter applies, Esc cancels."
            }
            list.reload()
            list.setNeedsDisplay()
        }
    }

    private func apply() {
        let marked = source.marked
        for repo in source.pinned + source.available where store.repos.contains(repo) != marked.contains(repo.fullName) {
            store.setRepo(repo, selected: marked.contains(repo.fullName))
        }
        onDone()
    }

    /// The rows: repositories selected when the dialog opened first, then
    /// everything else the account can see, narrowed by the filter text.
    private final class Source: ListViewDataSource, ListViewDelegate {
        var pinned: [Repo] = []
        var available: [Repo] = []
        var marked: Set<String> = []
        var filter = ""

        var rows: [Repo] {
            let rest = available.filter { !pinned.contains($0) }
                .sorted { $0.fullName.localizedStandardCompare($1.fullName) == .orderedAscending }
            let all = pinned + rest
            guard !filter.isEmpty else { return all }
            return all.filter { $0.fullName.localizedCaseInsensitiveContains(filter) }
        }

        func getCount(listView: ListView) -> Int { rows.count }

        func isMarked(listView: ListView, item: Int) -> Bool {
            rows.indices.contains(item) && marked.contains(rows[item].fullName)
        }

        func setMark(listView: ListView, item: Int, state: Bool) {
            guard rows.indices.contains(item) else { return }
            if state {
                marked.insert(rows[item].fullName)
            } else {
                marked.remove(rows[item].fullName)
            }
        }

        func render(listView: ListView, painter: Painter, selected: Bool, item: Int, col: Int, line: Int, width: Int) {
            guard rows.indices.contains(item) else { return }
            let repo = rows[item]
            let highlighted = selected && listView.hasFocus
            painter.attribute = Style.normal.attribute(selected: highlighted)
            painter.goto(col: col, row: line)
            painter.add(str: String(repeating: " ", count: width))
            painter.goto(col: col + 1, row: line)
            let room = max(1, width - 1)
            let name = repo.fullName.count > room ? String(repo.fullName.prefix(room - 1)) + "…" : repo.fullName
            painter.add(str: name)
        }

        func selectionChanged(listView: ListView) {}

        // Enter is left to the dialog's default button, so it applies the selection.
        func activate(listView: ListView, item: Int) -> Bool { false }
    }
}
