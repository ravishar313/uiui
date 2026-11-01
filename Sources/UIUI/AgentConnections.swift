import Foundation

/// The one owner of connecting an agent: a small skill in that agent's skills folder,
/// which tells the agent that `uiui ask` exists. Only ever touches its own folder.
/// Nothing runs in the background, and disconnecting removes exactly what was added.
struct AgentConnection: Identifiable, Equatable {
    let id: String
    let name: String
    /// The agent's own folder. Its presence is how uiui knows the agent is installed.
    let home: URL
    var skillDirectory: URL { home.appendingPathComponent("skills/\(AgentConnections.skillName)", isDirectory: true) }
    var isInstalled: Bool { FileManager.default.fileExists(atPath: home.path) }
    var isConnected: Bool {
        FileManager.default.fileExists(atPath: skillDirectory.appendingPathComponent("SKILL.md").path)
    }
}

enum AgentConnections {
    static let skillName = "uiui-ask"
    /// Marks a skill as written by uiui, so a folder of the same name is never overwritten or removed.
    private static let marker = "<!-- Added by uiui. Disconnect in uiui Settings > Agents. -->"

    static func known(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [AgentConnection] {
        [AgentConnection(id: "claude", name: "Claude Code", home: home.appendingPathComponent(".claude", isDirectory: true)),
         AgentConnection(id: "codex", name: "Codex", home: home.appendingPathComponent(".codex", isDirectory: true)),
         AgentConnection(id: "opencode", name: "OpenCode", home: home.appendingPathComponent(".config/opencode", isDirectory: true))]
    }

    /// The command inside this copy of the app.
    static var commandPath: String { Bundle.main.executablePath ?? "/Applications/uiui.app/Contents/MacOS/uiui" }

    static func instructions(commandPath: String) -> String {
        """
        When you need a decision or information only the person can give, and they may not be watching this session, run:

            \(commandPath) ask "your question"

        It shows the question in their Mac's notch and waits while they answer by voice. Their exact words are printed to stdout: treat them as their reply. Keep the question short enough to read at a glance.

        Exit codes: 0 answered. 3 uiui is unavailable. 4 the Mac is locked or asleep, so the person is away. 5 no answer in time (add --timeout seconds; the default is 600). For any non-zero code, carry on or ask in this session instead.
        """
    }

    static func skill(commandPath: String) -> String {
        """
        ---
        name: \(skillName)
        description: Ask the person a question by voice through the uiui notch on their Mac and get their spoken answer back. Use when you need a decision or information only they can give and they may not be watching this session.
        ---
        \(marker)

        \(instructions(commandPath: commandPath))

        """
    }

    static func connect(_ agent: AgentConnection, commandPath: String = commandPath) throws {
        let manager = FileManager.default
        let file = agent.skillDirectory.appendingPathComponent("SKILL.md")
        if manager.fileExists(atPath: file.path), !isOurs(file) { throw CocoaError(.fileWriteFileExists) }
        try manager.createDirectory(at: agent.skillDirectory, withIntermediateDirectories: true)
        try skill(commandPath: commandPath).write(to: file, atomically: true, encoding: .utf8)
    }

    static func disconnect(_ agent: AgentConnection) throws {
        let file = agent.skillDirectory.appendingPathComponent("SKILL.md")
        guard FileManager.default.fileExists(atPath: file.path), isOurs(file) else { return }
        try FileManager.default.removeItem(at: file)
        // Only the folder uiui made, and only if nothing else was added to it.
        if (try? FileManager.default.contentsOfDirectory(atPath: agent.skillDirectory.path))?.isEmpty == true {
            try FileManager.default.removeItem(at: agent.skillDirectory)
        }
    }

    private static func isOurs(_ file: URL) -> Bool {
        (try? String(contentsOf: file, encoding: .utf8))?.contains(marker) == true
    }
}
