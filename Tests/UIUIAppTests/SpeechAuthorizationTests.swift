import XCTest
import Observation
@testable import UIUI

final class SpeechAuthorizationTests: XCTestCase {
    @MainActor
    func testGrantedPermissionsNeverRequestAgainAcrossRepeatedCaptureChecks() async {
        var requests = 0
        let permissions = SpeechAuthorization(client: .init(
            speechStatus: { .authorized }, microphoneStatus: { .authorized },
            requestSpeech: { requests += 1; return .authorized },
            requestMicrophone: { requests += 1; return .authorized }))
        let first = await permissions.request()
        let second = await permissions.request()
        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(permissions.summary, "Microphone: Allowed · Speech: Allowed")
    }

    @MainActor
    func testDeniedAccessReturnsGuidanceWithoutReopeningPermissionDialog() async {
        var requests = 0
        let permissions = SpeechAuthorization(client: .init(
            speechStatus: { .authorized }, microphoneStatus: { .denied },
            requestSpeech: { requests += 1; return .authorized },
            requestMicrophone: { requests += 1; return .authorized }))
        let first = await permissions.request()
        let second = await permissions.request()
        XCTAssertFalse(first)
        XCTAssertFalse(second)
        XCTAssertEqual(requests, 0)
        XCTAssertTrue(permissions.guidance.contains("Microphone access is denied"))
    }

    @MainActor
    func testConcurrentCallersShareOnePermissionRequestAndRetainGrant() async throws {
        var speechStatus = CapturePermission.notDetermined
        var microphoneStatus = CapturePermission.notDetermined
        var speechRequests = 0
        var microphoneRequests = 0
        var speechReply: CheckedContinuation<CapturePermission, Never>?
        let entered = expectation(description: "One speech permission request")
        let permissions = SpeechAuthorization(client: .init(
            speechStatus: { speechStatus }, microphoneStatus: { microphoneStatus },
            requestSpeech: {
                speechRequests += 1
                return await withCheckedContinuation { reply in speechReply = reply; entered.fulfill() }
            },
            requestMicrophone: { microphoneRequests += 1; microphoneStatus = .authorized; return .authorized }))
        let first = Task { await permissions.request() }
        await fulfillment(of: [entered], timeout: 2)
        let secondEntered = expectation(description: "Second caller shares pending permission")
        let second = Task { secondEntered.fulfill(); return await permissions.request() }
        // Both callers may be waiting while the human answers the same OS dialog.
        await fulfillment(of: [secondEntered], timeout: 2)
        speechStatus = .authorized
        let reply = try XCTUnwrap(speechReply)
        reply.resume(returning: .authorized)
        let firstAllowed = await first.value
        let secondAllowed = await second.value
        XCTAssertTrue(firstAllowed)
        XCTAssertTrue(secondAllowed)
        let laterAllowed = await permissions.request()
        XCTAssertTrue(laterAllowed)
        XCTAssertEqual(speechRequests, 1)
        XCTAssertEqual(microphoneRequests, 1)
    }

    @MainActor
    func testCancelledSpeechPromptDoesNotOpenAnotherMicrophonePrompt() async throws {
        var activeCapture = true
        var speechStatus = CapturePermission.notDetermined
        var microphoneRequests = 0
        var speechReply: CheckedContinuation<CapturePermission, Never>?
        let entered = expectation(description: "Speech prompt is open")
        let permissions = SpeechAuthorization(client: .init(
            speechStatus: { speechStatus }, microphoneStatus: { .notDetermined },
            requestSpeech: { await withCheckedContinuation { reply in speechReply = reply; entered.fulfill() } },
            requestMicrophone: { microphoneRequests += 1; return .authorized }))
        let request = Task { await permissions.request(whileActive: { activeCapture }) }
        await fulfillment(of: [entered], timeout: 2)
        activeCapture = false
        speechStatus = .authorized
        try XCTUnwrap(speechReply).resume(returning: .authorized)
        let allowed = await request.value
        XCTAssertFalse(allowed)
        XCTAssertEqual(microphoneRequests, 0)
    }

    @MainActor
    func testEnglishCaptureNeedsOnlyAllowedMicrophoneWhenAppleSpeechIsDenied() async throws {
        var speechRequests = 0
        let permissions = SpeechAuthorization(client: .init(
            speechStatus: { .denied }, microphoneStatus: { .authorized },
            requestSpeech: { speechRequests += 1; return .denied }, requestMicrophone: { .authorized }))
        let owner = SpeechAudioOwner { _ in PermissionOnlyAudioSession() }
        let speech = SpeechCapture(audioOwner: owner, permissionOwner: permissions)
        defer { speech.cancel() }
        try await speech.start(locale: "en-IN", contextualStrings: [])
        XCTAssertTrue(speech.isRecording)
        XCTAssertEqual(speechRequests, 0)
        let appleAllowed = await permissions.request()
        XCTAssertFalse(appleAllowed, "Apple capture and explicit Settings still require their own speech grant")
    }

