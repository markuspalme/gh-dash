import SwiftUI

/// Sheet for the Atlassian site, the sign-in and the projects to follow.
struct JiraSettingsView: View {
    let store: JiraStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var site = ""
    @State private var projects = ""
    @State private var status: Status = .idle

    private enum Status: Equatable {
        case idle, signingIn, signedIn(String), failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Jira")
                .font(.headline)
                .padding()
            Divider()
            Form {
                TextField("Site", text: $site, prompt: Text("https://example.atlassian.net"))
                TextField("Projects", text: $projects, prompt: Text("INTEL, MARS"))
                LabeledContent("") {
                    Text("Project keys, separated by commas. Activity and tickets are shown for these.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Account") {
                    HStack {
                        switch status {
                        case .idle:
                            Text(store.isSignedIn ? "Signed in to Atlassian" : "Not signed in")
                                .foregroundStyle(.secondary)
                        case .signingIn:
                            ProgressView().controlSize(.small)
                            Text("Finish signing in in your browser…")
                                .foregroundStyle(.secondary)
                        case .signedIn(let name):
                            Label(name.isEmpty ? "Signed in" : "Signed in as \(name)", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        case .failed(let message):
                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        if store.isSignedIn {
                            Button("Sign Out") {
                                store.signOut()
                                status = .idle
                            }
                        } else {
                            Button("Sign in with Atlassian…") { Task { await signIn() } }
                                .disabled(status == .signingIn)
                        }
                    }
                }
                LabeledContent("") {
                    Text("Sign-in happens in your browser, through Atlassian's MCP service; no API token is needed. Save the site first so the account can be checked against it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    store.save(config: draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.isComplete)
            }
            .padding()
        }
        .frame(width: 560)
        .onAppear {
            site = store.config.site?.absoluteString ?? ""
            projects = store.config.projects.joined(separator: ", ")
        }
    }

    private var draft: JiraConfig {
        var siteText = site.trimmingCharacters(in: .whitespacesAndNewlines)
        if !siteText.isEmpty, !siteText.contains("://") { siteText = "https://" + siteText }
        if siteText.hasSuffix("/") { siteText.removeLast() }
        return JiraConfig(
            site: siteText.isEmpty ? nil : URL(string: siteText),
            projects: projects.split(whereSeparator: { $0 == "," || $0 == " " }).map { $0.uppercased() }.filter { !$0.isEmpty }
        )
    }

    private func signIn() async {
        // Save the draft first so the account check knows the site.
        if draft.isComplete || draft.site != nil {
            store.save(config: draft)
        }
        status = .signingIn
        do {
            let name = try await store.signIn { url in
                Task { @MainActor in openURL(url) }
            }
            status = .signedIn(name)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}
