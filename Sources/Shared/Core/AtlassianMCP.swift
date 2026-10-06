import CryptoKit
import Foundation
import Network

/// Atlassian's remote MCP server (https://mcp.atlassian.com): OAuth sign-in
/// with a self-registered public client (PKCE, localhost callback) and
/// JSON-RPC tool calls over its HTTP transport. This is the same route the
/// Atlassian connector in Claude Code uses, and it works where API tokens
/// are blocked by an administrator.
actor AtlassianMCP {
    enum Failure: LocalizedError {
        case notSignedIn
        case server(String)
        case tool(String)
        case callbackTimeout
        case badCallback

        var errorDescription: String? {
            switch self {
            case .notSignedIn: "Not signed in to Atlassian."
            case .server(let message): "Atlassian: \(message)"
            case .tool(let message): "Atlassian tool error: \(message)"
            case .callbackTimeout: "Sign-in timed out waiting for the browser."
            case .badCallback: "The browser came back without a valid code."
            }
        }

        var isUnauthorized: Bool {
            if case .notSignedIn = self { return true }
            return false
        }
    }

    /// What the Keychain holds between launches.
    struct Credentials: Codable, Sendable {
        var clientID: String
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
    }

    static let serverURL = URL(string: "https://mcp.atlassian.com")!
    /// Fixed so the registered redirect URI stays valid across launches.
    static let callbackPort: UInt16 = 48124
    static var redirectURI: String { "http://localhost:\(callbackPort)/callback" }
    private static let keychainAccount = "atlassian-mcp"

    private var credentials: Credentials?
    private var sessionID: String?
    private var protocolVersion = "2025-06-18"

    init() {
        if let data = Keychain.read(Self.keychainAccount)?.data(using: .utf8),
           let stored = try? JSONDecoder().decode(Credentials.self, from: data) {
            credentials = stored
        }
    }

    var isSignedIn: Bool { credentials != nil }

    func signOut() {
        credentials = nil
        sessionID = nil
        Keychain.delete(Self.keychainAccount)
    }

    // MARK: Sign-in

    /// Runs the whole OAuth flow: register a client if needed, open the
    /// browser via `openURL`, wait for the callback, exchange the code.
    func signIn(openURL: @Sendable @escaping (URL) -> Void) async throws {
        let metadata: Metadata = try await json(URLRequest(url: Self.serverURL.appending(path: ".well-known/oauth-authorization-server")))
        let clientID = try await registeredClientID(metadata: metadata)

        let verifier = Self.randomString(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        let state = Self.randomString(24)
        var components = URLComponents(url: metadata.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        let server = try CallbackServer(port: Self.callbackPort)
        openURL(components.url!)
        let code = try await server.waitForCode(state: state)

        let token: TokenResponse = try await form(metadata.tokenEndpoint, [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
        ])
        store(Credentials(
            clientID: clientID, accessToken: token.accessToken, refreshToken: token.refreshToken,
            expiresAt: token.expiresIn.map { Date.now.addingTimeInterval(TimeInterval($0) - 60) }
        ))
        sessionID = nil
    }

    private func registeredClientID(metadata: Metadata) async throws -> String {
        if let clientID = credentials?.clientID ?? UserDefaults.standard.string(forKey: "atlassianMCPClientID") {
            return clientID
        }
        var request = URLRequest(url: metadata.registrationEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_name": "GHDash",
            "redirect_uris": [Self.redirectURI],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        ])
        let registration: Registration = try await json(request)
        UserDefaults.standard.set(registration.clientId, forKey: "atlassianMCPClientID")
        return registration.clientId
    }

    private func store(_ credentials: Credentials) {
        self.credentials = credentials
        if let data = try? JSONEncoder().encode(credentials), let text = String(data: data, encoding: .utf8) {
            Keychain.save(text, for: Self.keychainAccount)
        }
    }

    /// A valid access token, refreshed first if it has expired.
    private func accessToken() async throws -> String {
        guard let credentials else { throw Failure.notSignedIn }
        if let expiresAt = credentials.expiresAt, expiresAt < .now, let refreshToken = credentials.refreshToken {
            let metadata: Metadata = try await json(URLRequest(url: Self.serverURL.appending(path: ".well-known/oauth-authorization-server")))
            do {
                let token: TokenResponse = try await form(metadata.tokenEndpoint, [
                    "grant_type": "refresh_token",
                    "refresh_token": refreshToken,
                    "client_id": credentials.clientID,
                ])
                store(Credentials(
                    clientID: credentials.clientID, accessToken: token.accessToken,
                    refreshToken: token.refreshToken ?? refreshToken,
                    expiresAt: token.expiresIn.map { Date.now.addingTimeInterval(TimeInterval($0) - 60) }
                ))
            } catch {
                signOut()
                throw Failure.notSignedIn
            }
        }
        return self.credentials?.accessToken ?? credentials.accessToken
    }

    // MARK: Tools

    /// Calls an MCP tool with JSON-encoded `arguments` and returns its result
    /// as JSON: `structuredContent` if present, else the text content (which
    /// the Atlassian tools fill with the Jira REST response).
    func call(_ tool: String, arguments: Data) async throws -> Data {
        let argumentsObject = try JSONSerialization.jsonObject(with: arguments)
        let result = try await rpc("tools/call", params: ["name": tool, "arguments": argumentsObject])
        guard let dictionary = result as? [String: Any] else { throw Failure.tool("unexpected result for \(tool)") }
        let content = dictionary["content"] as? [[String: Any]] ?? []
        let text = content.compactMap { $0["text"] as? String }.joined()
        if dictionary["isError"] as? Bool == true {
            throw Failure.tool(text.isEmpty ? "\(tool) failed" : text)
        }
        if let structured = dictionary["structuredContent"] {
            return try JSONSerialization.data(withJSONObject: structured)
        }
        return Data(text.utf8)
    }

    /// The server's tool catalogue as JSON, for finding out what the tools accept.
    func listTools() async throws -> Data {
        try JSONSerialization.data(withJSONObject: try await rpc("tools/list", params: [:]), options: [.prettyPrinted, .sortedKeys])
    }

    private func rpc(_ method: String, params: [String: Any]) async throws -> Any {
        if sessionID == nil {
            try await initializeSession()
        }
        return try await send(method: method, params: params, id: Int(Date.now.timeIntervalSince1970 * 1000))
    }

    private func initializeSession() async throws {
        let result = try await send(method: "initialize", params: [
            "protocolVersion": protocolVersion,
            "capabilities": [:],
            "clientInfo": ["name": "GHDash", "version": "0.1.0"],
        ], id: 1)
        if let version = (result as? [String: Any])?["protocolVersion"] as? String {
            protocolVersion = version
        }
        _ = try? await send(method: "notifications/initialized", params: nil, id: nil)
    }

    /// One JSON-RPC exchange over the Streamable HTTP transport; the server
    /// answers as plain JSON or as an SSE stream.
    private func send(method: String, params: [String: Any]?, id: Int?) async throws -> Any {
        var message: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { message["params"] = params }
        if let id { message["id"] = id }
        var request = URLRequest(url: Self.serverURL.appending(path: "v1/mcp"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID {
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: message)

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        if let newSession = http?.value(forHTTPHeaderField: "Mcp-Session-Id") {
            sessionID = newSession
        }
        let status = http?.statusCode ?? 0
        if status == 401 {
            sessionID = nil
            throw Failure.notSignedIn
        }
        guard (200..<300).contains(status) else {
            throw Failure.server("HTTP \(status) from \(method): \(String(decoding: data.prefix(300), as: UTF8.self))")
        }
        guard id != nil else { return [:] }

        let body: Any
        if http?.value(forHTTPHeaderField: "Content-Type")?.contains("text/event-stream") == true {
            body = try Self.lastJSONEvent(in: data, matching: id!)
        } else {
            body = try JSONSerialization.jsonObject(with: data)
        }
        guard let envelope = body as? [String: Any] else { throw Failure.server("unexpected reply to \(method)") }
        if let error = envelope["error"] as? [String: Any] {
            throw Failure.server(error["message"] as? String ?? "error \(error["code"] ?? "")")
        }
        return envelope["result"] ?? [:]
    }

    private static func lastJSONEvent(in data: Data, matching id: Int) throws -> Any {
        var found: Any?
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where line.hasPrefix("data:") {
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let parsed = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
            if (parsed["id"] as? Int) == id || parsed["id"] == nil && found == nil {
                found = parsed
            }
        }
        guard let found else { throw Failure.server("no reply in event stream") }
        return found
    }

    // MARK: HTTP helpers

    private func json<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw Failure.server("HTTP \(status): \(String(decoding: data.prefix(300), as: UTF8.self))")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }

    private func form<T: Decodable>(_ url: URL, _ fields: [String: String]) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        return try await json(request)
    }

    private static func randomString(_ length: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<length).map { _ in alphabet.randomElement()! })
    }
}

