import AppKit
import Foundation
import XCTest
@testable import UIUI

/// Models clipboard consumption with strings only: no pasteboard, AX or keyboard events.
final class PastePayloadTests: XCTestCase {
    @MainActor
    func testQueuedPasteCannotReplaceFirstPayloadBeforeItIsConsumed() async throws {
        let gate = PastePayloadGate()
        let firstLease = await gate.acquire()
        var clipboard = "first payload"
        let second = Task { @MainActor in
            let lease = await gate.acquire()
            defer { gate.release(lease) }
            clipboard = "second payload"
            return clipboard
        }
        try await waitForQueue(gate, count: 1)
        // The first app reads later than dispatch. A queued paste must not have
        // replaced its payload while this first consumption lease remains active.
        let firstConsumed = clipboard
        XCTAssertEqual(firstConsumed, "first payload")
        gate.release(firstLease)
        let secondConsumed = await second.value
        XCTAssertEqual(secondConsumed, "second payload")
        XCTAssertEqual(firstConsumed, "first payload")
    }

    @MainActor
    func testQueuedPayloadsAreGrantedInFIFOOrder() async throws {
        let gate = PastePayloadGate()
        let initial = await gate.acquire()
        var order: [Int] = []
        let second = Task { @MainActor in
            let lease = await gate.acquire()
            order.append(2)
            gate.release(lease)
        }
        try await waitForQueue(gate, count: 1)
        let third = Task { @MainActor in
            let lease = await gate.acquire()
            order.append(3)
            gate.release(lease)
        }
        try await waitForQueue(gate, count: 2)
        XCTAssertTrue(order.isEmpty)
        gate.release(initial)
        await second.value
        await third.value
        XCTAssertEqual(order, [2, 3])
    }

    @MainActor
    func testStaleReleaseCannotExposeTheNextPayloadEarly() async throws {
        let gate = PastePayloadGate()
        let first = await gate.acquire()
        let second = Task { @MainActor in await gate.acquire() }
        try await waitForQueue(gate, count: 1)
        gate.release(first)
        let activeSecond = await second.value
        gate.release(first)
        let third = Task { @MainActor in await gate.acquire() }
        try await waitForQueue(gate, count: 1)
        gate.release(activeSecond)
        let activeThird = await third.value
        XCTAssertNotEqual(activeSecond, activeThird)
        gate.release(activeThird)
    }

    @MainActor
    private func waitForQueue(_ gate: PastePayloadGate, count: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while gate.waitingCount != count {
            guard clock.now < deadline else {
                XCTFail("Queued paste did not reach the expected lease boundary", file: file, line: line)
                throw QueueError.deadline
            }
            await Task.yield()
        }
    }
    private enum QueueError: Error { case deadline }
}

/// Calls the actual delivery owner with in-memory effects. No general or named
/// system pasteboard, Accessibility permission checks, or CGEvents are used.
final class ClipboardDeliveryTests: XCTestCase {
    @MainActor
    func testCompletedPasteLeavesDictationOnClipboardAfterConsumptionLease() async throws {
        let effects = ClipboardEffects()
        let gate = PastePayloadGate()
        let delivery = TextDelivery(dependencies: effects.dependencies, payloadGate: gate)
        assertPasteSent(await delivery.deliver("completed dictation", to: nil))
        XCTAssertEqual(effects.clipboard, "completed dictation")
        XCTAssertEqual(effects.postedPayloads, ["completed dictation"])
        try await waitUntil { effects.leaseWaiters.count == 1 }
        let barrier = Task { await delivery.deliver("cancelled barrier", to: nil) }
        try await waitUntil { gate.waitingCount == 1 }
        delivery.cancel()
        effects.finishLease()
        assertHeld(await barrier.value)
        XCTAssertEqual(effects.clipboard, "completed dictation")
        XCTAssertEqual(effects.writtenPayloads, ["completed dictation"])
    }

