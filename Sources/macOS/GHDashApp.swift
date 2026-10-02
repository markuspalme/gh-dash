import SwiftUI

@main
struct GHDashApp: App {
    @State private var store: DashboardStore
    @AppStorage(PullRequestFilter.hideDraftsKey) private var hideDrafts = true
    @AppStorage(PullRequestFilter.hideFailingDependabotKey) private var hideFailingDependabot = true

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
    }

    var body: some Scene {
        Window("GitHub Dashboard", id: "main") {
            ContentView(store: store)
                .frame(minWidth: 860, minHeight: 400)
        }
        .defaultSize(width: 920, height: 780)
        .commands {
            // The filters also live in the View menu, where Mac users look for them.
            CommandGroup(before: .toolbar) {
                Toggle("Hide Drafts", isOn: $hideDrafts)
                Toggle("Hide Failing Dependabot", isOn: $hideFailingDependabot)
                Divider()
            }
        }
    }
}
