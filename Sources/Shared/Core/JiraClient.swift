import Foundation

enum JiraError: LocalizedError {
    case notConfigured
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Jira is not set up: add your site and sign in to Atlassian."
        case .badResponse(let detail):
            "Unexpected reply from Jira: \(detail)"
        }
    }
}

/// Jira data through Atlassian's MCP server, whose tools wrap the Jira
/// Cloud REST API and return its JSON.
struct JiraClient: Sendable {
    let site: URL
    let mcp: AtlassianMCP
    /// The site's sprint custom field (e.g. customfield_10005) once known;
    /// until then issues are fetched with every field to find it.
    var sprintField: String?

    /// A change recorded in an issue's history.
    struct Change: Sendable {
        let id: String
        let date: Date
        let author: String
        let field: String
        let from: String?
        let to: String?
    }

    /// A recently updated issue with the comments made on it.
    struct RecentIssue: Sendable {
        struct Comment: Sendable {
            let id: String
            let date: Date
            let author: String
            let text: String
        }
        let issue: JiraIssue
        let creator: String
        let comments: [Comment]
    }

    /// The signed-in account's display name; fails if the sign-in is gone.
    func fetchMyself() async throws -> String {
        let info = try await object(mcp.call("atlassianUserInfo", arguments: Data("{}".utf8)))
        return (info["name"] ?? info["displayName"] ?? info["email"]) as? String ?? "unknown"
    }

    /// The caller's open issues in `projects`, most recently updated first,
    /// and the id of the sprint field if it was seen.
    func fetchAssignedIssues(projects: [String]) async throws -> (issues: [JiraIssue], sprintField: String?) {
        guard !projects.isEmpty else { return ([], sprintField) }
        let jql = "assignee = currentUser() AND project in (\(projects.joined(separator: ", "))) AND statusCategory != Done ORDER BY updated DESC"
        // The sprint is a custom field whose id differs per site; "*all" finds it the first time.
        let fields = sprintField.map { Self.issueFields + [$0] } ?? ["*all"]
        let page = try await search(jql: jql, fields: fields, maxResults: 100)
        let discovered = page.lazy.compactMap { sprintFieldID(in: $0["fields"] as? [String: Any] ?? [:]) }.first
        return (page.map { issue(from: $0) }, sprintField ?? discovered)
    }

    private static let issueFields = ["summary", "status", "issuetype", "priority", "assignee", "created", "updated"]

    /// Issues in `projects` updated since `since`, with their comments.
    func fetchRecentIssues(projects: [String], since: Date) async throws -> [RecentIssue] {
        guard !projects.isEmpty else { return [] }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = .current
        let jql = "project in (\(projects.joined(separator: ", "))) AND updated >= \"\(formatter.string(from: since))\" ORDER BY updated DESC"
        let page = try await search(jql: jql, fields: Self.issueFields + ["creator", "comment"], maxResults: 50)
        return page.map { node in
            let fields = node["fields"] as? [String: Any] ?? [:]
            let comments = ((fields["comment"] as? [String: Any])?["comments"] as? [[String: Any]] ?? []).compactMap { comment -> RecentIssue.Comment? in
                guard let id = anyString(comment["id"]), let date = date(comment["created"]) else { return nil }
                return RecentIssue.Comment(id: id, date: date, author: person(comment["author"]), text: text(comment["body"]))
            }
            return RecentIssue(issue: issue(from: node), creator: person(fields["creator"]), comments: comments)
        }
    }

    /// The status and assignee changes recorded on one issue.
    func fetchChanges(of key: String) async throws -> [Change] {
        let arguments = try JSONSerialization.data(withJSONObject: [
            "cloudId": site.absoluteString, "issueIdOrKey": key, "fields": ["summary"], "expand": "changelog",
        ])
        let node = try await object(mcp.call("getJiraIssue", arguments: arguments))
        let histories = (node["changelog"] as? [String: Any])?["histories"] as? [[String: Any]] ?? []
        return histories.flatMap { history -> [Change] in
            guard let id = anyString(history["id"]), let date = date(history["created"]) else { return [] }
            let author = person(history["author"])
            return (history["items"] as? [[String: Any]] ?? []).compactMap { item in
                guard let field = item["field"] as? String, ["status", "assignee"].contains(field) else { return nil }
                return Change(id: "\(id):\(field)", date: date, author: author, field: field, from: item["fromString"] as? String, to: item["toString"] as? String)
            }
        }
    }