    @MainActor
    func testAutomaticPasteWritesTransientAndKeptCopiesDoNot() async {
        let sent = ClipboardEffects()
        assertPasteSent(await TextDelivery(dependencies: sent.dependencies).deliver("auto", to: nil))
        XCTAssertEqual(sent.writeKinds, ["transient"])

        let unavailable = ClipboardEffects()
        unavailable.unavailableReason = "No target"
        assertCopied(await TextDelivery(dependencies: unavailable.dependencies).deliver("manual", to: nil), reason: "No target")
        XCTAssertEqual(unavailable.writeKinds, ["persistent"])

        // Paste was attempted but fell through: the kept text becomes an ordinary copy.
        let vetoed = ClipboardEffects()
        vetoed.isValidAtDispatch = false
        assertCopied(await TextDelivery(dependencies: vetoed.dependencies).deliver("kept", to: nil))
        XCTAssertEqual(vetoed.writeKinds, ["transient", "persistent"])
        XCTAssertEqual(vetoed.clipboard, "kept")
    }

    @MainActor
    func testNativeTransientWriteAddsMarkersAndPlainWriteDoesNot() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("uiui-transient-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        guard ClipboardWriteTransaction.write("plain", using: .native(pasteboard)) else {
            throw XCTSkip("The isolated pasteboard service is unavailable in this test environment")
        }
        XCTAssertFalse(pasteboard.types?.contains(ClipboardMarker.transient) ?? false)
        XCTAssertTrue(ClipboardWriteTransaction.write("auto", transient: true, using: .native(pasteboard)))
        XCTAssertEqual(pasteboard.string(forType: .string), "auto")
        XCTAssertTrue(pasteboard.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) ?? false)
        XCTAssertTrue(pasteboard.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")) ?? false)
    }

    @MainActor
    func testUnavailableTargetOrPermissionCopiesWithoutPosting() async {
        for reason in ["No target", "Accessibility unavailable", "Destination changed", "Event unavailable"] {
            let effects = ClipboardEffects()
            effects.unavailableReason = reason
            let delivery = TextDelivery(dependencies: effects.dependencies)
            assertCopied(await delivery.deliver("keep this dictation", to: nil), reason: reason)
            XCTAssertEqual(effects.clipboard, "keep this dictation")
            XCTAssertTrue(effects.postedPayloads.isEmpty)
            XCTAssertTrue(effects.leaseWaiters.isEmpty)
        }
    }

    @MainActor
    func testFocusChangesAfterCopyLeavesTextCopiedWithoutPosting() async {
        let effects = ClipboardEffects()
        effects.isValidAtDispatch = false
        let delivery = TextDelivery(dependencies: effects.dependencies)
        assertCopied(await delivery.deliver("copy if focus changes", to: nil))
        XCTAssertEqual(effects.clipboard, "copy if focus changes")
        XCTAssertTrue(effects.postedPayloads.isEmpty)
    }

    @MainActor
    func testLaterDeliveryCannotReplacePostedPayloadUntilConsumptionLeaseEnds() async throws {
        let effects = ClipboardEffects()
        let gate = PastePayloadGate()
        let delivery = TextDelivery(dependencies: effects.dependencies, payloadGate: gate)
        assertPasteSent(await delivery.deliver("first dictation", to: nil))
        try await waitUntil { effects.leaseWaiters.count == 1 }
        // The later delivery has no target and must still wait before copying.
        effects.unavailableReason = "No destination for second dictation"
        let second = Task { await delivery.deliver("second dictation", to: nil) }
        try await waitUntil { gate.waitingCount == 1 }
        XCTAssertEqual(effects.clipboard, "first dictation")
        XCTAssertEqual(effects.writtenPayloads, ["first dictation"])
        XCTAssertEqual(effects.postedPayloads, ["first dictation"])
        effects.finishLease()
        assertCopied(await second.value)
        XCTAssertEqual(effects.clipboard, "second dictation")
        XCTAssertEqual(effects.writtenPayloads, ["first dictation", "second dictation"])
    }

    @MainActor
    func testNewerUserCopySurvivesLeaseCleanupAndQueuedGenerationCancellation() async throws {
        let effects = ClipboardEffects()
        let gate = PastePayloadGate()
        let delivery = TextDelivery(dependencies: effects.dependencies, payloadGate: gate)
        assertPasteSent(await delivery.deliver("posted dictation", to: nil))
        try await waitUntil { effects.leaseWaiters.count == 1 }
        let second = Task { await delivery.deliver("stale queued dictation", to: nil) }
        try await waitUntil { gate.waitingCount == 1 }
        delivery.cancel()
        effects.userCopy("new user copy")
        effects.finishLease()
        assertHeld(await second.value)
        XCTAssertEqual(effects.clipboard, "new user copy")
        XCTAssertEqual(effects.writtenPayloads, ["posted dictation"])
        XCTAssertEqual(effects.postedPayloads, ["posted dictation"])
    }

    @MainActor
    func testTaskCancelledWhileQueuedNeverCopiesOrPostsItsPayload() async throws {
        let effects = ClipboardEffects()
        let gate = PastePayloadGate()
        let delivery = TextDelivery(dependencies: effects.dependencies, payloadGate: gate)
        assertPasteSent(await delivery.deliver("first dictation", to: nil))
        try await waitUntil { effects.leaseWaiters.count == 1 }
        let second = Task { await delivery.deliver("cancelled queued dictation", to: nil) }
        try await waitUntil { gate.waitingCount == 1 }
        second.cancel()
        effects.finishLease()
        assertHeld(await second.value)
        XCTAssertEqual(effects.clipboard, "first dictation")
        XCTAssertEqual(effects.writtenPayloads, ["first dictation"])
        XCTAssertEqual(effects.postedPayloads, ["first dictation"])
    }

    @MainActor
    func testEmptyTextAndClipboardWriteFailureNeverPostPaste() async {
        let effects = ClipboardEffects()
        let delivery = TextDelivery(dependencies: effects.dependencies)
        assertHeld(await delivery.deliver("", to: nil))
        XCTAssertEqual(effects.clipboard, "previous clipboard")
        XCTAssertTrue(effects.writtenPayloads.isEmpty)
        effects.acceptsWrites = false
        assertHeld(await delivery.deliver("cannot copy", to: nil))
        XCTAssertTrue(effects.postedPayloads.isEmpty)
    }

    @MainActor
    func testHeldModifiersDelayExactlyOnePasteUntilReleased() async throws {
        let effects = ClipboardEffects()
        effects.blocksOnModifiers = true
        let delivery = TextDelivery(dependencies: effects.dependencies)
        let pending = Task { await delivery.deliver("wait for shortcut release", to: nil) }
        try await waitUntil { effects.modifierWaiters.count == 1 }
        XCTAssertEqual(effects.clipboard, "wait for shortcut release")
        XCTAssertTrue(effects.postedPayloads.isEmpty)
        effects.finishModifiers(released: true)
        assertPasteSent(await pending.value)
        XCTAssertEqual(effects.postedPayloads, ["wait for shortcut release"])
        try await waitUntil { effects.leaseWaiters.count == 1 }
        effects.finishLease()
    }

    @MainActor
    func testModifierTimeoutReturnsCopyReasonWithoutPosting() async throws {
        let effects = ClipboardEffects()
        effects.blocksOnModifiers = true
        let delivery = TextDelivery(dependencies: effects.dependencies)
        let pending = Task { await delivery.deliver("copy on timeout", to: nil) }
        try await waitUntil { effects.modifierWaiters.count == 1 }
        effects.finishModifiers(released: false)
        let result = await pending.value
        guard case .copied(let reason) = result else { return XCTFail("Expected copied dictation after modifier timeout") }
        XCTAssertTrue(reason.contains("still held"))
        XCTAssertEqual(effects.clipboard, "copy on timeout")
        XCTAssertTrue(effects.postedPayloads.isEmpty)
        XCTAssertTrue(effects.leaseWaiters.isEmpty)
    }

    @MainActor
    func testGenerationCancellationDuringModifierWaitNeverPosts() async throws {
        let effects = ClipboardEffects()
        effects.blocksOnModifiers = true
        let delivery = TextDelivery(dependencies: effects.dependencies)
        let pending = Task { await delivery.deliver("cancel while waiting", to: nil) }
        try await waitUntil { effects.modifierWaiters.count == 1 }
        delivery.cancel()
        effects.finishModifiers(released: true)
        assertHeld(await pending.value)
        XCTAssertTrue(effects.postedPayloads.isEmpty)
        XCTAssertEqual(effects.clipboard, "cancel while waiting")
    }

    @MainActor
    func testTaskCancellationDuringModifierWaitNeverPosts() async throws {
        let effects = ClipboardEffects()
        effects.blocksOnModifiers = true
        let delivery = TextDelivery(dependencies: effects.dependencies)
        let pending = Task { await delivery.deliver("cancel task while waiting", to: nil) }
        try await waitUntil { effects.modifierWaiters.count == 1 }
        pending.cancel()
        effects.finishModifiers(released: true)
        assertHeld(await pending.value)
        XCTAssertTrue(effects.postedPayloads.isEmpty)
    }

    @MainActor
    func testForegroundChangeDuringModifierWaitLeavesDictationCopied() async throws {
        let effects = ClipboardEffects()
        effects.blocksOnModifiers = true
        let delivery = TextDelivery(dependencies: effects.dependencies)
        let pending = Task { await delivery.deliver("changed destination", to: nil) }
        try await waitUntil { effects.modifierWaiters.count == 1 }
        effects.isValidAtDispatch = false
        effects.finishModifiers(released: true)
        assertCopied(await pending.value)
        XCTAssertTrue(effects.postedPayloads.isEmpty)
        XCTAssertEqual(effects.clipboard, "changed destination")
    }

    @MainActor
    func testFinalForegroundOrModifierRecheckCanVetoPreparedPaste() async {
        let effects = ClipboardEffects()
        effects.canDispatch = false
        let delivery = TextDelivery(dependencies: effects.dependencies)
        assertCopied(await delivery.deliver("final check changed", to: nil))
        XCTAssertEqual(effects.clipboard, "final check changed")
        XCTAssertTrue(effects.postedPayloads.isEmpty)
        XCTAssertTrue(effects.leaseWaiters.isEmpty)
    }

    @MainActor
    func testNewerClipboardDuringModifierWaitIsNeverPastedOrOverwritten() async throws {
        let effects = ClipboardEffects()
        effects.blocksOnModifiers = true
        let delivery = TextDelivery(dependencies: effects.dependencies)
        let pending = Task { await delivery.deliver("dictation", to: nil) }
        try await waitUntil { effects.modifierWaiters.count == 1 }
        effects.userCopy("newer user payload")
        effects.finishModifiers(released: true)
        assertHeld(await pending.value)
        XCTAssertEqual(effects.clipboard, "newer user payload")
        XCTAssertTrue(effects.postedPayloads.isEmpty)
    }

    @MainActor
    func testNewerClipboardDuringWriteCannotBeMistakenForOurReceipt() async {
        let effects = ClipboardEffects()
        effects.copyDuringWrite = true
        let delivery = TextDelivery(dependencies: effects.dependencies)
        assertHeld(await delivery.deliver("dictation", to: nil))
        XCTAssertEqual(effects.clipboard, "newer user payload")
        XCTAssertTrue(effects.postedPayloads.isEmpty)
    }

    @MainActor
    func testUnavailableDestinationCannotClaimDictationCopiedAfterNewerCopyWins() async {
        let effects = ClipboardEffects()
        effects.unavailableReason = "Destination changed"
        effects.copyDuringWrite = true
        let delivery = TextDelivery(dependencies: effects.dependencies)
        assertHeld(await delivery.deliver("dictation", to: nil))
        XCTAssertEqual(effects.clipboard, "newer user payload")
        XCTAssertEqual(effects.writtenPayloads, ["dictation"])
        XCTAssertTrue(effects.postedPayloads.isEmpty)
        XCTAssertTrue(effects.leaseWaiters.isEmpty)
    }

    @MainActor
    func testClipboardChangeDuringDestinationVetoIsReportedAsHeld() async {
        let effects = ClipboardEffects()
        effects.isValidAtDispatch = false
        effects.onValidate = { [weak effects] in effects?.userCopy("newer user payload") }
        let delivery = TextDelivery(dependencies: effects.dependencies)
        assertHeld(await delivery.deliver("dictation", to: nil))
        XCTAssertEqual(effects.clipboard, "newer user payload")
        XCTAssertTrue(effects.postedPayloads.isEmpty)
        XCTAssertTrue(effects.leaseWaiters.isEmpty)
    }

    @MainActor
    func testClipboardChangeDuringFinalDispatchVetoIsReportedAsHeld() async {
        let effects = ClipboardEffects()
        effects.canDispatch = false
        effects.onCanDispatch = { [weak effects] in effects?.userCopy("newer user payload") }
        let delivery = TextDelivery(dependencies: effects.dependencies)
        assertHeld(await delivery.deliver("dictation", to: nil))
        XCTAssertEqual(effects.clipboard, "newer user payload")
        XCTAssertTrue(effects.postedPayloads.isEmpty)
        XCTAssertTrue(effects.leaseWaiters.isEmpty)
    }

    @MainActor
    func testClipboardChangeDuringDispatchCountReadNeverPostsOtherPayload() async {
        let effects = ClipboardEffects()
        effects.copyOnSecondCountRead = true
        let delivery = TextDelivery(dependencies: effects.dependencies)
        assertHeld(await delivery.deliver("dictation", to: nil))
        XCTAssertEqual(effects.clipboard, "newer user payload")
        XCTAssertTrue(effects.postedPayloads.isEmpty)
    }

    private func assertPasteSent(_ result: DeliveryResult, file: StaticString = #filePath, line: UInt = #line) {
        guard case .pasteSent = result else { return XCTFail("Expected dispatched paste", file: file, line: line) }
    }
    private func assertCopied(_ result: DeliveryResult, reason: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        guard case .copied(let actualReason) = result else { return XCTFail("Expected copy-only delivery", file: file, line: line) }
        XCTAssertFalse(actualReason.isEmpty, file: file, line: line)
        if let reason { XCTAssertEqual(actualReason, reason, file: file, line: line) }
    }
    private func assertHeld(_ result: DeliveryResult, file: StaticString = #filePath, line: UInt = #line) {
        guard case .held = result else { return XCTFail("Expected held delivery", file: file, line: line) }
    }
    @MainActor
    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("Delivery did not reach the expected lease boundary", file: file, line: line)
                throw LeaseError.deadline
            }
            await Task.yield()
        }
    }
    private enum LeaseError: Error { case deadline }
}

