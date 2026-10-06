import Foundation

/// Made-up Jira data for `--demo`, matching the acme repositories of `DemoData`.
enum JiraDemoData {
    static let config = JiraConfig(site: URL(string: "https://acme.atlassian.net"), email: "alex@acme.example", projects: ["WEB", "API"])

    static var assigned: [JiraIssue] {
        [
            issue("WEB-412", "Checkout page shows stale cart after coupon removal", status: "In Progress", category: .indeterminate, type: "Bug", priority: "High", hoursAgo: 3),
            issue("API-287", "Rate limit public endpoints per API key", status: "In Review", category: .indeterminate, type: "Story", priority: "Medium", hoursAgo: 5),
            issue("WEB-398", "Dark mode for the reporting charts", status: "To Do", category: .new, type: "Story", priority: "Medium", hoursAgo: 30),
            issue("API-301", "Audit log export as CSV", status: "To Do", category: .new, type: "Task", priority: "Low", hoursAgo: 52),
        ]
    }

    static var activity: [JiraEvent] {
        let review = issue("API-287", "Rate limit public endpoints per API key", status: "In Review", category: .indeterminate, type: "Story", priority: "Medium", hoursAgo: 5)
        let checkout = issue("WEB-412", "Checkout page shows stale cart after coupon removal", status: "In Progress", category: .indeterminate, type: "Bug", priority: "High", hoursAgo: 3)
        let onboarding = issue("WEB-420", "Onboarding carousel redesign", status: "In Progress", category: .indeterminate, type: "Story", priority: "Medium", hoursAgo: 1)
        let flaky = issue("API-295", "Flaky date parsing in report export", status: "Done", category: .done, type: "Bug", priority: "High", hoursAgo: 20)
        return [
            JiraEvent(id: "1", date: .now.addingTimeInterval(-40 * 60), actor: "Dana Lee", kind: .commented(excerpt: "Reproduced on staging with the 10% coupon. Looks like the cart total is cached per session."), issue: checkout),
            JiraEvent(id: "2", date: .now.addingTimeInterval(-70 * 60), actor: "Jonas Weber", kind: .created, issue: onboarding),
            JiraEvent(id: "3", date: .now.addingTimeInterval(-5 * 3600), actor: "Alex Example", kind: .statusChanged(from: "In Progress", to: "In Review"), issue: review),
            JiraEvent(id: "4", date: .now.addingTimeInterval(-6 * 3600), actor: "Priya Nair", kind: .assigned(to: "Alex Example"), issue: checkout),
            JiraEvent(id: "5", date: .now.addingTimeInterval(-20 * 3600), actor: "Tomasz Kowalski", kind: .statusChanged(from: "In Review", to: "Done"), issue: flaky),
            JiraEvent(id: "6", date: .now.addingTimeInterval(-26 * 3600), actor: "Tomasz Kowalski", kind: .commented(excerpt: "Fixed by pinning the locale in the parser; added a regression test."), issue: flaky),
        ]
    }

    private static func issue(_ key: String, _ summary: String, status: String, category: JiraIssue.StatusCategory, type: String, priority: String, hoursAgo: Double) -> JiraIssue {
        JiraIssue(
            key: key, summary: summary, status: status, statusCategory: category, type: type, priority: priority,
            assignee: "Alex Example", created: .now.addingTimeInterval(-hoursAgo * 3600 - 86400 * 3),
            updated: .now.addingTimeInterval(-hoursAgo * 3600),
            url: config.site!.appending(path: "browse/\(key)")
        )
    }
}
