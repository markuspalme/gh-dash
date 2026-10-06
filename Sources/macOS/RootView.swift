import SwiftUI

/// The two pages of the window, switched with the segmented control in the toolbar.
enum Page: String, CaseIterable {
    case github, jira

    var title: String {
        switch self {
        case .github: "GitHub"
        case .jira: "Jira"
        }
    }
}

struct RootView: View {
    let store: DashboardStore
    let jira: JiraStore
    @AppStorage("page") private var page = Page.github

    var body: some View {
        switch page {
        case .github:
            ContentView(store: store, page: $page)
        case .jira:
            JiraView(store: jira, page: $page)
        }
    }
}

struct PagePicker: View {
    @Binding var page: Page

    var body: some View {
        Picker("Page", selection: $page) {
            ForEach(Page.allCases, id: \.self) { page in
                Text(page.title).tag(page)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help("Switch between GitHub and Jira (⌘1, ⌘2)")
    }
}
