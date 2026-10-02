import SwiftUI

@main
struct GHDashApp: App {
    @State private var store: DashboardStore

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
    }
}
