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
        content
            .task {
                pinned = store.repos
                await store.loadAvailableRepos()
            }
    }

    #if os(macOS)
    private var content: some View {
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
                .listStyle(.inset)
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
    }
    #else
    private var content: some View {
        NavigationStack {
            list
                .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
                .navigationTitle("Repositories")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .bottomBar) {
                        Text("\(store.repos.count) selected")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
        }
    }
    #endif

    private var list: some View {
        let repos = matchingRepos
        return List {
            if store.availableReposHiddenBySSO {
                Label {
                    Text("Some organisations are hidden because this token is not authorised for their single sign-on. Authorise it under **Configure SSO** at github.com/settings/tokens.")
                } icon: {
                    Image(systemName: "lock.fill")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            ForEach(repos) { repo in
                row(for: repo)
            }
            if let error = store.availableReposError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .overlay {
            if store.isLoadingAvailableRepos, store.availableRepos.isEmpty {
                ProgressView("Loading repositories…")
            } else if repos.isEmpty, store.availableReposError == nil {
                Text("No matching repositories")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func row(for repo: Repo) -> some View {
        let isSelected = selection(for: repo)
        #if os(macOS)
        Toggle(isOn: isSelected) {
            Text(repo.fullName)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .toggleStyle(.checkbox)
        #else
        Button {
            isSelected.wrappedValue.toggle()
        } label: {
            HStack {
                Text(repo.fullName)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if isSelected.wrappedValue {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                }
            }
        }
        #endif
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
