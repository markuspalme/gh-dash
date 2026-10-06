import SwiftUI

/// The Jira page: recent activity in the configured projects, and the
/// user's open tickets, overall or per project.
enum TicketsLayout: String, CaseIterable {
    case list, board

    var title: String {
        switch self {
        case .list: "List"
        case .board: "Board"
        }
    }

    var symbol: String {
        switch self {
        case .list: "list.bullet"
        case .board: "rectangle.split.3x1"
        }
    }
}

struct JiraView: View {
    let store: JiraStore
    @Binding var page: Page
    @Environment(\.openURL) private var openURL
    /// "activity", "tickets" (all projects) or "tickets:KEY".
    @AppStorage("jiraSelection") private var selectionID = "activity"
    /// How "My tickets" is laid out.
    @AppStorage("jiraTicketsLayout") private var ticketsLayout = TicketsLayout.list
    @State private var scrollsHorizontally = false
    @State private var isEditingSettings = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .sheet(isPresented: $isEditingSettings) {
            Task { await store.refresh() }
        } content: {
            JiraSettingsView(store: store)
        }
        .task { await store.runAutoRefresh() }
    }

    private var selection: Binding<String?> {
        Binding(get: { selectionID }, set: { selectionID = $0 ?? "activity" })
    }

    private var scopedProject: String? {
        selectionID.hasPrefix("tickets:") ? String(selectionID.dropFirst("tickets:".count)) : nil
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: selection) {
            Label("Activity", systemImage: "newspaper")
                .badge(store.activity.count)
                .tag("activity")
            Section("My tickets") {
                Label("All projects", systemImage: "square.stack")
                    .badge(store.assigned.count)
                    .tag("tickets")
                ForEach(store.config.projects, id: \.self) { project in
                    Label(project, systemImage: "folder")
                        .badge(store.assigned(in: project).count)
                        .tag("tickets:\(project)")
                        .contextMenu {
                            if let site = store.config.site {
                                Button("Open on Jira") {
                                    openURL(site.appending(path: "jira/software/c/projects/\(project)/summary"))
                                }
                            }
                        }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 190, ideal: 240, max: 360)
        .safeAreaInset(edge: .bottom) {
            Button {
                isEditingSettings = true
            } label: {
                Label("Jira Settings…", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(12)
        }
    }

    // MARK: Detail

    private var showsBoard: Bool { selectionID != "activity" && ticketsLayout == .board }

    private var detail: some View {
        ScrollView(showsBoard ? [.horizontal, .vertical] : .vertical) {
            VStack(alignment: .leading, spacing: 0) {
                if store.lastUpdated != nil {
                    if selectionID == "activity" {
                        activityRows
                    } else if showsBoard {
                        board
                    } else {
                        ticketRows
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .frame(maxWidth: showsBoard ? nil : .infinity, alignment: .leading)
        }
        .overlay {
            if !store.isConfigured {
                ContentUnavailableView {
                    Label("Jira Not Set Up", systemImage: "gearshape")
                } description: {
                    Text("Add your Atlassian site, email, API token and the projects to follow.")
                } actions: {
                    Button("Jira Settings…") { isEditingSettings = true }
                }
                .background()
            } else if store.lastUpdated == nil, store.isLoading {
                ProgressView("Loading…")
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let message = store.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.orange.opacity(0.2))
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .principal) {
                PagePicker(page: $page)
            }
            ToolbarItem {
                Picker("Layout", selection: $ticketsLayout) {
                    ForEach(TicketsLayout.allCases, id: \.self) { layout in
                        Label(layout.title, systemImage: layout.symbol).tag(layout)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(selectionID == "activity")
                .help("Show your tickets as a list by sprint or as a board by status")
            }
            ToolbarItem {
                Button {
                    isEditingSettings = true
                } label: {
                    Label("Jira Settings", systemImage: "gearshape")
                }
                .help("Site, account and projects")
            }
            ToolbarItem {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r")
                .disabled(store.isLoading)
                .help("Refresh (⌘R)")
            }
        }
    }

    private var title: String {
        switch selectionID {
        case "activity": "Activity"
        case "tickets": "My Tickets"
        default: "My Tickets · \(scopedProject ?? "")"
        }
    }

    private var subtitle: String {
        if store.isLoading { return "Refreshing…" }
        guard let lastUpdated = store.lastUpdated else { return "" }
        return "Updated \(lastUpdated.formatted(date: .omitted, time: .shortened))"
    }

    @ViewBuilder
    private var activityRows: some View {
        if store.activity.isEmpty {
            Text("Nothing happened in the last \(Int(JiraStore.activityWindow / 86400)) days.")
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
        }
        ForEach(store.activity) { event in
            JiraEventRow(event: event)
            Divider()
        }
    }

    @ViewBuilder
    private var ticketRows: some View {
        let tickets = store.assigned(in: scopedProject)
        if tickets.isEmpty {
            Text("No open tickets assigned to you.")
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
        }
        ForEach(Self.groupedBySprint(tickets), id: \.title) { group in
            HStack(spacing: 6) {
                Text(group.title)
                    .font(.headline)
                Text(verbatim: "\(group.issues.count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let note = group.note {
                    Text("· \(note)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 8)
            Divider()
            ForEach(group.issues) { issue in
                JiraIssueRow(issue: issue)
                Divider()
            }
            Spacer().frame(height: 22)
        }
    }

    /// One column per status, in the board's order.
    private var board: some View {
        // Empty columns stay out of the way; the configured order is kept for the rest.
        let columns = store.boardColumns(for: store.assigned(in: scopedProject, includeDone: true)).filter { !$0.issues.isEmpty }
        return HStack(alignment: .top, spacing: 12) {
            ForEach(columns, id: \.status) { column in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text(column.status.uppercased())
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(verbatim: "\(column.issues.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .background(.quaternary, in: Capsule())
                    }
                    .padding(.horizontal, 4)
                    ForEach(column.issues) { issue in
                        JiraCard(issue: issue)
                    }
                }
                .frame(width: 260, alignment: .leading)
                .padding(8)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(.bottom, 16)
    }

    struct SprintGroup {
        let title: String
        let note: String?
        let issues: [JiraIssue]
    }

    /// Active sprints first, then future ones, then everything without a sprint.
    static func groupedBySprint(_ issues: [JiraIssue]) -> [SprintGroup] {
        let bySprint = Dictionary(grouping: issues) { $0.sprint }
        func rank(_ sprint: JiraIssue.Sprint?) -> Int {
            switch sprint?.state {
            case "active": 0
            case "future": 1
            case nil: 3
            default: 2
            }
        }
        return bySprint.keys
            .sorted { (rank($0), $0?.name ?? "") < (rank($1), $1?.name ?? "") }
            .map { sprint in
                SprintGroup(
                    title: sprint?.name ?? "No sprint",
                    note: sprint.map { $0.state.isEmpty ? nil : $0.state } ?? nil,
                    issues: bySprint[sprint] ?? []
                )
            }
    }
}

// MARK: - Rows

struct JiraEventRow: View {
    let event: JiraEvent

    var body: some View {
        LinkRow(url: event.issue.url) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    (Text(event.actor).fontWeight(.medium) + Text(" \(event.verb) ") + Text(event.issue.key).fontWeight(.medium)
                        + Text(event.suffix.map { " \($0)" } ?? ""))
                        .lineLimit(1)
                    Spacer(minLength: 12)
                    RelativeTime(date: event.date)
                }
                Text(event.issue.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if case .commented(let excerpt) = event.kind, !excerpt.isEmpty {
                    Text(excerpt)
                        .font(.callout)
                        .lineLimit(2)
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 1).fill(.quaternary).frame(width: 2)
                        }
                }
                if case .statusChanged(let from, let to) = event.kind, !from.isEmpty {
                    HStack(spacing: 6) {
                        Badge(from, symbol: "circle", tint: .secondary)
                        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                        Badge(to, symbol: "circle.fill", tint: .blue)
                    }
                }
            }
        }
    }
}

struct JiraIssueRow: View {
    let issue: JiraIssue

    var body: some View {
        LinkRow(url: issue.url) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(issue.summary)
                        .fontWeight(.medium)
                        .lineLimit(2)
                    Spacer(minLength: 12)
                    RelativeTime(date: issue.updated)
                }
                Text("\(issue.key) · \(issue.type)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                FlowLayout(spacing: 6) {
                    Badge(issue.status, symbol: statusSymbol, tint: statusTint)
                    if let priority = issue.priority {
                        Badge(priority, symbol: "flag", tint: .secondary)
                    }
                }
            }
        }
    }

    private var statusSymbol: String {
        switch issue.statusCategory {
        case .new: "circle"
        case .indeterminate: "circle.lefthalf.filled"
        case .done: "checkmark.circle.fill"
        case .unknown: "circle.dotted"
        }
    }

    private var statusTint: Color {
        switch issue.statusCategory {
        case .new: .secondary
        case .indeterminate: .blue
        case .done: .green
        case .unknown: .secondary
        }
    }
}

/// A ticket on the board.
struct JiraCard: View {
    let issue: JiraIssue

    var body: some View {
        LinkRow(url: issue.url) {
            VStack(alignment: .leading, spacing: 6) {
                Text(issue.summary)
                    .font(.callout)
                    .lineLimit(3)
                HStack(spacing: 6) {
                    Text(issue.key)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(issue.type)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    if let priority = issue.priority {
                        Image(systemName: "flag")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help(priority)
                    }
                    if let sprint = issue.sprint {
                        Text(sprint.name)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(10)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
