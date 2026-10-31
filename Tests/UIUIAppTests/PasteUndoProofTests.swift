import AppKit
import XCTest
@testable import UIUI

/// Undo after paste is offered and sent only with positive evidence. Everything here
/// uses fake probes: no Accessibility, no keyboard or mouse counters, no real paste.
private let testPID: pid_t = 4242

@MainActor
final class PasteUndoProofTests: XCTestCase {
    private func field(_ element: Int = 1, length: Int = 100, location: Int = 10, selected: Int = 0,
                       contains: Bool? = nil, pid: pid_t = testPID) -> PasteFocusSnapshot {
        PasteFocusSnapshot(element: element, pid: pid, valueLength: length, selectedLocation: location, selectedLength: selected, containsPasted: contains)
    }

    /// A mutable world the probes read.
    private final class World {
        var now: TimeInterval = 1_000
        var ages = PasteUndoPolicy.InputAges(key: 50, mouse: 50)
        var front: pid_t? = testPID
        var after: PasteFocusSnapshot?
        var current: PasteFocusSnapshot?
        var snapshotReads = 0
        var probes: PasteUndoProbes {
            PasteUndoProbes(uptime: { self.now }, inputAges: { self.ages }, frontmostPID: { self.front },
                            snapshot: { checking in self.snapshotReads += 1; return checking ? self.after : self.current },
                            sleep: { self.now += $0 })
        }
    }

    /// A pasted 12-character string landed at offset 10 of a 100-character field.
    private func verifiedProof(world: World = World()) async -> (PasteUndoProof, World) {
        let landed = field(length: 112, location: 22, contains: true)
        world.after = landed
        world.current = field(length: 112, location: 22)
        let proof = PasteUndoProof(probes: world.probes, targetPID: testPID, before: field(length: 100, location: 10), pastedLength: 12)
        proof.markPosted()
        await proof.verify()
        return (proof, world)
    }

    // MARK: Pure policy

    func testInsertionIsVerifiedOnlyWhenTheFieldGrewByExactlyThePastedText() {
        let before = field(length: 100, location: 10)
        XCTAssertTrue(PasteUndoPolicy.insertionVerified(before: before, after: field(length: 112, contains: true), pastedLength: 12))
        XCTAssertFalse(PasteUndoPolicy.insertionVerified(before: before, after: field(length: 100, contains: true), pastedLength: 12), "Unchanged")
        XCTAssertFalse(PasteUndoPolicy.insertionVerified(before: before, after: field(length: 113, contains: true), pastedLength: 12), "Something else changed too")
        XCTAssertFalse(PasteUndoPolicy.insertionVerified(before: before, after: field(length: 112, contains: false), pastedLength: 12))
        XCTAssertFalse(PasteUndoPolicy.insertionVerified(before: before, after: field(2, length: 112, contains: true), pastedLength: 12), "Another element")
        XCTAssertFalse(PasteUndoPolicy.insertionVerified(before: nil, after: field(length: 112, contains: true), pastedLength: 12))
        XCTAssertFalse(PasteUndoPolicy.insertionVerified(before: before, after: nil, pastedLength: 12))
        var unreadable = field(length: 112, contains: true); unreadable.valueLength = nil
        XCTAssertFalse(PasteUndoPolicy.insertionVerified(before: before, after: unreadable, pastedLength: 12))
    }

    func testReplacingASelectionIsAccountedFor() {
        let before = field(length: 100, location: 10, selected: 5)
        XCTAssertTrue(PasteUndoPolicy.insertionVerified(before: before, after: field(length: 107, contains: true), pastedLength: 12))
        XCTAssertFalse(PasteUndoPolicy.insertionVerified(before: before, after: field(length: 112, contains: true), pastedLength: 12))
    }

    func testKeyAndMouseRules() {
        // Our own Command-V registers at the paste, so its age tracks the time since.
        XCTAssertFalse(PasteUndoPolicy.keyPressedSince(keyAge: 2.0, elapsed: 2.0))
        XCTAssertFalse(PasteUndoPolicy.keyPressedSince(keyAge: 9.0, elapsed: 2.0), "Older key presses are before the paste")
        XCTAssertTrue(PasteUndoPolicy.keyPressedSince(keyAge: 0.8, elapsed: 2.0), "A key went down 0.8 s ago, after the paste")
        XCTAssertFalse(PasteUndoPolicy.mouseDownSince(baselineAge: 30, nowAge: 32, elapsed: 2, mayBeOwnClick: false))
        XCTAssertTrue(PasteUndoPolicy.mouseDownSince(baselineAge: 30, nowAge: 1.5, elapsed: 2, mayBeOwnClick: false))
        XCTAssertFalse(PasteUndoPolicy.mouseDownSince(baselineAge: 30, nowAge: 0.4, elapsed: 2, mayBeOwnClick: true), "The click on Undo itself")
        XCTAssertTrue(PasteUndoPolicy.mouseDownSince(baselineAge: 30, nowAge: 4, elapsed: 20, mayBeOwnClick: true), "A click long before Undo is not Undo's own")
    }