    @MainActor
    func testUndeterminedAppleSpeechIsNeverRequestedForEnglishMicrophoneCapture() async {
        var speechRequests = 0
        var microphoneRequests = 0
        var microphone = CapturePermission.notDetermined
        let permissions = SpeechAuthorization(client: .init(
            speechStatus: { .notDetermined }, microphoneStatus: { microphone },
            requestSpeech: { speechRequests += 1; return .authorized },
            requestMicrophone: { microphoneRequests += 1; microphone = .authorized; return microphone }))
        let allowed = await permissions.request(requiresSpeechRecognition: false)
        XCTAssertTrue(allowed)
        XCTAssertEqual(speechRequests, 0)
        XCTAssertEqual(microphoneRequests, 1)
    }

    @MainActor
    func testMixedRequestersShareMicrophonePromptButEnglishDoesNotWaitForSettingsSpeechGrant() async throws {
        var microphone = CapturePermission.notDetermined
        var speech = CapturePermission.notDetermined
        var microphoneReply: CheckedContinuation<CapturePermission, Never>?
        var speechReply: CheckedContinuation<CapturePermission, Never>?
        var microphoneRequests = 0
        var speechRequests = 0
        let microphoneEntered = expectation(description: "One microphone dialog")
        let speechEntered = expectation(description: "Settings speech dialog follows microphone")
        let englishCompleted = expectation(description: "English capture continues without Apple's speech grant")
        let settingsJoined = expectation(description: "Settings joined the pending microphone request")
        let permissions = SpeechAuthorization(client: .init(
            speechStatus: { speech }, microphoneStatus: { microphone },
            requestSpeech: {
                speechRequests += 1
                return await withCheckedContinuation { speechReply = $0; speechEntered.fulfill() }
            },
            requestMicrophone: {
                microphoneRequests += 1
                return await withCheckedContinuation { microphoneReply = $0; microphoneEntered.fulfill() }
            }))
        let english = Task {
            let allowed = await permissions.request(requiresSpeechRecognition: false)
            englishCompleted.fulfill()
            return allowed
        }
        await fulfillment(of: [microphoneEntered], timeout: 2)
        let settings = Task { settingsJoined.fulfill(); return await permissions.request() }
        await fulfillment(of: [settingsJoined], timeout: 2)
        microphone = .authorized
        try XCTUnwrap(microphoneReply).resume(returning: .authorized)
        await fulfillment(of: [speechEntered, englishCompleted], timeout: 2)
        speech = .denied
        try XCTUnwrap(speechReply).resume(returning: .denied)
        let englishAllowed = await english.value
        let settingsAllowed = await settings.value
        XCTAssertTrue(englishAllowed)
        XCTAssertFalse(settingsAllowed)
        XCTAssertEqual(microphoneRequests, 1)
        XCTAssertEqual(speechRequests, 1)
    }

    @MainActor
    func testCancelledSettingsRequesterCannotBlockAnActiveEnglishRequesterAfterSpeechDenial() async throws {
        var speech = CapturePermission.notDetermined
        var microphone = CapturePermission.notDetermined
        var speechReply: CheckedContinuation<CapturePermission, Never>?
        var microphoneRequests = 0
        let entered = expectation(description: "Settings speech dialog is open")
        let englishJoined = expectation(description: "English caller shares the single prompt owner")
        let permissions = SpeechAuthorization(client: .init(
            speechStatus: { speech }, microphoneStatus: { microphone },
            requestSpeech: { await withCheckedContinuation { speechReply = $0; entered.fulfill() } },
            requestMicrophone: { microphoneRequests += 1; microphone = .authorized; return microphone }))
        let settings = Task { await permissions.request() }
        await fulfillment(of: [entered], timeout: 2)
        let english = Task { englishJoined.fulfill(); return await permissions.request(requiresSpeechRecognition: false) }
        await fulfillment(of: [englishJoined], timeout: 2)
        settings.cancel()
        speech = .denied
        try XCTUnwrap(speechReply).resume(returning: .denied)
        let settingsAllowed = await settings.value
        let englishAllowed = await english.value
        XCTAssertFalse(settingsAllowed)
        XCTAssertTrue(englishAllowed)
        XCTAssertEqual(microphoneRequests, 1)
    }

    @MainActor
    func testTaskCancellationAlonePreventsASecondPermissionPrompt() async throws {
        var speech = CapturePermission.notDetermined
        var speechReply: CheckedContinuation<CapturePermission, Never>?
        var microphoneRequests = 0
        let entered = expectation(description: "Speech dialog is open")
        let permissions = SpeechAuthorization(client: .init(
            speechStatus: { speech }, microphoneStatus: { .notDetermined },
            requestSpeech: { await withCheckedContinuation { speechReply = $0; entered.fulfill() } },
            requestMicrophone: { microphoneRequests += 1; return .authorized }))
        let request = Task { await permissions.request() }
        await fulfillment(of: [entered], timeout: 2)
        request.cancel()
        speech = .authorized
        try XCTUnwrap(speechReply).resume(returning: .authorized)
        let allowed = await request.value
        XCTAssertFalse(allowed)
        XCTAssertEqual(microphoneRequests, 0)
    }

