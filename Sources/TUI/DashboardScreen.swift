import Foundation
import TermKit

/// The main screen: menu bar, repository sidebar, dashboard and status bar,
/// wired to a `DashboardStore`.
@MainActor
final class DashboardScreen {
    private let store: DashboardStore
    private let config: TUIConfig
    private let isDemo: Bool

    private let window = DashboardWindow()
    private let sidebar = Sidebar()
    private let dashboard = DashboardList()
    private let status = StatusBar()
    private var menuBar: MenuBar?
    private var refreshTask: Task<Void, Never>?
    private let herdr = Herdr()

    private var scope: Repo? {
        store.repos.first { $0.fullName == config.scope }
    }

    init(store: DashboardStore, config: TUIConfig, isDemo: Bool) {
        self.store = store
        self.config = config
        self.isDemo = isDemo
        layout()
    }

    // MARK: Layout

    private func layout() {
        let top = Application.top
        let showSidebar = Application.terminalSize.width >= 90
        let sidebarWidth = showSidebar ? 30 : 0

        window.x = Pos.at(0)
        window.y = Pos.at(1)
        window.width = Dim.fill()
        window.height = Dim.fill(1)
        window.onHotKey = { [weak self] key in
            MainActor.assumeIsolated { self?.handleHotKey(key) ?? false }
        }

        if showSidebar {
            let frame = Frame("Repositories")
            frame.x = Pos.at(0)
            frame.y = Pos.at(0)
            frame.width = Dim.sized(sidebarWidth)
            frame.height = Dim.fill()
            sidebar.x = Pos.at(0)
            sidebar.y = Pos.at(0)
            sidebar.width = Dim.fill()
            sidebar.height = Dim.fill()
            sidebar.onSelect = { [weak self] repo in
                MainActor.assumeIsolated { self?.setScope(repo) }
            }
            frame.addSubview(sidebar)
            window.addSubview(frame)
            sidebarFrame = frame
        }

        let dashboardFrame = Frame(title)
        dashboardFrame.x = Pos.at(sidebarWidth)
        dashboardFrame.y = Pos.at(0)
        dashboardFrame.width = Dim.fill()
        dashboardFrame.height = Dim.fill()
        dashboard.x = Pos.at(0)
        dashboard.y = Pos.at(0)
        dashboard.width = Dim.fill()
        dashboard.height = Dim.fill()
        dashboard.onOpen = { row in
            if let url = row.url { open(url) }
        }
        dashboard.onToggleSection = { [weak self] id in
            MainActor.assumeIsolated { self?.toggleSection(id) }
        }
        dashboardFrame.addSubview(dashboard)
        window.addSubview(dashboardFrame)
        self.dashboardFrame = dashboardFrame

        // Panels sort by priority alone, so each hotkey gets its own level to keep this order.
        let hotkeys: [(id: String, key: Character, label: String, priority: StatusBar.Priority, action: () -> Void)] = [
            ("refresh", "r", " Refresh", .veryHigh, { [weak self] in MainActor.assumeIsolated { self?.refreshNow() } }),
            ("drafts", "d", " Drafts", .high, { [weak self] in MainActor.assumeIsolated { self?.toggleDrafts() } }),
            ("dependabot", "b", " Dependabot", .default, { [weak self] in MainActor.assumeIsolated { self?.toggleDependabot() } }),
            ("repos", "p", " Repositories", .low, { [weak self] in MainActor.assumeIsolated { self?.chooseRepos() } }),
            ("quit", "q", " Quit", .veryLow, { [weak self] in MainActor.assumeIsolated { self?.quit() } }),
        ]
        for hotkey in hotkeys {
            status.addHotkeyPanel(
                id: hotkey.id, hotkeyText: String(hotkey.key), labelText: hotkey.label, hotkey: .letter(hotkey.key),
                action: hotkey.action, priority: hotkey.priority, placement: .leading
            )
        }
        status.addPanel(id: "updated", content: "", placement: .trailing)

        let menu = makeMenuBar()
        menuBar = menu
        top.addSubviews([menu, window, status])
        focus(dashboard)
        reload()
    }

    private var sidebarFrame: Frame?
    private var dashboardFrame: Frame?

    /// Focuses `view` down the whole chain; TermKit only focuses direct children.
    private func focus(_ view: View) {
        var chain: [View] = []
        var current: View? = view
        while let v = current, v !== Application.top {
            chain.append(v)
            current = v.superview
        }
        for v in chain.reversed() {
            v.superview?.setFocus(v)
        }
    }

    /// Tab moves between the repository list and the dashboard.
    private func switchFocus() {
        if sidebar.hasFocus {
            focus(dashboard)
        } else if sidebarFrame != nil {
            focus(sidebar)
        }
    }

    private var title: String {
        scope?.name ?? "All repositories"
    }