    // MARK: Proof

    func testVerifiedUntouchedPasteIsSafeToUndo() async {
        let (proof, world) = await verifiedProof()
        world.now += 2
        world.ages = .init(key: 52, mouse: 52)
        XCTAssertEqual(proof.insertion, .verified)
        XCTAssertTrue(proof.isSafeToUndo(invokedByClick: false))
    }

    func testUnverifiedInsertionIsNeverSafe() async {
        let world = World()
        world.after = field(length: 100, location: 10, contains: false) // The paste did not land.
        let proof = PasteUndoProof(probes: world.probes, targetPID: testPID, before: field(length: 100, location: 10), pastedLength: 12)
        proof.markPosted()
        await proof.verify()
        XCTAssertEqual(proof.insertion, .unverified)
        world.current = field(length: 100, location: 10)
        XCTAssertFalse(proof.isSafeToUndo(invokedByClick: true))
    }

    func testUnreadableFieldIsUnverifiedNotAssumed() async {
        let world = World()
        world.after = nil // Accessibility could not read the field.
        let proof = PasteUndoProof(probes: world.probes, targetPID: testPID, before: nil, pastedLength: 12)
        proof.markPosted()
        await proof.verify()
        XCTAssertEqual(proof.insertion, .unverified)
        XCTAssertFalse(proof.isSafeToUndo(invokedByClick: false))
    }

    func testSlowInsertionIsRetriedAFewTimesThenGivenUp() async {
        let world = World()
        world.after = field(length: 100, location: 10, contains: false)
        let proof = PasteUndoProof(probes: world.probes, targetPID: testPID, before: field(length: 100, location: 10), pastedLength: 12)
        proof.markPosted()
        await proof.verify()
        XCTAssertEqual(world.snapshotReads, 3, "Bounded: three reads, no polling loop")
        XCTAssertEqual(proof.insertion, .unverified)
    }

    func testAnyChangeSinceThePasteWithdrawsUndo() async {
        func scenario(_ change: (World) -> Void, click: Bool = false, file: StaticString = #filePath, line: UInt = #line) async -> Bool {
            let (proof, world) = await verifiedProof()
            world.now += 2
            world.ages = .init(key: 52, mouse: 52)
            change(world)
            return proof.isSafeToUndo(invokedByClick: click)
        }
        let untouched = await scenario { _ in }
        XCTAssertTrue(untouched)
        let otherApp = await scenario { $0.front = 99 }
        XCTAssertFalse(otherApp, "Another app is in front")
        let otherElement = await scenario { $0.current = self.field(2, length: 112, location: 22) }
        XCTAssertFalse(otherElement, "Focus moved to another field")
        let typed = await scenario { $0.current = self.field(length: 113, location: 23) }
        XCTAssertFalse(typed, "Text changed")
        let caretMoved = await scenario { $0.current = self.field(length: 112, location: 5) }
        XCTAssertFalse(caretMoved, "Selection moved")
        let key = await scenario { $0.ages.key = 0.6 }
        XCTAssertFalse(key, "A key went down after the paste")
        let mouse = await scenario { $0.ages.mouse = 1.2 }
        XCTAssertFalse(mouse, "A mouse-down after the paste")
        let unreadable = await scenario { $0.current = nil }
        XCTAssertFalse(unreadable, "Cannot read the field now: unsure means no")
        let ownClick = await scenario({ $0.ages.mouse = 0.3 }, click: true)
        XCTAssertTrue(ownClick, "The click on the Undo button itself does not count")
        let ownClickWithMovedCaret = await scenario({ $0.ages.mouse = 0.3; $0.current = self.field(length: 112, location: 5) }, click: true)
        XCTAssertFalse(ownClickWithMovedCaret)
    }

    func testCheapChecksRunBeforeAnyAccessibilityRead() async {
        let (proof, world) = await verifiedProof()
        world.now += 2
        world.ages = .init(key: 0.1, mouse: 52)
        let reads = world.snapshotReads
        XCTAssertFalse(proof.isSafeToUndo(invokedByClick: false))
        XCTAssertEqual(world.snapshotReads, reads, "A key press already decided it")
    }

    // MARK: Delivery and model

