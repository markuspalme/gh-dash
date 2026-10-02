import SwiftUI

@main
struct GHDashMobileApp: App {
    @State private var auth: AuthSession
    @State private var store: DashboardStore
    private let isDemo: Bool

    init() {
        isDemo = ProcessInfo.processInfo.arguments.contains("--demo")
        let auth = AuthSession()
        let store = DashboardStore(demo: isDemo, token: { try await auth.currentToken() })
        // A token GitHub no longer accepts (revoked or expired) sends the user back to sign-in.
        store.onUnauthorized = { auth.signOut() }
        _auth = State(initialValue: auth)
        _store = State(initialValue: store)
    }

    var body: some Scene {
        WindowGroup {
            if isDemo {
                MobileContentView(store: store, signOut: nil)
            } else if auth.isSignedIn {
                MobileContentView(store: store, signOut: auth.signOut)
                    .onDisappear { store.clear() }
            } else {
                SignInView(auth: auth)
            }
        }
    }
}