@MainActor
private final class ClipboardEffects {
    var clipboard = "previous clipboard"
    var changeCount = 0
    var unavailableReason: String?
    var isValidAtDispatch = true
    var canDispatch = true
    var onValidate: (() -> Void)?
    var onCanDispatch: (() -> Void)?
    var acceptsWrites = true
    var blocksOnModifiers = false
    var copyDuringWrite = false
    var copyOnSecondCountRead = false
    var countReadCount = 0
    var modifierWaiters: [CheckedContinuation<Bool, Never>] = []
    var writtenPayloads: [String] = []
    var postedPayloads: [String] = []
    var leaseWaiters: [CheckedContinuation<Void, Never>] = []

    /// "transient" or "persistent", one entry per clipboard write.
    var writeKinds: [String] = []

    var dependencies: TextDeliveryDependencies {
        TextDeliveryDependencies(
            writeClipboard: { [self] text in
                writeKinds.append("persistent")
                return write(text)
            },
            writeTransientClipboard: { [self] text in
                writeKinds.append("transient")
                return write(text)
            },
            clipboardChangeCount: { [self] in
                countReadCount += 1
                let sampledCount = changeCount
                if copyOnSecondCountRead, countReadCount == 2 { userCopy("newer user payload") }
                return sampledCount
            },
            preparePaste: { [self] _ in
                if let unavailableReason { return .unavailable(unavailableReason) }
                return .ready(.init(validate: { [self] in onValidate?(); return isValidAtDispatch },
                                    post: { [self] in postedPayloads.append(clipboard) },
                                    canDispatch: { [self] in onCanDispatch?(); return canDispatch }))
            },
            waitForPasteConsumption: { [self] in
                await withCheckedContinuation { leaseWaiters.append($0) }
            },
            waitForModifiersReleased: { [self] in
                guard blocksOnModifiers else { return true }
                return await withCheckedContinuation { modifierWaiters.append($0) }
            },
            clipboardMatches: { [self] in clipboard == $0 }
        )
    }
    private func write(_ text: String) -> Bool {
        guard acceptsWrites else { return false }
        clipboard = text
        changeCount += 1
        writtenPayloads.append(text)
        if copyDuringWrite { userCopy("newer user payload") }
        return true
    }
    func userCopy(_ text: String) { clipboard = text; changeCount += 1 }
    func finishLease() { leaseWaiters.removeFirst().resume() }
    func finishModifiers(released: Bool) { modifierWaiters.removeFirst().resume(returning: released) }
}