    func testDeliveryHoldsTheProofForTheLastPasteAndDropsItOnTheNext() async {
        let world = World()
        world.after = field(length: 112, location: 22, contains: true)
        world.current = field(length: 112, location: 22)
        var proofs: [PasteUndoProof] = []
        var clipboard = ""
        var changes = 0
        let dependencies = TextDeliveryDependencies(
            writeClipboard: { clipboard = $0; changes += 1; return true },
            clipboardChangeCount: { changes },
            preparePaste: { _ in
                .ready(.init(validate: { true }, post: {}, beginUndoProof: { pasted in
                    let proof = PasteUndoProof(probes: world.probes, targetPID: testPID, before: self.field(length: 100, location: 10),
                                               pastedLength: (pasted as NSString).length)
                    proofs.append(proof)
                    return proof
                }))
            },
            waitForPasteConsumption: {},
            clipboardMatches: { $0 == clipboard })
        let delivery = TextDelivery(dependencies: dependencies)
        let result = await delivery.deliver("twelve chars", to: nil)
        guard case .pasteSent = result else { return XCTFail("Expected a sent paste") }
        XCTAssertTrue(delivery.pasteUndoProof() === proofs.first)
        for _ in 0..<500 where proofs.first?.insertion == .pending { await Task.yield() }
        XCTAssertEqual(proofs.first?.insertion, .verified, "Insertion is confirmed after the lease is free")
        _ = await delivery.deliver("other text!!", to: nil)
        XCTAssertFalse(delivery.pasteUndoProof() === proofs.first, "A newer paste replaces the evidence")
    }

    private func makeModel() async throws -> (AppModel, UndoRecordingDelivery) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("uiui-undo-\(UUID().uuidString)")
        let suite = "uiui-undo-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let delivery = UndoRecordingDelivery()
        let model = AppModel(dataDirectory: root, defaults: defaults, persistSettings: false, delivery: delivery)
        await model.start(installSystemServices: false)
        addTeardownBlock {
            await MainActor.run { model.shutdown() }
            try? FileManager.default.removeItem(at: root)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        return (model, delivery)
    }

    func testNoProofMeansNoUndoOffer() async throws {
        let (model, delivery) = try await makeModel()
        let target = DeliveryTarget(application: .current)
        model.frontmostApplicationPID = { target.appPID }
        model.notchExtras.offerUndo(captureID: model.dictationCaptureGeneration, target: target, proof: nil)
        XCTAssertNil(model.notchExtras.undoOffer)
        XCTAssertFalse(model.notchUndoAvailable)
        model.undoLastPaste()
        XCTAssertEqual(delivery.undoCount, 0, "Copy only: Command-Z is never sent when unsure")
    }

    func testUndoIsOfferedAndSentOnlyWhileTheProofHolds() async throws {
        let (model, delivery) = try await makeModel()
        let target = DeliveryTarget(application: .current)
        model.frontmostApplicationPID = { target.appPID }
        let world = World()
        world.front = target.appPID
        let landed = field(length: 112, location: 22, contains: true)
        world.after = landed
        world.current = field(length: 112, location: 22)
        let proof = PasteUndoProof(probes: world.probes, targetPID: target.appPID, before: field(length: 100, location: 10, pid: target.appPID), pastedLength: 12)
        proof.markPosted()
        model.notchExtras.offerUndo(captureID: model.dictationCaptureGeneration, target: target, proof: proof)
        XCTAssertFalse(model.notchUndoAvailable, "Insertion not confirmed yet")
        world.after?.pid = target.appPID; world.current?.pid = target.appPID
        await proof.verify()
        world.now += 1
        world.ages = .init(key: 51, mouse: 51)
        XCTAssertTrue(model.notchUndoAvailable)
        // The person types in the field: the offer is withdrawn and Undo sends nothing.
        world.current = field(length: 113, location: 23, pid: target.appPID)
        XCTAssertFalse(model.notchUndoAvailable)
        model.undoLastPaste()
        XCTAssertEqual(delivery.undoCount, 0)
        XCTAssertEqual(model.dictationFeedback?.title, "Undo unavailable")
    }

    func testUndoSendsExactlyOnceWhenEverythingHolds() async throws {
        let (model, delivery) = try await makeModel()
        let target = DeliveryTarget(application: .current)
        model.frontmostApplicationPID = { target.appPID }
        let world = World()
        world.front = target.appPID
        world.after = field(length: 112, location: 22, contains: true, pid: target.appPID)
        world.current = field(length: 112, location: 22, pid: target.appPID)
        let proof = PasteUndoProof(probes: world.probes, targetPID: target.appPID, before: field(length: 100, location: 10, pid: target.appPID), pastedLength: 12)
        proof.markPosted()
        await proof.verify()
        world.now += 1
        world.ages = .init(key: 51, mouse: 51)
        model.notchExtras.offerUndo(captureID: model.dictationCaptureGeneration, target: target, proof: proof)
        model.undoLastPaste()
        XCTAssertEqual(delivery.undoCount, 1)
        model.undoLastPaste()
        XCTAssertEqual(delivery.undoCount, 1, "The offer is consumed")
    }
}

@MainActor
private final class UndoRecordingDelivery: TextDelivering {
    private(set) var undoCount = 0
    func deliver(_ text: String, to target: DeliveryTarget?) async -> DeliveryResult { .held("Synthetic") }
    func cancel() {}
    func undoPaste(to target: DeliveryTarget, proof: PasteUndoProof, invokedByClick: Bool) -> Bool { undoCount += 1; return true }
}
