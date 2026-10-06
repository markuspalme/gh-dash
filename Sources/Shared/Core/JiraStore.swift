import Foundation
import Observation

/// Jira configuration, credentials and the data behind the Jira page.
@MainActor
@Observable
final class JiraStore {
    private(set) var config: JiraConfig
    private(set) var hasToken: Bool
    private(set) var activity: [JiraEvent] = []
    private(set) var assigned: [JiraIssue] = []
    private(set) var lastUpdated: Date?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    @ObservationIgnored private var refreshQueued = false
    /// Demo mode shows `JiraDemoData` and never talks to Jira or touches the saved settings.
    private let isDemo: Bool
    private static let siteKey = "jiraSite"
    private static let emailKey = "jiraEmail"
    private static let projectsKey = "jiraProjects"
    private static let tokenAccount = "jira-api-token"
    /// How far back the activity feed looks.
    static let activityWindow: TimeInterval = 7 * 86400

    init(demo: Bool = false) {
        isDemo = demo
        guard !demo else {
            config = JiraDemoData.config
            hasToken = true
            return
        }
        let defaults = UserDefaults.standard
        let environment = ProcessInfo.processInfo.environment
        config = JiraConfig(
            site: (environment["JIRA_SITE"] ?? defaults.string(forKey: Self.siteKey)).flatMap(URL.init(string:)),
            email: environment["JIRA_EMAIL"] ?? defaults.string(forKey: Self.emailKey) ?? "",
            projects: defaults.stringArray(forKey: Self.projectsKey) ?? []
        )
        hasToken = environment["JIRA_TOKEN"] != nil || Keychain.read(Self.tokenAccount) != nil
    }

    var isConfigured: Bool { config.isComplete && hasToken }

    /// Saves the settings; an empty token keeps the stored one.
    func save(config: JiraConfig, token: String) {
        guard !isDemo else { return }
        let defaults = UserDefaults.standard
        defaults.set(config.site?.absoluteString, forKey: Self.siteKey)
        defaults.set(config.email, forKey: Self.emailKey)
        defaults.set(config.projects, forKey: Self.projectsKey)
        if !token.isEmpty {
            Keychain.save(token, for: Self.tokenAccount)
            hasToken = true
        }
        self.config = config
        activity = []
        assigned = []
        lastUpdated = nil
        errorMessage = nil
    }

    func signOut() {
        Keychain.delete(Self.tokenAccount)
        hasToken = false
        activity = []
        assigned = []
        lastUpdated = nil
    }

    /// Checks `token` (or the stored one) against `config` and returns the account's name.
    func verify(config: JiraConfig, token: String) async throws -> String {
        guard let client = client(for: config, token: token) else { throw JiraError.notConfigured }
        return try await client.fetchMyself()
    }

    private func client(for config: JiraConfig, token: String) -> JiraClient? {
        let token = token.isEmpty ? (ProcessInfo.processInfo.environment["JIRA_TOKEN"] ?? Keychain.read(Self.tokenAccount) ?? "") : token
        guard let site = config.site, !config.email.isEmpty, !token.isEmpty else { return nil }
        return JiraClient(site: site, email: config.email, token: token)
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
        guard isConfigured, let client = client(for: config, token: "") else {
            errorMessage = nil
            return
        }
        let projects = config.projects
        async let activity = client.fetchActivity(projects: projects, since: Date.now.addingTimeInterval(-Self.activityWindow))
        async let assigned = client.fetchAssignedIssues(projects: projects)
        var errors: [String] = []
        do {
            self.activity = try await activity
        } catch {
            errors.append("Activity: \(error.localizedDescription)")
        }
        do {
            self.assigned = try await assigned
        } catch {
            errors.append("Tickets: \(error.localizedDescription)")
        }
        errorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")
        if errors.count < 2 {
            lastUpdated = .now
        }
    }
}
