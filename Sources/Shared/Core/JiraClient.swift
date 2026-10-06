import Foundation

enum JiraError: LocalizedError {
    case notConfigured
    case siteNotAccessible(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Jira is not set up: add your site and sign in to Atlassian."
        case .siteNotAccessible(let host):
            "Your Atlassian account has no access to \(host)."
        }
    }
}

/// Jira data through Atlassian's MCP server, whose tools wrap the Jira
/// Cloud REST API and return its JSON.
struct JiraClient: Sendable {
    let site: URL
    let mcp: AtlassianMCP

    /// The signed-in account's display name; fails if the sign-in is gone.
    func fetchMyself() async throws -> String {
        let info = try await mcp.call("atlassianUserInfo", arguments: Data("{}".utf8))
        let dictionary = (try? JSONSerialization.jsonObject(with: info)) as? [String: Any] ?? [:]
        return (dictionary["name"] ?? dictionary["displayName"] ?? dictionary["email"]) as? String ?? "unknown"
    }

    /// The caller's open issues in `projects`, most recently updated first.
    func fetchAssignedIssues(projects: [String]) async throws -> [JiraIssue] {
        guard !projects.isEmpty else { return [] }
        let jql = "assignee = currentUser() AND project in (\(projects.joined(separator: ", "))) AND statusCategory != Done ORDER BY updated DESC"
        let page: SearchPage = try await search(jql: jql, fields: Self.issueFields, expand: nil, maxResults: 100)
        return page.issues.map { issue(from: $0) }
    }

    /// What happened in `projects` since `since`: issues created, comments,
    /// status changes and assignments, newest first.
    func fetchActivity(projects: [String], since: Date) async throws -> [JiraEvent] {
        guard !projects.isEmpty else { return [] }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = .current
        let jql = "project in (\(projects.joined(separator: ", "))) AND updated >= \"\(formatter.string(from: since))\" ORDER BY updated DESC"
        let page: SearchPage = try await search(jql: jql, fields: Self.issueFields + ["creator", "comment"], expand: "changelog", maxResults: 50)

        var events: [JiraEvent] = []
        for node in page.issues {
            let issue = issue(from: node)
            if issue.created >= since {
                events.append(JiraEvent(id: "\(issue.key):created", date: issue.created, actor: node.fields.creator?.displayName ?? "someone", kind: .created, issue: issue))
            }
            for history in node.changelog?.histories ?? [] where history.created >= since {
                for item in history.items {
                    switch item.field {
                    case "status":
                        events.append(JiraEvent(
                            id: "\(issue.key):\(history.id):status", date: history.created,
                            actor: history.author?.displayName ?? "someone",
                            kind: .statusChanged(from: item.fromString ?? "", to: item.toString ?? ""), issue: issue
                        ))
                    case "assignee":
                        events.append(JiraEvent(
                            id: "\(issue.key):\(history.id):assignee", date: history.created,
                            actor: history.author?.displayName ?? "someone",
                            kind: .assigned(to: item.toString ?? "nobody"), issue: issue
                        ))
                    default:
                        continue
                    }
                }
            }
            for comment in node.fields.comment?.comments ?? [] where comment.created >= since {
                events.append(JiraEvent(
                    id: "\(issue.key):comment:\(comment.id)", date: comment.created,
                    actor: comment.author?.displayName ?? "someone",
                    kind: .commented(excerpt: comment.body?.plainText ?? ""), issue: issue
                ))
            }
        }
        return events.sorted { $0.date > $1.date }
    }

    // MARK: Transport

    private static let issueFields = ["summary", "status", "issuetype", "priority", "assignee", "created", "updated"]

    /// The cloud id of `site` among the sites the account can reach.
    private func cloudID() async throws -> String {
        let resourcesData = try await mcp.call("getAccessibleAtlassianResources", arguments: Data("{}".utf8))
        let resources = try JSONSerialization.jsonObject(with: resourcesData)
        let list = (resources as? [[String: Any]]) ?? ((resources as? [String: Any])?["resources"] as? [[String: Any]]) ?? []
        let host = site.host()?.lowercased() ?? ""
        guard let match = list.first(where: { ($0["url"] as? String)?.lowercased().contains(host) == true }),
              let id = match["id"] as? String else {
            throw JiraError.siteNotAccessible(host)
        }
        return id
    }

    private func search(jql: String, fields: [String], expand: String?, maxResults: Int) async throws -> SearchPage {
        let cloudID = try await cloudID()
        var arguments: [String: Any] = ["cloudId": cloudID, "jql": jql, "fields": fields, "maxResults": maxResults]
        if let expand { arguments["expand"] = expand }
        let data: Data
        do {
            data = try await mcp.call("searchJiraIssuesUsingJql", arguments: try JSONSerialization.data(withJSONObject: arguments))
        } catch AtlassianMCP.Failure.tool(let message) where expand != nil && message.localizedCaseInsensitiveContains("expand") {
            // The tool may not pass `expand` through; the changelog is then unavailable.
            arguments["expand"] = nil
            data = try await mcp.call("searchJiraIssuesUsingJql", arguments: try JSONSerialization.data(withJSONObject: arguments))
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            guard let date = Self.parseDate(string) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unrecognised date \(string)"))
            }
            return date
        }
        return try decoder.decode(SearchPage.self, from: data)
    }

    /// Jira writes dates like 2026-10-05T19:06:06.000+0200.
    nonisolated(unsafe) private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return formatter
    }()

    private static func parseDate(_ string: String) -> Date? {
        dateFormatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    private func issue(from node: IssueNode) -> JiraIssue {
        let category = node.fields.status.statusCategory?.key ?? ""
        return JiraIssue(
            key: node.key,
            summary: node.fields.summary,
            status: node.fields.status.name,
            statusCategory: JiraIssue.StatusCategory(rawValue: category) ?? .unknown,
            type: node.fields.issuetype?.name ?? "Issue",
            priority: node.fields.priority?.name,
            assignee: node.fields.assignee?.displayName,
            created: node.fields.created,
            updated: node.fields.updated,
            url: site.appending(path: "browse/\(node.key)")
        )
    }
}

// MARK: - Wire formats

private struct SearchPage: Decodable {
    let issues: [IssueNode]
}

private struct IssueNode: Decodable {
    struct Fields: Decodable {
        struct Status: Decodable {
            struct Category: Decodable {
                let key: String
            }
            let name: String
            let statusCategory: Category?
        }
        struct Named: Decodable {
            let name: String
        }
        struct Comments: Decodable {
            let comments: [Comment]
        }
        let summary: String
        let status: Status
        let issuetype: Named?
        let priority: Named?
        let assignee: Person?
        let creator: Person?
        let created: Date
        let updated: Date
        let comment: Comments?
    }
    struct Changelog: Decodable {
        let histories: [History]
    }
    struct History: Decodable {
        struct Item: Decodable {
            let field: String
            let fromString: String?
            let toString: String?
        }
        let id: String
        let created: Date
        let author: Person?
        let items: [Item]
    }
    let key: String
    let fields: Fields
    let changelog: Changelog?
}

private struct Person: Decodable {
    let displayName: String
}

private struct Comment: Decodable {
    let id: String
    let created: Date
    let author: Person?
    let body: ADF?
}

/// The part of Atlassian Document Format needed to pull plain text out of a comment.
private struct ADF: Decodable {
    let text: String?
    let content: [ADF]?

    var plainText: String {
        if let text { return text }
        return (content ?? []).map(\.plainText).joined(separator: " ").replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
    }
}