final class ClipboardWriteTransactionTests: XCTestCase {
    @MainActor
    func testClearThenFailedStringWriteRestoresEveryOriginalItemAndFormat() async {
        let board = TransactionalClipboardEffects()
        let originalData = board.materializedData
        let delivery = TextDelivery(dependencies: board.deliveryDependencies)
        guard case .held = await delivery.deliver("new dictation", to: nil) else {
            return XCTFail("A failed clipboard write must hold the dictation")
        }
        XCTAssertEqual(board.materializedData, originalData)
        XCTAssertEqual(board.events, ["snapshot", "clear", "writeString", "clear", "restore"])
    }

    @MainActor
    func testFailedWriteNeverRestoresOverNewerUserCopy() {
        let board = TransactionalClipboardEffects()
        board.copyDuringFailedWrite = true
        XCTAssertFalse(ClipboardWriteTransaction.write("dictation", using: board.operations))
        XCTAssertEqual(board.items.first?.string(forType: .string), "newer user copy")
        XCTAssertEqual(board.events, ["snapshot", "clear", "writeString", "userCopy"])
    }

    @MainActor
    func testUnmaterializableOldFormatDoesNotPreventDeliberateTextCopy() {
        let board = TransactionalClipboardEffects()
        board.canMaterialize = false
        board.stringWriteSucceeds = true
        XCTAssertTrue(ClipboardWriteTransaction.write("completed dictation", using: board.operations))
        XCTAssertEqual(board.items.first?.string(forType: .string), "completed dictation")
        XCTAssertEqual(board.events, ["snapshot", "clear", "writeString"])
    }

