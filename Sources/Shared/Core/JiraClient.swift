import Foundation

enum JiraError: LocalizedError {
    case notConfigured
    case http(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Jira is not set up: add your site, email and API token."
        case .http(let status, let message):
            "Jira API error \(status): \(message)"
        }
    }

    var isUnauthorized: Bool {
        if case .http(let status, _) = self { return status == 401 || status == 403 }
        return false
    }
}

/// A thin client for the Jira Cloud REST API v3, authenticated with an
/// Atlassian API token (basic auth with the account's email).
struct JiraClient: Sendable {
    let site: URL
    let email: String
    let token: String

    /// The signed-in account's display name; fails if the credentials are wrong.
    func fetchMyself() async throws -> String {
        let me: Myself = try await send(request(path: "rest/api/3/myself"))
        return me.displayName
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

    private func search(jql: String, fields: [String], expand: String?, maxResults: Int) async throws -> SearchPage {
        var body: [String: Any] = ["jql": jql, "fields": fields, "maxResults": maxResults]
        if let expand { body["expand"] = expand }
        var request = request(path: "rest/api/3/search/jql")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }

    private func request(path: String) -> URLRequest {
        var request = URLRequest(url: site.appending(path: path))
        let credentials = Data("\(email):\(token)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            guard let date = Self.parseDate(string) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unrecognised date \(string)"))
            }
            return date
        }
        guard (200..<300).contains(status) else {
            let message = (try? decoder.decode(ErrorBody.self, from: data))?.message ?? "request failed"
            throw JiraError.http(status: status, message: message)
        }
        return try decoder.decode(T.self, from: data)
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

private struct Myself: Decodable {
    let displayName: String
}

private struct ErrorBody: Decodable {
    let errorMessages: [String]?
    let errorMessage: String?

    var message: String? {
        errorMessage ?? errorMessages.flatMap { $0.isEmpty ? nil : $0.joined(separator: " ") }
    }

    private enum CodingKeys: String, CodingKey {
        case errorMessages
        case errorMessage = "message"
    }
}

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
