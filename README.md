# GHDash

A small native dashboard, for macOS and iOS, for your GitHub work across the repositories you choose. The main goal of this application is to show everything that's waiting for you across repositories at a glance.

> This project is 100% vibe-coded: all of the code was written by Claude Code from conversational prompts.

![GHDash showing pull requests, review requests and pending Actions runs](docs/screenshot.png)

*Screenshot of the demo mode, which shows made-up data.*

It shows:

- **My open pull requests** – with draft, review, approval, check, conflict and unresolved-thread status
- **Awaiting your review** – pull requests where your review is requested
- **My pull requests waiting on reviewers** – your pull requests with nothing left for you to do
- **Pending actions** – GitHub Actions runs that have not finished, including deployments waiting for approval

Every row opens the pull request or workflow run on GitHub; the app itself is read-only.

A sidebar scopes the dashboard to a single repository and shows item counts per repository. The Dock badge counts the things waiting on you: review requests, your pull requests that need fixing, and deployments you can approve. Data refreshes every three minutes.

## macOS

### Requirements

- macOS 15 or later
- Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- The [GitHub CLI](https://cli.github.com), logged in with `gh auth login`

The app gets its token by running `gh auth token` and stores no credentials itself, which is why it is not sandboxed. Setting `GH_TOKEN` in the app's environment overrides this.

### Build and run

```sh
make run      # build and open the app
make install  # copy it to /Applications
make demo     # open a second instance with made-up data, no GitHub login needed
```

On first launch, pick the repositories to show with **Choose Repositories…**.

## iOS

The iPhone and iPad app shows the same dashboard. It needs iOS 18 or later and has no notifications or badge yet.

### Signing in

iOS has no GitHub CLI to borrow a login from, so the app signs in with GitHub's OAuth [device flow](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps#device-flow): it shows a short code, you enter it on github.com, and the app receives a token that it keeps in the Keychain. The flow needs no client secret, so nothing confidential is in the app.

Sign-in goes through a GitHub OAuth app, whose client ID (a public identifier) is in `Sources/iOS/OAuthConfig.swift`. To use an OAuth app of your own instead:

1. Register one at <https://github.com/settings/applications/new>. The homepage and callback URLs can be anything, such as this repository's URL; the device flow does not use them.
2. Tick **Enable Device Flow**.
3. Replace the client ID in `Sources/iOS/OAuthConfig.swift`.

The app asks for the `repo` scope, which is what lets it read private repositories. If an organisation restricts third-party OAuth apps, an owner has to approve yours before its repositories show up.

### Build and run

```sh
make ios-run   # build, then install and launch in the iPhone simulator
make ios-demo  # the same, with made-up data and no sign-in
```

`IOS_DEVICE="iPad (A16)" make ios-run` picks another simulator. To run on a real device, open the project in Xcode and choose your team for the `GHDashMobile` target.

## Project

The Xcode project is generated from `project.yml`; run `make project` to open it in Xcode. Code shared by both apps is in `Sources/Shared`, with `Sources/macOS` and `Sources/iOS` holding what differs. The app icons are drawn by `scripts/make-icon.swift`.
