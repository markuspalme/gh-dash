import Foundation

/// The terminal app's settings, kept in `~/.config/ghdash/config.json`:
/// the chosen repositories, the hide filters, collapsed sections and
/// the repository scope. Separate from the Mac app's settings by design.
final class TUIConfig: RepoSelectionStorage {
    private struct Contents: Codable {
        var repos: [String] = []
        var hideDrafts = true
        var hideFailingDependabot = true
        var hideDependabot = false
        var collapsedSections: [String] = []
        var scope: String?

        init() {}

        /// Keys added in later versions may be missing from an older file.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            repos = try container.decodeIfPresent([String].self, forKey: .repos) ?? []
            hideDrafts = try container.decodeIfPresent(Bool.self, forKey: .hideDrafts) ?? true
            hideFailingDependabot = try container.decodeIfPresent(Bool.self, forKey: .hideFailingDependabot) ?? true
            hideDependabot = try container.decodeIfPresent(Bool.self, forKey: .hideDependabot) ?? false
            collapsedSections = try container.decodeIfPresent([String].self, forKey: .collapsedSections) ?? []
            scope = try container.decodeIfPresent(String.self, forKey: .scope)
        }
    }

    static let fileURL: URL = {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config")
        return base.appending(path: "ghdash/config.json")
    }()

    private var contents: Contents
    /// Repositories given on the command line replace the saved ones for this run only.
    private let transientRepos: [Repo]?

    init(transientRepos: [Repo]? = nil) {
        self.transientRepos = transientRepos
        if let data = try? Data(contentsOf: Self.fileURL),
           let stored = try? JSONDecoder().decode(Contents.self, from: data) {
            contents = stored
        } else {
            contents = Contents()
        }
    }

    var filter: PullRequestFilter {
        get {
            PullRequestFilter(
                hideDrafts: contents.hideDrafts,
                hideFailingDependabot: contents.hideFailingDependabot,
                hideDependabot: contents.hideDependabot
            )
        }
        set {
            contents.hideDrafts = newValue.hideDrafts
            contents.hideFailingDependabot = newValue.hideFailingDependabot
            contents.hideDependabot = newValue.hideDependabot
            save()
        }
    }

    var collapsedSections: Set<String> {
        get { Set(contents.collapsedSections) }
        set {
            contents.collapsedSections = newValue.sorted()
            save()
        }
    }

    /// Full name of the repository the dashboard is scoped to; nil for all.
    var scope: String? {
        get { contents.scope }
        set {
            contents.scope = newValue
            save()
        }
    }

    // MARK: RepoSelectionStorage

    func load() -> [Repo] {
        transientRepos ?? contents.repos.compactMap(Repo.init(fullName:))
    }

    func save(_ repos: [Repo]) {
        guard transientRepos == nil else { return }
        contents.repos = repos.map(\.fullName)
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(contents) else { return }
        let directory = Self.fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}