    private func makeMenuBar() -> MenuBar {
        let filter = config.filter
        func mark(_ on: Bool) -> String { on ? "[x] " : "[ ] " }
        var viewItems: [MenuItem?] = [
            MenuItem(title: mark(filter.hideDrafts) + "Hide _Drafts", action: { [weak self] in self?.toggleDrafts() }),
            MenuItem(title: mark(filter.hideFailingDependabot) + "Hide Failing Depend_abot", action: { [weak self] in self?.toggleDependabot() }),
            MenuItem(title: mark(filter.hideDependabot) + "Hide A_ll Dependabot", action: { [weak self] in self?.toggleAllDependabot() }),
            nil,
            MenuItem(title: "_All repositories", action: { [weak self] in self?.setScope(nil) }),
        ]
        for repo in store.repos {
            viewItems.append(MenuItem(title: repo.name, action: { [weak self] in self?.setScope(repo) }))
        }
        return MenuBar(menus: [
            MenuBarItem(title: "_File", children: [
                MenuItem(title: "Choose _Repositories…", action: { [weak self] in self?.chooseRepos() }),
                MenuItem(title: "_Refresh", action: { [weak self] in self?.refreshNow() }),
                nil,
                MenuItem(title: "_Quit", action: { [weak self] in self?.quit() }),
            ]),
            MenuBarItem(title: "_View", children: viewItems),
            MenuBarItem(title: "_Help", children: [
                MenuItem(title: "_Keys", action: { Self.showKeys() }),
            ]),
        ])
    }

    private static func showKeys() {
        MessageBox.query("Keys", message: """
            j/k or arrows  move
            Enter          open on GitHub, or fold a section
            Space, c       fold or unfold the section
            g / G          first / last row
            Tab            switch between repositories and dashboard
            r              refresh
            d / b / B      hide drafts / failing Dependabot / all Dependabot
            p              choose repositories
            q              quit
            """, buttons: ["OK"]) { _ in }
    }

    // MARK: Refreshing

    func start() {
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshNowAndWait()
                try? await Task.sleep(for: Config.refreshInterval)
            }
        }
    }

    private func refreshNow() {
        Task { @MainActor in await refreshNowAndWait() }
    }

    private func refreshNowAndWait() async {
        guard !store.repos.isEmpty else {
            dashboard.placeholder = "No repositories chosen: press p to choose some."
            dashboard.rows = []
            return
        }
        // The spinner takes the place of the "Updated" time at the right end.
        status.updatePanel(id: "updated", content: "")
        status.showSpinner(id: "loading", message: "Refreshing…", placement: .trailing)
        // Not reported to herdr as "working": the working → idle change after
        // every refresh counts as a finished turn there and rings its chime.
        await store.refresh()
        status.hideIndicator(id: "loading")
        reload()
    }

    /// Rebuilds everything shown from the store.
    private func reload() {
        let filter = config.filter
        if store.lastUpdated != nil {
            dashboard.rows = DashboardRows.build(store: store, scope: scope, filter: filter, collapsed: config.collapsedSections)
        } else if store.repos.isEmpty {
            dashboard.placeholder = "No repositories chosen: press p to choose some."
        }
        var entries = [Sidebar.Entry(repo: nil, count: store.itemCount(in: nil, filter: filter))]
        entries += store.repos.map { Sidebar.Entry(repo: $0, count: store.itemCount(in: $0, filter: filter)) }
        sidebar.update(entries: entries, scope: scope)
        dashboardFrame?.title = title
        if let updated = store.lastUpdated {
            status.updatePanel(id: "updated", content: "Updated \(updated.formatted(date: .omitted, time: .shortened))")
        }
        if let message = store.errorMessage {
            status.pushStatus(message, priority: .high)
        } else {
            status.clearStatus()
        }
        if let menuBar {
            menuBar.menus = makeMenuBar().menus
            menuBar.setNeedsDisplay()
        }
        window.setNeedsDisplay()
        if !store.isLoading {
            let waiting = store.waitingOnMeCount(in: nil, filter: filter)
            herdr?.report(waiting > 0 ? .blocked(count: waiting) : .idle)
        }
    }

    private func quit() {
        herdr?.release()
        Application.shutdown()
    }

    // MARK: Actions

    private func handleHotKey(_ key: Key) -> Bool {
        switch key {
        case .letter("r"): refreshNow()
        case .letter("d"): toggleDrafts()
        case .letter("b"): toggleDependabot()
        case .letter("B"): toggleAllDependabot()
        case .letter("p"): chooseRepos()
        case .letter("q"): quit()
        case .letter("?"): Self.showKeys()
        case .controlI, .backtab: switchFocus()
        default: return false
        }
        return true
    }

    private func toggleDrafts() {
        config.filter.hideDrafts.toggle()
        reload()
    }

    private func toggleDependabot() {
        config.filter.hideFailingDependabot.toggle()
        reload()
    }

    private func toggleAllDependabot() {
        config.filter.hideDependabot.toggle()
        reload()
    }

    private func toggleSection(_ id: String) {
        var collapsed = config.collapsedSections
        if collapsed.contains(id) {
            collapsed.remove(id)
        } else {
            collapsed.insert(id)
        }
        config.collapsedSections = collapsed
        reload()
    }

    private func setScope(_ repo: Repo?) {
        guard repo?.fullName != config.scope else { return }
        config.scope = repo?.fullName
        reload()
    }

    /// Kept while the dialog is up; its callbacks only hold it weakly.
    private var picker: RepoPickerDialog?

    private func chooseRepos() {
        let picker = RepoPickerDialog(store: store) { [weak self] in
            self?.picker = nil
            self?.refreshNow()
        }
        self.picker = picker
        picker.present()
    }
}

/// Opens a URL in the user's browser.
private func open(_ url: URL) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [url.absoluteString]
    try? process.run()
}

/// The container for sidebar and dashboard; single-letter hotkeys that the
/// focused view did not use are offered to the screen.
final class DashboardWindow: View {
    var onHotKey: ((Key) -> Bool)?

    override init() {
        super.init()
        canFocus = true
    }

    override func processKey(event: KeyEvent) -> Bool {
        if super.processKey(event: event) {
            return true
        }
        return onHotKey?(event.key) ?? false
    }
}