    @MainActor
    func testFailedCopyWithoutMaterializedSnapshotDoesNotPromiseRestoration() {
        let board = TransactionalClipboardEffects()
        board.canMaterialize = false
        XCTAssertFalse(ClipboardWriteTransaction.write("dictation", using: board.operations))
        XCTAssertTrue(board.items.isEmpty)
        XCTAssertEqual(board.events, ["snapshot", "clear", "writeString"])
    }

    @MainActor
    func testClipboardChangesWhileSnapshotMaterializesNeverClearsNewerCopy() {
        let board = TransactionalClipboardEffects()
        board.copyDuringSnapshot = true
        XCTAssertFalse(ClipboardWriteTransaction.write("dictation", using: board.operations))
        XCTAssertEqual(board.items.first?.string(forType: .string), "newer user copy")
        XCTAssertEqual(board.events, ["snapshot", "userCopy"])
    }

    @MainActor
    func testSuccessfulWriteLeavesDictationAndNeverRestoresSnapshot() {
        let board = TransactionalClipboardEffects()
        board.stringWriteSucceeds = true
        XCTAssertTrue(ClipboardWriteTransaction.write("completed dictation", using: board.operations))
        XCTAssertEqual(board.items.count, 1)
        XCTAssertEqual(board.items.first?.string(forType: .string), "completed dictation")
        XCTAssertEqual(board.events, ["snapshot", "clear", "writeString"])
    }

