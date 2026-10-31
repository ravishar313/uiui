import XCTest
@testable import UIUI

/// An update never opens a window or takes focus because dictation went idle. Only the
/// person's own choice opens the prompt. No network and no window: a URLProtocol stub
/// answers the release lookup and the prompt is a counting closure.
@MainActor
final class UpdateInterruptionGateTests: XCTestCase {
    func testPolicyPromptsOnlyForAnExplicitCheckWhileIdle() {
        XCTAssertEqual(UpdatePresentation.forFoundRelease(userInitiated: true, workInFlight: false), .promptNow)
        XCTAssertEqual(UpdatePresentation.forFoundRelease(userInitiated: true, workInFlight: true), .indicate)
        XCTAssertEqual(UpdatePresentation.forFoundRelease(userInitiated: false, workInFlight: false), .indicate, "Idle alone never opens a prompt")
        XCTAssertEqual(UpdatePresentation.forFoundRelease(userInitiated: false, workInFlight: true), .indicate)
        XCTAssertFalse(UpdatePresentation.mayShowModal(workInFlight: true))
        XCTAssertTrue(UpdatePresentation.mayShowModal(workInFlight: false))
    }

    private struct Harness {
        let updater: AppUpdater
        let prompts: Counter
        let notices: Counter
        let defaults: UserDefaults
        var inFlight: Flag
    }
    private final class Counter { var count = 0; var choice: UpdatePromptChoice = .later }
    private final class Flag { var value = false }

    private func harness(release: String = "9.9.0") throws -> Harness {
        let suite = "uiui-updater-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        StubReleaseProtocol.body = Data(#"""
        {"tag_name":"v\#(release)","name":"uiui \#(release)","body":"Notes","html_url":"https://github.com/x/y/releases/tag/v\#(release)","draft":false,"prerelease":false,"assets":[{"name":"uiui-\#(release)-arm64.zip","browser_download_url":"https://github.com/x/y/releases/download/v\#(release)/uiui-\#(release)-arm64.zip","size":10},{"name":"uiui-\#(release)-arm64.zip.sha256","browser_download_url":"https://github.com/x/y/releases/download/v\#(release)/uiui-\#(release)-arm64.zip.sha256","size":10}]}
        """#.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubReleaseProtocol.self]
        let updater = AppUpdater(repository: "x/y", currentVersion: "1.0.0", defaults: defaults, session: URLSession(configuration: configuration))
        let prompts = Counter(), notices = Counter(), flag = Flag()
        updater.promptUser = { _, _ in prompts.count += 1; return prompts.choice }
        updater.showNotice = { _, _ in notices.count += 1 }
        updater.isWorkInFlight = { flag.value }
        return Harness(updater: updater, prompts: prompts, notices: notices, defaults: defaults, inFlight: flag)
    }

    func testAutomaticCheckShowsAQuietIndicationAndNeverPrompts() async throws {
        let h = try harness()
        let chosen = await h.updater.check(userInitiated: false)
        XCTAssertNil(chosen)
        XCTAssertEqual(h.prompts.count, 0)
        XCTAssertEqual(h.notices.count, 0)
        XCTAssertEqual(h.updater.pendingNotice?.version.description, "9.9.0")
        // Dictation finishing is exactly the moment the old code prompted.
        h.inFlight.value = true
        h.updater.activityChanged()
        h.inFlight.value = false
        h.updater.activityChanged()
        XCTAssertEqual(h.prompts.count, 0, "Going idle opens nothing")
    }

    func testExplicitCheckKeepsItsPromptWhenIdle() async throws {
        let h = try harness()
        h.prompts.choice = .install
        let chosen = await h.updater.check(userInitiated: true)
        XCTAssertEqual(h.prompts.count, 1)
        XCTAssertNotNil(chosen)
        XCTAssertNil(h.updater.pendingNotice, "Chosen to install: no lingering notice")
    }

    func testLaterKeepsTheIndicationAndSkipClearsItForAutomaticChecks() async throws {
        let h = try harness()
        h.prompts.choice = .later
        _ = await h.updater.check(userInitiated: true)
        XCTAssertNotNil(h.updater.pendingNotice)
        h.prompts.choice = .skip
        h.updater.presentPendingUpdate()
        for _ in 0..<200 where h.prompts.count < 2 { await Task.yield() }
        XCTAssertEqual(h.prompts.count, 2, "Chosen from the indication: the prompt opens")
        XCTAssertNil(h.updater.pendingNotice)
        _ = await h.updater.check(userInitiated: false)
        XCTAssertNil(h.updater.pendingNotice, "A skipped version stays quiet")
        XCTAssertEqual(h.prompts.count, 2)
    }

    func testNothingModalOpensWhileDictationIsInFlight() async throws {
        let h = try harness()
        h.inFlight.value = true
        let chosen = await h.updater.check(userInitiated: true)
        XCTAssertNil(chosen)
        XCTAssertEqual(h.prompts.count, 0, "Even an explicit check waits")
        XCTAssertNotNil(h.updater.pendingNotice)
        h.updater.presentPendingUpdate()
        await Task.yield()
        XCTAssertEqual(h.prompts.count, 0, "Choosing it mid-dictation does not open a window either")
        XCTAssertTrue(h.updater.status.contains("when dictation is finished"))
    }

    func testUpToDateAlertIsSuppressedMidDictation() async throws {
        let h = try harness(release: "0.9.0")
        h.inFlight.value = true
        _ = await h.updater.check(userInitiated: true)
        XCTAssertEqual(h.notices.count, 0)
        h.inFlight.value = false
        _ = await h.updater.check(userInitiated: true)
        XCTAssertEqual(h.notices.count, 1, "Idle, an explicit check still says it is up to date")
    }

    func testIdleModelReportsNoDictationWork() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("uiui-gate-\(UUID().uuidString)")
        let suite = "uiui-gate-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = AppModel(dataDirectory: root, defaults: defaults, persistSettings: false)
        defer {
            model.shutdown(); try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        XCTAssertFalse(model.isDictationWorkInFlight)
        model.manualCleanupInProgress = true
        XCTAssertTrue(model.isDictationWorkInFlight)
    }
}

private final class StubReleaseProtocol: URLProtocol {
    nonisolated(unsafe) static var body = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
