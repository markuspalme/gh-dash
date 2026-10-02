# GHDash

A small native macOS dashboard for your GitHub work across the repositories you choose. The main goal of this application is to show everything that's waiting for me across repositories at a glance.

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

## Requirements

- macOS 15 or later
- Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- The [GitHub CLI](https://cli.github.com), logged in with `gh auth login`

The app gets its token by running `gh auth token` and stores no credentials itself, which is why it is not sandboxed. Setting `GH_TOKEN` in the app's environment overrides this.

## Build and run

```sh
make run      # build and open the app
make install  # copy it to /Applications
make demo     # open a second instance with made-up data, no GitHub login needed
```

On first launch, pick the repositories to show with **Choose Repositories…**.

The Xcode project is generated from `project.yml`; run `make project` to open it in Xcode. The app icon is drawn by `scripts/make-icon.swift`.
