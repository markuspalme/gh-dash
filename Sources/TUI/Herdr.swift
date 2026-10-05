import Foundation

/// Reports the dashboard's state to herdr (https://herdr.dev) when running in
/// one of its panes: blocked while something is waiting on the user, idle
/// otherwise. Does nothing outside herdr.
final class Herdr {
    enum State: Equatable {
        case working
        case idle
        case blocked(count: Int)
    }

    private let binary: String
    private let paneID: String
    private var lastState: State?

    /// Nil unless the HERDR_* environment variables are present.
    init?(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard environment["HERDR_ENV"] == "1",
              let binary = environment["HERDR_BIN_PATH"], !binary.isEmpty,
              let paneID = environment["HERDR_PANE_ID"], !paneID.isEmpty else { return nil }
        self.binary = binary
        self.paneID = paneID
    }

    func report(_ state: State) {
        guard state != lastState else { return }
        lastState = state
        var arguments = ["pane", "report-agent", paneID, "--source", "ghdash", "--agent", "GHDash", "--seq", sequence()]
        switch state {
        case .working:
            arguments += ["--state", "working"]
        case .idle:
            arguments += ["--state", "idle"]
        case .blocked(let count):
            arguments += ["--state", "blocked", "--message", count == 1 ? "1 item waiting on you" : "\(count) items waiting on you"]
        }
        // No resume command: the installed herdr rejects the documented `-- …` form.
        run(arguments)
    }

    /// Tells herdr the pane no longer has an agent; call before exiting.
    func release() {
        run(["pane", "release-agent", paneID, "--source", "ghdash", "--agent", "GHDash", "--seq", sequence()], wait: true)
    }

    private func sequence() -> String {
        String(Int(Date.now.timeIntervalSince1970 * 1000))
    }

    private func run(_ arguments: [String], wait: Bool = false) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return
        }
        if wait {
            process.waitUntilExit()
        } else {
            // Reap it off the main thread so the UI never waits on herdr.
            Thread.detachNewThread { process.waitUntilExit() }
        }
    }
}