    // MARK: Transport

    private func search(jql: String, fields: [String], maxResults: Int) async throws -> [[String: Any]] {
        let arguments = try JSONSerialization.data(withJSONObject: [
            "cloudId": site.absoluteString, "jql": jql, "fields": fields, "maxResults": max(50, min(100, maxResults)),
            "responseContentFormat": "markdown",
        ])
        let data = try await mcp.call("searchJiraIssuesUsingJql", arguments: arguments)
        Self.log(data, as: "last-jira-search.json")
        let page = try object(data)
        return page["issues"] as? [[String: Any]] ?? []
    }

    private func object(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JiraError.badResponse(String(decoding: data.prefix(200), as: UTF8.self))
        }
        return object
    }

    /// Keeps the last raw reply in ~/Library/Logs/GHDash for diagnosing field shapes.
    private static func log(_ data: Data, as name: String) {
        guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return }
        let directory = library.appending(path: "Logs/GHDash")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appending(path: name))
    }

    // MARK: Decoding

    private func issue(from node: [String: Any]) -> JiraIssue {
        let fields = node["fields"] as? [String: Any] ?? [:]
        let key = anyString(node["key"]) ?? "?"
        let status = fields["status"] as? [String: Any]
        let category = (status?["statusCategory"] as? [String: Any])?["key"] as? String ?? ""
        return JiraIssue(
            key: key,
            summary: fields["summary"] as? String ?? "",
            status: status?["name"] as? String ?? "",
            statusCategory: JiraIssue.StatusCategory(rawValue: category) ?? .unknown,
            type: (fields["issuetype"] as? [String: Any])?["name"] as? String ?? "Issue",
            priority: (fields["priority"] as? [String: Any])?["name"] as? String,
            assignee: fields["assignee"] == nil || fields["assignee"] is NSNull ? nil : person(fields["assignee"]),
            created: date(fields["created"]) ?? .distantPast,
            updated: date(fields["updated"]) ?? .distantPast,
            url: site.appending(path: "browse/\(key)"),
            sprint: sprint(in: fields)
        )
    }

    /// The sprint field is a custom field; recognise it by the shape of its value.
    private func sprintFieldID(in fields: [String: Any]) -> String? {
        if let sprintField, fields[sprintField] != nil { return sprintField }
        return fields.first { _, value in
            guard let sprints = value as? [[String: Any]], let first = sprints.first else { return false }
            return first["boardId"] != nil && first["state"] != nil && first["name"] != nil
        }?.key
    }

    private func sprint(in fields: [String: Any]) -> JiraIssue.Sprint? {
        guard let field = sprintFieldID(in: fields), let sprints = fields[field] as? [[String: Any]] else { return nil }
        // Prefer the sprint the issue is in now over ones it was carried over from.
        let ranked = sprints.sorted { rank($0["state"] as? String) < rank($1["state"] as? String) }
        guard let chosen = ranked.first, let name = chosen["name"] as? String else { return nil }
        return JiraIssue.Sprint(name: name, state: chosen["state"] as? String ?? "")
    }

    private func rank(_ state: String?) -> Int {
        switch state {
        case "active": 0
        case "future": 1
        default: 2
        }
    }

    private func person(_ value: Any?) -> String {
        guard let dictionary = value as? [String: Any] else { return "someone" }
        return (dictionary["displayName"] ?? dictionary["name"] ?? dictionary["emailAddress"] ?? dictionary["accountId"]) as? String ?? "someone"
    }

    private func anyString(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    /// Comment bodies arrive as markdown text (with the odd <custom> tag
    /// around smart links) or as Atlassian Document Format.
    private func text(_ value: Any?) -> String {
        if let string = value as? String {
            return string.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let node = value as? [String: Any] else { return "" }
        if let text = node["text"] as? String { return text }
        let parts = (node["content"] as? [[String: Any]] ?? []).map { text($0) }.filter { !$0.isEmpty }
        return parts.joined(separator: " ")
    }

    /// Jira writes dates like 2026-10-05T19:06:06.000+0200.
    private func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        return Self.dateFormatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    nonisolated(unsafe) private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return formatter
    }()
}
