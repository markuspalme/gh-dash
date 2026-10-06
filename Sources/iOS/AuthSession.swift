import Foundation
import Observation

/// The signed-in GitHub account: a personal access token the user pasted in,
/// checked against GitHub once and then kept in the Keychain.
@MainActor
@Observable
final class AuthSession {
    struct NotSignedIn: LocalizedError {
        var errorDescription: String? { "Not signed in to GitHub." }
    }

    private static let tokenAccount = "github-token"
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
            token = Keychain.read(Self.tokenAccount)
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
            Keychain.save(candidate, for: Self.tokenAccount)
            errorMessage = nil
            token = candidate
        } catch let error as GitHubError where error.isUnauthorized {
            errorMessage = "GitHub rejected this token. Check that it was copied completely and has not expired."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signOut() {
        Keychain.delete(Self.tokenAccount)
        token = nil
    }
}
