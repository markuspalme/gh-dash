import Foundation

/// GitHub's OAuth device flow (RFC 8628): the app shows a short code, the user
/// enters it on github.com, and the app polls until GitHub hands over a token.
/// It needs no client secret, so nothing confidential ships in the app.
struct GitHubDeviceFlow: Sendable {
    struct DeviceCode: Decodable, Sendable {
        let deviceCode: String
        let userCode: String
        let verificationUri: URL
        let expiresIn: Int
        let interval: Int
    }

    enum Failure: LocalizedError {
        case missingClientID
        case denied
        case expired
        case github(String)

        var errorDescription: String? {
            switch self {
            case .missingClientID:
                "No GitHub OAuth client ID is configured. Set one in OAuthConfig.swift."
            case .denied:
                "Sign-in was cancelled on GitHub."
            case .expired:
                "The code expired before it was entered. Try again."
            case .github(let message):
                "GitHub sign-in failed: \(message)"
            }
        }
    }

    let clientID: String
    let scope: String

    /// Step 1: ask GitHub for a code the user can enter.
    func requestCode() async throws -> DeviceCode {
        guard !clientID.isEmpty else { throw Failure.missingClientID }
        let response: CodeResponse = try await post(
            "https://github.com/login/device/code",
            ["client_id": clientID, "scope": scope]
        )
        guard let code = response.code else {
            throw Failure.github(response.errorDescription ?? response.error ?? "unexpected response")
        }
        return code
    }

    /// Step 2: poll until the user has entered the code and approved access.
    func waitForToken(_ code: DeviceCode) async throws -> String {
        var interval = code.interval
        let deadline = Date.now.addingTimeInterval(TimeInterval(code.expiresIn))
        while Date.now < deadline {
            try await Task.sleep(for: .seconds(interval))
            let response: TokenResponse = try await post(
                "https://github.com/login/oauth/access_token",
                [
                    "client_id": clientID,
                    "device_code": code.deviceCode,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                ]
            )
            if let token = response.accessToken {
                return token
            }
            switch response.error {
            case "authorization_pending":
                continue
            case "slow_down":
                interval = response.interval ?? interval + 5
            case "expired_token":
                throw Failure.expired
            case "access_denied":
                throw Failure.denied
            default:
                throw Failure.github(response.errorDescription ?? response.error ?? "unexpected response")
            }
        }
        throw Failure.expired
    }

    private func post<T: Decodable>(_ url: String, _ form: [String: String]) async throws -> T {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }
}

private struct CodeResponse: Decodable {
    let code: GitHubDeviceFlow.DeviceCode?
    let error: String?
    let errorDescription: String?

    private enum CodingKeys: String, CodingKey {
        case error, errorDescription
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        errorDescription = try container.decodeIfPresent(String.self, forKey: .errorDescription)
        code = error == nil ? try GitHubDeviceFlow.DeviceCode(from: decoder) : nil
    }
}

private struct TokenResponse: Decodable {
    let accessToken: String?
    let error: String?
    let errorDescription: String?
    let interval: Int?
}
