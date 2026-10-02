import Foundation

/// On the Mac, credentials come from the GitHub CLI, so the app never stores a token itself.
enum GitHubCLI {
    enum Failure: LocalizedError {
        case notInstalled
        case noToken(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                "GitHub CLI (gh) not found. Install it and run `gh auth login`."
            case .noToken(let detail):
                "Could not get a token from `gh auth token`: \(detail)"
            }
        }
    }

    static func token() async throws -> String {
        try await Task.detached { try readToken() }.value
    }

    private static func readToken() throws -> String {
        if let token = ProcessInfo.processInfo.environment["GH_TOKEN"], !token.isEmpty {
            return token
        }
        // Apps launched from Finder don't inherit the shell's PATH.
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        guard let gh = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw Failure.notInstalled
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: gh)
        process.arguments = ["auth", "token"]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let token = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, !token.isEmpty else {
            let detail = String(decoding: errorOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.noToken(detail.isEmpty ? "not logged in" : detail)
        }
        return token
    }
}
