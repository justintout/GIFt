import Foundation

/// What the Settings window's Agents pane installs and links to.
enum AgentSetup {
    static let guideURL = URL(string: "https://justintout.github.io/GIFt/agents.html")!
    static let mcpGuideURL = URL(string: "https://justintout.github.io/GIFt/mcp.html")!

    /// On the default PATH of every shell, so agents find `gift` without any profile changes.
    static let commandPath = "/usr/local/bin/gift"

    static var isCommandInstalled: Bool {
        guard let executable = Bundle.main.executableURL else { return false }
        return URL(fileURLWithPath: commandPath).resolvingSymlinksInPath() == executable.resolvingSymlinksInPath()
    }

    /// Links `gift` to this app's executable. /usr/local/bin belongs to root, so macOS asks for an
    /// administrator password.
    static func installCommand() throws {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath().path else { return }
        let command = "mkdir -p /usr/local/bin && ln -sf \(quoted(executable)) \(quoted(commandPath))"
        let script = "do shell script \"\(command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        // -128 is the user canceling the password prompt, which needs no message.
        if let error, error[NSAppleScript.errorNumber] as? Int != -128 {
            throw InstallError(message: error[NSAppleScript.errorMessage] as? String ?? "The command could not be installed.")
        }
    }

    struct InstallError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func quoted(_ path: String) -> String {
        "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
