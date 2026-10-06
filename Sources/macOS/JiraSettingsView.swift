import SwiftUI

/// Sheet for the Atlassian site, account, API token and projects to follow.
struct JiraSettingsView: View {
    let store: JiraStore
    @Environment(\.dismiss) private var dismiss
    @State private var site = ""
    @State private var email = ""
    @State private var token = ""
    @State private var projects = ""
    @State private var check: Check = .idle

    private enum Check: Equatable {
        case idle, running, ok(String), failed(String)
    }

    private static let tokenPageURL = URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")!

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Jira")
                .font(.headline)
                .padding()
            Divider()
            Form {
                TextField("Site", text: $site, prompt: Text("https://example.atlassian.net"))
                TextField("Email", text: $email, prompt: Text("you@example.com"))
                SecureField("API token", text: $token, prompt: Text(store.hasToken ? "unchanged" : "paste a token"))
                LabeledContent("") {
                    Link("Create an API token on Atlassian", destination: Self.tokenPageURL)
                        .font(.callout)
                }
                TextField("Projects", text: $projects, prompt: Text("INTEL, MARS"))
                LabeledContent("") {
                    Text("Project keys, separated by commas. Activity and tickets are shown for these.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            Divider()
            HStack {
                Button("Test") { Task { await test() } }
                    .disabled(check == .running || !draft.isComplete)
                switch check {
                case .idle: EmptyView()
                case .running: ProgressView().controlSize(.small)
                case .ok(let name): Label("Signed in as \(name)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed(let message): Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    store.save(config: draft, token: token)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.isComplete || (!store.hasToken && token.isEmpty))
            }
            .padding()
        }
        .frame(width: 520)
        .onAppear {
            site = store.config.site?.absoluteString ?? ""
            email = store.config.email
            projects = store.config.projects.joined(separator: ", ")
        }
    }

    private var draft: JiraConfig {
        var siteText = site.trimmingCharacters(in: .whitespacesAndNewlines)
        if !siteText.isEmpty, !siteText.contains("://") { siteText = "https://" + siteText }
        if siteText.hasSuffix("/") { siteText.removeLast() }
        return JiraConfig(
            site: siteText.isEmpty ? nil : URL(string: siteText),
            email: email.trimmingCharacters(in: .whitespaces),
            projects: projects.split(whereSeparator: { $0 == "," || $0 == " " }).map { $0.uppercased() }.filter { !$0.isEmpty }
        )
    }

    private func test() async {
        check = .running
        do {
            check = .ok(try await store.verify(config: draft, token: token))
        } catch {
            check = .failed(error.localizedDescription)
        }
    }
}
