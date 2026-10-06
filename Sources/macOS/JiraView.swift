import SwiftUI

/// The Jira page: recent activity in the configured projects, and the
/// user's open tickets, overall or per project.
struct JiraView: View {
    let store: JiraStore
    @Binding var page: Page
    @Environment(\.openURL) private var openURL
    /// "activity", "tickets" (all projects) or "tickets:KEY".
    @AppStorage("jiraSelection") private var selectionID = "activity"
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

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if store.lastUpdated != nil {
                    if selectionID == "activity" {
                        activityRows
                    } else {
                        ticketRows
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
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
        ForEach(tickets) { issue in
            JiraIssueRow(issue: issue)
            Divider()
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
