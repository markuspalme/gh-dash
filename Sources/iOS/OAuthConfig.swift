import Foundation

enum OAuthConfig {
    /// Client ID of the GitHub OAuth app that GHDash signs in with. It is a
    /// public identifier, not a secret.
    ///
    /// To use your own, register an app at
    /// https://github.com/settings/applications/new, tick "Enable Device
    /// Flow", and replace this value.
    static let clientID = "Ov23liSXhfWzKUjPTsjh"

    /// `repo` is what lets the app read pull requests and workflow runs in
    /// private repositories; GitHub has no read-only variant of it.
    static let scope = "repo"
}
