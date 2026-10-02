import SwiftUI

/// Sheet for choosing which repositories the dashboard covers.
struct RepoPicker: View {
    let store: DashboardStore
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    /// Repositories selected when the sheet opened. They stay at the top so
    /// rows don't jump around while toggling.
    @State private var pinned: [Repo] = []

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Repositories")
                    .font(.headline)
                TextField("Search", text: $search)
                    .textFieldStyle(.roundedBorder)
            }
            .padding()
            Divider()
            list
            Divider()
            HStack {
                Text("\(store.repos.count) selected")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 460, height: 540)
        .task {
            pinned = store.repos
            await store.loadAvailableRepos()
        }
    }

    @ViewBuilder
    private var list: some View {
        let repos = matchingRepos
        List {
            ForEach(repos) { repo in
                Toggle(isOn: selection(for: repo)) {
                    Text(repo.fullName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .toggleStyle(.checkbox)
            }
            if let error = store.availableReposError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.inset)
        .overlay {
            if store.isLoadingAvailableRepos, store.availableRepos.isEmpty {
                ProgressView("Loading repositories…")
            } else if repos.isEmpty, store.availableReposError == nil {
                Text("No matching repositories")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var matchingRepos: [Repo] {
        let all = pinned + store.availableRepos.filter { !pinned.contains($0) }
        guard !search.isEmpty else { return all }
        return all.filter { $0.fullName.localizedCaseInsensitiveContains(search) }
    }

    private func selection(for repo: Repo) -> Binding<Bool> {
        Binding(
            get: { store.repos.contains(repo) },
            set: { store.setRepo(repo, selected: $0) }
        )
    }
}
