import AuthenticationServices
import SwiftUI

struct SignInView: View {
    let auth: AuthSession
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var browser: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: "arrow.triangle.pull")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 96, height: 96)
                    .background(.indigo.gradient, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                Text("GHDash")
                    .font(.largeTitle.bold())
                Text("Everything waiting on you across your GitHub repositories.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            step
            Spacer()
            Spacer()
        }
        .padding(32)
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDisappear { browser?.cancel() }
    }

    @ViewBuilder
    private var step: some View {
        switch auth.phase {
        case .signedOut:
            signInButton
        case .failed(let message):
            VStack(spacing: 14) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                signInButton
            }
        case .requestingCode:
            ProgressView("Contacting GitHub…")
        case .awaitingUser(let code, let url):
            VStack(spacing: 18) {
                Text("Enter this code on GitHub to connect the app:")
                    .multilineTextAlignment(.center)
                Text(code)
                    .font(.system(.largeTitle, design: .monospaced).bold())
                    .textSelection(.enabled)
                Button {
                    UIPasteboard.general.string = code
                    openGitHub(url)
                } label: {
                    Label("Copy Code and Open GitHub", systemImage: "arrow.up.forward.app")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                ProgressView("Waiting for GitHub…")
                    .font(.footnote)
                Button("Cancel", role: .cancel) { auth.cancelSignIn() }
            }
        }
    }

    private var signInButton: some View {
        Button {
            auth.signIn()
        } label: {
            Label("Sign in with GitHub", systemImage: "person.badge.key")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    /// Shows GitHub's code page in the system sign-in sheet, which shares
    /// Safari's GitHub login. The device flow never redirects back, so the
    /// sheet closes when sign-in completes (this view goes away) or the user
    /// dismisses it.
    private func openGitHub(_ url: URL) {
        browser?.cancel()
        browser = Task {
            _ = try? await webAuthenticationSession.authenticate(
                using: url,
                callbackURLScheme: "ghdash",
                preferredBrowserSession: .shared
            )
        }
    }
}