    @MainActor
    func testNativeCopyDoesNotRequestPromisedOldClipboardData() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("uiui-lazy-copy-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let provider = UnavailableClipboardDataProvider()
        let lazyItem = NSPasteboardItem()
        lazyItem.setDataProvider(provider, forTypes: [NSPasteboard.PasteboardType("uiui.unavailable.lazy")])
        guard pasteboard.writeObjects([lazyItem]) else {
            throw XCTSkip("The isolated pasteboard service is unavailable in this test environment")
        }
        XCTAssertTrue(ClipboardWriteTransaction.write("completed dictation", using: .native(pasteboard)))
        XCTAssertEqual(pasteboard.string(forType: .string), "completed dictation")
        XCTAssertEqual(provider.requestCount, 0, "Copy must not invoke the previous owner's promised data provider")
    }

    @MainActor
    func testNewerCopyDuringRecoveryClearPreventsSnapshotWrite() {
        let board = TransactionalClipboardEffects()
        board.copyDuringRecoveryClear = true
        XCTAssertFalse(ClipboardWriteTransaction.write("dictation", using: board.operations))
        XCTAssertEqual(board.items.first?.string(forType: .string), "newer user copy")
        XCTAssertEqual(board.events, ["snapshot", "clear", "writeString", "clear", "userCopy"])
    }
}

