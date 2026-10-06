import Foundation
import Observation

/// Jira configuration, the Atlassian sign-in and the data behind the Jira page.
@MainActor
@Observable
final class JiraStore {
    private(set) var config: JiraConfig
    private(set) var isSignedIn: Bool
    private(set) var isSigningIn = false
    private(set) var activity: [JiraEvent] = []
    private(set) var assigned: [JiraIssue] = []
    private(set) var lastUpdated: Date?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    @ObservationIgnored private var refreshQueued = false
    @ObservationIgnored private let mcp = AtlassianMCP()
    /// Changelogs already fetched, keyed by issue; refetched when the issue's `updated` moves.
    @ObservationIgnored private var changeCache: [String: (updated: Date, changes: [JiraClient.Change])] = [:]
    /// Demo mode shows `JiraDemoData` and never talks to Atlassian or touches the saved settings.
    private let isDemo: Bool
    private static let siteKey = "jiraSite"
    private static let projectsKey = "jiraProjects"
    private static let sprintFieldKey = "jiraSprintField"
    private static let boardColumnsKey = "jiraBoardColumns"
    /// How far back the activity feed looks.
    static let activityWindow: TimeInterval = 7 * 86400

    init(demo: Bool = false) {
        isDemo = demo
        guard !demo else {
            config = JiraDemoData.config
            isSignedIn = true
            return
        }
        let defaults = UserDefaults.standard
        config = JiraConfig(
            site: (ProcessInfo.processInfo.environment["JIRA_SITE"] ?? defaults.string(forKey: Self.siteKey)).flatMap(URL.init(string:)),
            projects: defaults.stringArray(forKey: Self.projectsKey) ?? [],
            boardColumns: defaults.stringArray(forKey: Self.boardColumnsKey) ?? []
        )
        isSignedIn = false
        Task { isSignedIn = await mcp.isSignedIn }
    }

    var isConfigured: Bool { config.isComplete && isSignedIn }

    func save(config: JiraConfig) {
        guard !isDemo else { return }
        let defaults = UserDefaults.standard
        defaults.set(config.site?.absoluteString, forKey: Self.siteKey)
        defaults.set(config.projects, forKey: Self.projectsKey)
        defaults.set(config.boardColumns, forKey: Self.boardColumnsKey)
        self.config = config
        activity = []
        assigned = []
        lastUpdated = nil
        errorMessage = nil
    }

    /// Signs in to Atlassian in the browser and returns the account's name.
    func signIn(openURL: @Sendable @escaping (URL) -> Void) async throws -> String {
        isSigningIn = true
        defer { isSigningIn = false }
        try await mcp.signIn(openURL: openURL)
        isSignedIn = true
        await logToolCatalogue()
        guard let site = config.site else { return "" }
        return try await JiraClient(site: site, mcp: mcp, sprintField: nil).fetchMyself()
    }

    func signOut() {
        Task { await mcp.signOut() }
        isSignedIn = false
        activity = []
        assigned = []
        lastUpdated = nil
    }

