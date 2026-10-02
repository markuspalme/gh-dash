import SwiftUI

struct SignInView: View {
    let auth: AuthSession
    @State private var token = ""
    @FocusState private var isTokenFocused: Bool

    /// GitHub's page for a new classic token, with the scopes and a name filled in.
    private static let newTokenURL = URL(string: "https://github.com/settings/tokens/new?scopes=repo,read:org&description=GHDash")!

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
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
                .padding(.top, 48)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Personal access token")
                        .font(.headline)
                    HStack {
                        SecureField("ghp_…", text: $token)
                            .textContentType(.password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($isTokenFocused)
                            .submitLabel(.go)
                            .onSubmit(signIn)
                        PasteButton(payloadType: String.self) { strings in
                            token = strings.first ?? ""
                        }
                        .labelStyle(.iconOnly)
                    }
                    .padding(12)
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Text("Sign in with a classic token that has the **repo** scope; **read:org** adds the names of teams asked to review. It is stored in the Keychain on this device and only ever sent to GitHub.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Link(destination: Self.newTokenURL) {
                        Label("Create a token on GitHub", systemImage: "arrow.up.right")
                            .font(.footnote)
                    }
                }

                if let message = auth.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button(action: signIn) {
                    Group {
                        if auth.isCheckingToken {
                            ProgressView()
                        } else {
                            Text("Sign In")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || auth.isCheckingToken)
            }
            .padding(32)
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func signIn() {
        isTokenFocused = false
        Task { await auth.signIn(with: token) }
    }
}
