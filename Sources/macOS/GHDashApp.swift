import SwiftUI

@main
struct GHDashApp: App {
    @State private var store: DashboardStore
    @State private var jira: JiraStore
    @AppStorage("page") private var page = Page.github
    @AppStorage(PullRequestFilter.hideDraftsKey) private var hideDrafts = true
    @AppStorage(PullRequestFilter.hideFailingDependabotKey) private var hideFailingDependabot = true
    @AppStorage(PullRequestFilter.hideDependabotKey) private var hideDependabot = false

    init() {
        let isDemo = ProcessInfo.processInfo.arguments.contains("--demo")
        let store = DashboardStore(demo: isDemo, token: GitHubCLI.token)
        if !isDemo {
            Notifier.shared.start()
            store.postNotification = { title, subtitle, body, url in
                Notifier.shared.post(title: title, subtitle: subtitle, body: body, url: url)
            }
        }
        _store = State(initialValue: store)
        _jira = State(initialValue: JiraStore(demo: isDemo))
    }

    var body: some Scene {
        Window("GitHub Dashboard", id: "main") {
            RootView(store: store, jira: jira)
                .frame(minWidth: 860, minHeight: 400)
        }
        .defaultSize(width: 920, height: 780)
        .commands {
            // The filters also live in the View menu, where Mac users look for them.
            CommandGroup(before: .toolbar) {
                Button("GitHub") { page = .github }
                    .keyboardShortcut("1")
                Button("Jira") { page = .jira }
                    .keyboardShortcut("2")
                Divider()
                Toggle("Hide Drafts", isOn: $hideDrafts)
                Toggle("Hide Failing Dependabot", isOn: $hideFailingDependabot)
                Toggle("Hide All Dependabot", isOn: $hideDependabot)
                Divider()
            }
        }
    }
}
