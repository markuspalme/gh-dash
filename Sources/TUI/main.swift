import Foundation
import TermKit

// ghdash: the GHDash dashboard in the terminal.
//
//   ghdash                      the repositories chosen with p / File > Choose Repositories
//   ghdash --repo owner/name …  these repositories, for this run only
//   ghdash --demo               made-up data, no GitHub login needed

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--help") || arguments.contains("-h") {
    print("""
        usage: ghdash [--demo] [--repo owner/name ...]

          --repo owner/name   show this repository (repeatable); overrides the saved choice for this run
          --demo              show made-up data without signing in

        Signs in with the GitHub CLI (gh auth login) or GH_TOKEN. Settings live in
        \(TUIConfig.fileURL.path).
        """)
    exit(0)
}

let isDemo = arguments.contains("--demo")
var transientRepos: [Repo] = []
var index = 0
while index < arguments.count {
    if arguments[index] == "--repo", index + 1 < arguments.count {
        if let repo = Repo(fullName: arguments[index + 1]) {
            transientRepos.append(repo)
        } else {
            FileHandle.standardError.write(Data("ghdash: expected owner/name after --repo, got \(arguments[index + 1])\n".utf8))
            exit(2)
        }
        index += 2
    } else {
        index += 1
    }
}

MainActor.assumeIsolated {
    let config = TUIConfig(transientRepos: transientRepos.isEmpty ? nil : transientRepos)
    let store = DashboardStore(demo: isDemo, token: GitHubCLI.token, repoStorage: config)
    Application.prepare()
    // TermKit's defaults are white on blue with cyan menus; use the terminal's
    // own colours instead (black and white here become its defaults below).
    // The menu bar strip is drawn with base.focus and the status bar with the
    // dialog scheme, so all three schemes get the same flat look.
    for scheme in [Colors.base, Colors.menu, Colors.dialog] {
        scheme.normal = Application.makeAttribute(fore: .gray, back: .black)
        scheme.focus = Application.makeAttribute(fore: .gray, back: .blue)
        scheme.hotNormal = Application.makeAttribute(fore: .brightYellow, back: .black)
        scheme.hotFocus = Application.makeAttribute(fore: .brightYellow, back: .blue)
    }
    Colors.base.focus = Application.makeAttribute(fore: .gray, back: .black)
    TerminalColors.adoptTerminalDefaults()
    let screen = DashboardScreen(store: store, config: config, isDemo: isDemo)
    screen.start()
    Application.run()
}