    @MainActor
    func testInconclusiveSpeechReplyIsAttemptedOnceAndALaterExplicitRequestCanRetry() async {
        var requests = 0
        let permissions = SpeechAuthorization(client: .init(
            speechStatus: { .notDetermined }, microphoneStatus: { .authorized },
            requestSpeech: { requests += 1; return requests == 1 ? .notDetermined : .denied },
            requestMicrophone: { .authorized }))
        let first = await permissions.request()
        XCTAssertFalse(first)
        XCTAssertEqual(requests, 1, "An inconclusive reply must not reopen the same dialog")
        XCTAssertEqual(permissions.speechStatus, .notDetermined, "Do not synthesize a denied OS status")
        let explicitRetry = await permissions.request()
        XCTAssertFalse(explicitRetry)
        XCTAssertEqual(requests, 2, "The last waiter leaving permits a later explicit retry")
    }

    @MainActor
    func testInconclusiveMicrophoneReplyForEnglishIsAttemptedOnceAndCanRetryLater() async {
        var requests = 0
        var speechRequests = 0
        let permissions = SpeechAuthorization(client: .init(
            speechStatus: { .notDetermined }, microphoneStatus: { .notDetermined },
            requestSpeech: { speechRequests += 1; return .denied },
            requestMicrophone: { requests += 1; return requests == 1 ? .notDetermined : .denied }))
        let first = await permissions.request(requiresSpeechRecognition: false)
        XCTAssertFalse(first)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(speechRequests, 0)
        XCTAssertEqual(permissions.microphoneStatus, .notDetermined)
        let explicitRetry = await permissions.request(requiresSpeechRecognition: false)
        XCTAssertFalse(explicitRetry)
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(speechRequests, 0)
    }

    @MainActor
    func testConcurrentWaitersShareOneInconclusiveAttemptForEachRequiredPermission() async throws {
        for requiresSpeech in [true, false] {
            var requests = 0
            var reply: CheckedContinuation<CapturePermission, Never>?
            let entered = expectation(description: "One inconclusive OS request")
            let joined = expectation(description: "Concurrent caller joins the same wave")
            let request: () async -> CapturePermission = {
                requests += 1
                // Unexpected repeats return denied so a regression fails quickly
                // instead of leaving a test or the app in an endless prompt loop.
                if requests > 1 { return .denied }
                return await withCheckedContinuation { reply = $0; entered.fulfill() }
            }
            let permissions = SpeechAuthorization(client: .init(
                speechStatus: { requiresSpeech ? .notDetermined : .denied },
                microphoneStatus: { requiresSpeech ? .authorized : .notDetermined },
                requestSpeech: { await request() }, requestMicrophone: { await request() }))
            let first = Task { await permissions.request(requiresSpeechRecognition: requiresSpeech) }
            await fulfillment(of: [entered], timeout: 2)
            let second = Task { joined.fulfill(); return await permissions.request(requiresSpeechRecognition: requiresSpeech) }
            await fulfillment(of: [joined], timeout: 2)
            try XCTUnwrap(reply).resume(returning: .notDetermined)
            let firstAllowed = await first.value
            let secondAllowed = await second.value
            XCTAssertFalse(firstAllowed)
            XCTAssertFalse(secondAllowed)
            XCTAssertEqual(requests, 1, "Concurrent waiters share one attempt, including an inconclusive reply")
            let retry = await permissions.request(requiresSpeechRecognition: requiresSpeech)
            XCTAssertFalse(retry)
            XCTAssertEqual(requests, 2)
        }
    }

    @MainActor
    func testPermissionRefreshNotifiesSettingsAfterExternalAccessChange() async {
        var microphone = CapturePermission.denied
        let permissions = SpeechAuthorization(client: .init(
            speechStatus: { .authorized }, microphoneStatus: { microphone },
            requestSpeech: { .authorized }, requestMicrophone: { .authorized }))
        let updated = expectation(description: "Permission label changes")
        withObservationTracking { _ = permissions.summary } onChange: { updated.fulfill() }
        microphone = .authorized
        permissions.refresh()
        await fulfillment(of: [updated], timeout: 2)
        XCTAssertEqual(permissions.summary, "Microphone: Allowed · Speech: Allowed")
    }
}

private final class PermissionOnlyAudioSession: SpeechAudioSession, @unchecked Sendable {
    func start(lease: SpeechAudioLease) throws {}
    func stopAudio() {}
    func finishRecognition() {}
    func cancel() {}
}