private struct Metadata: Decodable {
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    let registrationEndpoint: URL
}

private struct Registration: Decodable {
    let clientId: String
}

private struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int?
}

private extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// Listens on localhost for the one browser redirect that ends the sign-in.
private final class CallbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ghdash.oauth-callback")

    init(port: UInt16) throws {
        listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
    }

    func waitForCode(state expectedState: String) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await self.receiveCode(expectedState: expectedState) }
            group.addTask {
                try await Task.sleep(for: .seconds(300))
                throw AtlassianMCP.Failure.callbackTimeout
            }
            let code = try await group.next()!
            group.cancelAll()
            listener.cancel()
            return code
        }
    }

    private func receiveCode(expectedState: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let resumed = Locked(false)
            listener.newConnectionHandler = { connection in
                connection.start(queue: self.queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                    let request = String(decoding: data ?? Data(), as: UTF8.self)
                    let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                    let items = URLComponents(string: "http://localhost\(target)")?.queryItems ?? []
                    let code = items.first { $0.name == "code" }?.value
                    let state = items.first { $0.name == "state" }?.value
                    let ok = code != nil && state == expectedState
                    let page = ok
                        ? "<html><body style='font-family:-apple-system;padding:40px'><h2>Signed in to Atlassian</h2><p>You can close this window and return to GHDash.</p></body></html>"
                        : "<html><body style='font-family:-apple-system;padding:40px'><h2>Sign-in failed</h2><p>Go back to GHDash and try again.</p></body></html>"
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n\(page)"
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                    guard resumed.exchange(true) == false else { return }
                    if ok, let code {
                        continuation.resume(returning: code)
                    } else {
                        continuation.resume(throwing: AtlassianMCP.Failure.badCallback)
                    }
                }
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state, resumed.exchange(true) == false {
                    continuation.resume(throwing: AtlassianMCP.Failure.server("could not listen for the sign-in callback: \(error)"))
                }
            }
            listener.start(queue: queue)
        }
    }
}

private final class Locked<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ value: T) { self.value = value }
    func exchange(_ new: T) -> T {
        lock.lock(); defer { lock.unlock() }
        let old = value; value = new; return old
    }
}
