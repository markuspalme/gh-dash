import SwiftUI

@main
struct GHDashApp: App {
    @State private var store = DashboardStore()

    var body: some Scene {
        Window("GitHub Dashboard", id: "main") {
            ContentView(store: store)
                .frame(minWidth: 860, minHeight: 400)
        }
        .defaultSize(width: 920, height: 780)
    }
}
