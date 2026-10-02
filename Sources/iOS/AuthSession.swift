import Foundation
import Observation
import Security

/// The signed-in GitHub account: a personal access token the user pasted in,
/// checked against GitHub once and then kept in the Keychain.
@MainActor
@Observable
final class AuthSession {
    struct NotSignedIn: LocalizedError {
        var errorDescription: String? { "Not signed in to GitHub." }
    }

    private(set) var token: String?
    private(set) var isCheckingToken = false
    /// Why the last sign-in attempt failed.
    private(set) var errorMessage: String?

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

    /// Signs in with `candidate` if GitHub accepts it.
    func signIn(with candidate: String) async {
        let candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, !isCheckingToken else { return }
        isCheckingToken = true
        defer { isCheckingToken = false }
        do {
            _ = try await GitHubClient(token: candidate).fetchViewerLogin()
            Keychain.save(candidate)
            errorMessage = nil
            token = candidate
        } catch let error as GitHubError where error.isUnauthorized {
            errorMessage = "GitHub rejected this token. Check that it was copied completely and has not expired."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signOut() {
        Keychain.delete()
        token = nil
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