    /// Writes the server's tool list to ~/Library/Logs/GHDash, which is how
    /// the tool parameters this client relies on were found out.
    private func logToolCatalogue() async {
        guard let data = try? await mcp.listTools() else { return }
        guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return }
        let directory = library.appending(path: "Logs/GHDash")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appending(path: "atlassian-mcp-tools.json"))
    }

    /// Open tickets for the list; `includeDone` adds recently finished ones for the board.
    func assigned(in project: String?, includeDone: Bool = false) -> [JiraIssue] {
        assigned.filter { (project == nil || $0.projectKey == project) && (includeDone || $0.statusCategory != .done) }
    }

    /// The board's columns. With a configured list, each column collects the
    /// statuses named in its entry ("In Progress / Rework") and anything
    /// unlisted lands in a trailing "Other" column. Without one, every
    /// status is its own column, ordered by category.
    func boardColumns(for issues: [JiraIssue]) -> [(status: String, issues: [JiraIssue])] {
        let byStatus = Dictionary(grouping: issues, by: \.status)
        let configured = config.boardColumns.map { entry -> (title: String, statuses: [String]) in
            let parts = entry.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return (parts.first ?? entry, parts)
        }.filter { !$0.title.isEmpty }

        guard !configured.isEmpty else {
            func rank(_ status: String) -> Int {
                switch byStatus[status]?.first?.statusCategory {
                case .new: 0
                case .indeterminate: 1
                case .done: 3
                default: 2
                }
            }
            return byStatus.keys.sorted { (rank($0), $0) < (rank($1), $1) }.map { (status: $0, issues: byStatus[$0] ?? []) }
        }

        var remaining = byStatus
        var columns: [(status: String, issues: [JiraIssue])] = []
        for column in configured {
            var collected: [JiraIssue] = []
            for status in column.statuses {
                if let key = remaining.keys.first(where: { $0.caseInsensitiveCompare(status) == .orderedSame }) {
                    collected += remaining.removeValue(forKey: key) ?? []
                }
            }
            columns.append((status: column.title, issues: collected.sorted { $0.updated > $1.updated }))
        }
        let other = remaining.values.flatMap { $0 }.sorted { $0.updated > $1.updated }
        if !other.isEmpty {
            columns.append((status: "Other", issues: other))
        }
        return columns
    }

    // MARK: Refreshing

    func runAutoRefresh() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: Config.refreshInterval)
        }
    }

    func refresh() async {
        if isLoading {
            refreshQueued = true
            return
        }
        isLoading = true
        defer { isLoading = false }
        repeat {
            refreshQueued = false
            await load()
        } while refreshQueued
    }

    private func load() async {
        guard !isDemo else {
            activity = JiraDemoData.activity
            assigned = JiraDemoData.assigned
            lastUpdated = .now
            return
        }
        isSignedIn = await mcp.isSignedIn
        guard isConfigured, let site = config.site else {
            errorMessage = nil
            return
        }
        let client = JiraClient(site: site, mcp: mcp, sprintField: UserDefaults.standard.string(forKey: Self.sprintFieldKey))
        let projects = config.projects
        let since = Date.now.addingTimeInterval(-Self.activityWindow)
        async let recent = client.fetchRecentIssues(projects: projects, since: since)
        async let assigned = client.fetchAssignedIssues(projects: projects)
        var errors: [String] = []
        var signedOut = false
        do {
            self.activity = try await events(from: try await recent, since: since, client: client)
        } catch {
            errors.append("Activity: \(error.localizedDescription)")
            signedOut = (error as? AtlassianMCP.Failure)?.isUnauthorized ?? false
        }
        do {
            let (issues, sprintField) = try await assigned
            self.assigned = issues
            if let sprintField {
                UserDefaults.standard.set(sprintField, forKey: Self.sprintFieldKey)
            }
        } catch {
            errors.append("Tickets: \(error.localizedDescription)")
            signedOut = signedOut || (error as? AtlassianMCP.Failure)?.isUnauthorized ?? false
        }
        if signedOut {
            isSignedIn = false
        }
        errorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")
        if errors.count < 2 {
            lastUpdated = .now
        }
    }

    /// Turns recently updated issues into feed entries: creation, comments,
    /// and the status and assignee changes from each issue's changelog.
    private func events(from recent: [JiraClient.RecentIssue], since: Date, client: JiraClient) async throws -> [JiraEvent] {
        // Changelogs need one call per issue; only refetch issues that changed.
        let stale = recent.filter { changeCache[$0.issue.key]?.updated != $0.issue.updated }
        try await withThrowingTaskGroup(of: (String, Date, [JiraClient.Change]).self) { group in
            for item in stale {
                group.addTask { (item.issue.key, item.issue.updated, try await client.fetchChanges(of: item.issue.key)) }
            }
            for try await (key, updated, changes) in group {
                changeCache[key] = (updated, changes)
            }
        }
        changeCache = changeCache.filter { entry in recent.contains { $0.issue.key == entry.key } }

        var events: [JiraEvent] = []
        for item in recent {
            let issue = item.issue
            if issue.created >= since {
                events.append(JiraEvent(id: "\(issue.key):created", date: issue.created, actor: item.creator, kind: .created, issue: issue))
            }
            for comment in item.comments where comment.date >= since {
                events.append(JiraEvent(id: "\(issue.key):comment:\(comment.id)", date: comment.date, actor: comment.author, kind: .commented(excerpt: comment.text), issue: issue))
            }
            for change in changeCache[issue.key]?.changes ?? [] where change.date >= since {
                let kind: JiraEvent.Kind = change.field == "status"
                    ? .statusChanged(from: change.from ?? "", to: change.to ?? "")
                    : .assigned(to: change.to ?? "nobody")
                events.append(JiraEvent(id: "\(issue.key):\(change.id)", date: change.date, actor: change.author, kind: kind, issue: issue))
            }
        }
        return events.sorted { $0.date > $1.date }
    }
}
