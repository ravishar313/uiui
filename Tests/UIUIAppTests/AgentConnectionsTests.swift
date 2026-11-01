import XCTest
@testable import UIUI

final class AgentConnectionsTests: XCTestCase {
    private func home() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("uiui-connect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testOnlyAgentsPresentOnThisMacAreInstalled() throws {
        let root = try home()
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        let agents = AgentConnections.known(home: root)
        XCTAssertEqual(agents.filter(\.isInstalled).map(\.id), ["codex"])
    }

    func testConnectWritesASkillAndDisconnectRemovesExactlyThat() throws {
        let root = try home()
        let agent = try XCTUnwrap(AgentConnections.known(home: root).first)
        try FileManager.default.createDirectory(at: agent.home, withIntermediateDirectories: true)
        try AgentConnections.connect(agent, commandPath: "/Applications/uiui.app/Contents/MacOS/uiui")
        XCTAssertTrue(agent.isConnected)
        let text = try String(contentsOf: agent.skillDirectory.appendingPathComponent("SKILL.md"), encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("---\nname: uiui-ask\ndescription: "))
        XCTAssertTrue(text.contains("/Applications/uiui.app/Contents/MacOS/uiui ask"))
        try AgentConnections.disconnect(agent)
        XCTAssertFalse(agent.isConnected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: agent.skillDirectory.path))
    }

    func testAnotherSkillWithTheSameNameIsNeverTouched() throws {
        let root = try home()
        let agent = try XCTUnwrap(AgentConnections.known(home: root).first)
        let file = agent.skillDirectory.appendingPathComponent("SKILL.md")
        try FileManager.default.createDirectory(at: agent.skillDirectory, withIntermediateDirectories: true)
        try "mine".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try AgentConnections.connect(agent))
        try AgentConnections.disconnect(agent)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "mine")
    }
}
