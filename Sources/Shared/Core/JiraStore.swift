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
    /// Demo mode shows `JiraDemoData` and never talks to Atlassian or touches the saved settings.
    private let isDemo: Bool
    private static let siteKey = "jiraSite"
    private static let projectsKey = "jiraProjects"
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
            projects: defaults.stringArray(forKey: Self.projectsKey) ?? []
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
        return try await JiraClient(site: site, mcp: mcp).fetchMyself()
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

    func assigned(in project: String?) -> [JiraIssue] {
        guard let project else { return assigned }
        return assigned.filter { $0.projectKey == project }
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
        let client = JiraClient(site: site, mcp: mcp)
        let projects = config.projects
        async let activity = client.fetchActivity(projects: projects, since: Date.now.addingTimeInterval(-Self.activityWindow))
        async let assigned = client.fetchAssignedIssues(projects: projects)
        var errors: [String] = []
        var signedOut = false
        do {
            self.activity = try await activity
        } catch {
            errors.append("Activity: \(error.localizedDescription)")
            signedOut = (error as? AtlassianMCP.Failure)?.isUnauthorized ?? false
        }
        do {
            self.assigned = try await assigned
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
}
