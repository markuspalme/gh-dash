import Foundation
import Observation
import Security

/// The signed-in GitHub account: runs the OAuth device flow and keeps the
/// resulting token in the Keychain.
@MainActor
@Observable
final class AuthSession {
    enum Phase: Equatable {
        case signedOut
        case requestingCode
        /// Waiting for the user to enter `code` at `url`.
        case awaitingUser(code: String, url: URL)
        case failed(String)
    }

    struct NotSignedIn: LocalizedError {
        var errorDescription: String? { "Not signed in to GitHub." }
    }

    private(set) var token: String?
    private(set) var phase: Phase = .signedOut
    @ObservationIgnored private var signInTask: Task<Void, Never>?

    var isSignedIn: Bool { token != nil }

    init() {
        // GH_TOKEN overrides sign-in, as it does on the Mac; handy in the simulator.
        if let token = ProcessInfo.processInfo.environment["GH_TOKEN"], !token.isEmpty {
            self.token = token
        } else {
            token = Keychain.read()
        }
    }

    func currentToken() throws -> String {
        guard let token else { throw NotSignedIn() }
        return token
    }

    func signIn() {
        signInTask?.cancel()
        phase = .requestingCode
        signInTask = Task {
            let flow = GitHubDeviceFlow(clientID: OAuthConfig.clientID, scope: OAuthConfig.scope)
            do {
                let code = try await flow.requestCode()
                phase = .awaitingUser(code: code.userCode, url: code.verificationUri)
                let token = try await flow.waitForToken(code)
                Keychain.save(token)
                self.token = token
                phase = .signedOut
            } catch is CancellationError {
                phase = .signedOut
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        phase = .signedOut
    }

    func signOut() {
        signInTask?.cancel()
        Keychain.delete()
        token = nil
        phase = .signedOut
    }
}

/// The one Keychain item the app owns: the GitHub token.
private enum Keychain {
    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? "GHDash",
            kSecAttrAccount as String: "github-token",
        ]
    }

    static func read() -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String) {
        delete()
        var attributes = query
        attributes[kSecValueData as String] = Data(token.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