@MainActor
private final class TransactionalClipboardEffects {
    private(set) var items: [NSPasteboardItem] = {
        let first = NSPasteboardItem()
        first.setString("original text", forType: .string)
        first.setData(Data([0x01, 0x02, 0x03]), forType: .rtf)
        let second = NSPasteboardItem()
        second.setData(Data([0x04, 0x05]), forType: NSPasteboard.PasteboardType("example.custom"))
        return [first, second]
    }()
    private(set) var changeCount = 1
    private(set) var events: [String] = []
    private var clearCount = 0
    var canMaterialize = true
    var stringWriteSucceeds = false
    var copyDuringFailedWrite = false
    var copyDuringSnapshot = false
    var copyDuringRecoveryClear = false

    var materializedData: [[String: Data]] {
        items.map { item in Dictionary(uniqueKeysWithValues: item.types.map { ($0.rawValue, item.data(forType: $0)!) }) }
    }
    var operations: ClipboardWriteOperations {
        ClipboardWriteOperations(
            changeCount: { [self] in changeCount },
            readItems: { [self] in
                events.append("snapshot")
                let snapshot = items
                if copyDuringSnapshot { userCopy() }
                return canMaterialize ? snapshot : nil
            },
            clearContents: { [self] in
                events.append("clear")
                items = []
                changeCount += 1
                clearCount += 1
                let ownChangeCount = changeCount
                if clearCount == 2, copyDuringRecoveryClear { userCopy() }
                return ownChangeCount
            },
            writeString: { [self] text in
                events.append("writeString")
                guard stringWriteSucceeds else {
                    if copyDuringFailedWrite { userCopy() }
                    return false
                }
                let item = NSPasteboardItem()
                item.setString(text, forType: .string)
                items = [item]
                changeCount += 1
                return true
            },
            writeItems: { [self] original in
                events.append("restore")
                items = original
                changeCount += 1
                return true
            }
        )
    }
    var deliveryDependencies: TextDeliveryDependencies {
        TextDeliveryDependencies(
            writeClipboard: { [self] in ClipboardWriteTransaction.write($0, using: operations) },
            clipboardChangeCount: { [self] in changeCount },
            preparePaste: { _ in .unavailable("No test target") },
            waitForPasteConsumption: { XCTFail("A failed write must never dispatch or acquire a consumption lease") }
        )
    }
    private func userCopy() {
        events.append("userCopy")
        let item = NSPasteboardItem()
        item.setString("newer user copy", forType: .string)
        items = [item]
        changeCount += 1
    }
}

/// A promised format whose provider cannot supply data. This object touches only
/// the unique named pasteboard created by its test, never the user's clipboard.
private final class UnavailableClipboardDataProvider: NSObject, NSPasteboardItemDataProvider {
    private(set) var requestCount = 0
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        requestCount += 1
    }
}
