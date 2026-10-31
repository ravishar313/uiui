import Foundation
import XCTest
@testable import UIUI

@MainActor
final class LegacyReminderCleanupTests: XCTestCase {
    func testRemovesExactLegacyAndTokenIdentifiersWithoutCrossingUUIDBoundary() async {
        let id = UUID()
        let prefix = "uiui.reminder.\(id.uuidString)"
        let otherReminder = "uiui.reminder.\(UUID().uuidString).token"
        let neighbors = [prefix + "extra", "other." + prefix, otherReminder, "unrelated"]
        let pendingMatches = [prefix, prefix + ".first-token", prefix + ".second-token"]
        let deliveredMatches = [prefix, prefix + ".delivered-token"]
        let client = LegacyReminderNotificationFixture(pending: pendingMatches + neighbors, delivered: deliveredMatches + neighbors)
        await LegacyReminderCleanup.remove(id: id, client: client)
        XCTAssertEqual(client.removedPending, pendingMatches)
        XCTAssertEqual(client.removedDelivered, deliveredMatches)
        XCTAssertEqual(client.pending, neighbors)
        XCTAssertEqual(client.delivered, neighbors)
    }

    func testNoMatchingRequestDoesNotIssueRemovalCalls() async {
        let client = LegacyReminderNotificationFixture(pending: ["unrelated"], delivered: ["uiui.reminder.\(UUID()).token"])
        await LegacyReminderCleanup.remove(id: UUID(), client: client)
        XCTAssertTrue(client.removedPending.isEmpty)
        XCTAssertTrue(client.removedDelivered.isEmpty)
        XCTAssertEqual(client.removalCalls, 0)
    }
}

@MainActor
private final class LegacyReminderNotificationFixture: LegacyReminderNotificationClient {
    var pending: [String]
    var delivered: [String]
    var removedPending: [String] = []
    var removedDelivered: [String] = []
    var removalCalls = 0
    init(pending: [String], delivered: [String]) { self.pending = pending; self.delivered = delivered }
    func pendingIdentifiers() async -> [String] { pending }
    func deliveredIdentifiers() async -> [String] { delivered }
    func removePending(identifiers: [String]) {
        removalCalls += 1
        removedPending += identifiers
        pending.removeAll { identifiers.contains($0) }
    }
    func removeDelivered(identifiers: [String]) {
        removalCalls += 1
        removedDelivered += identifiers
        delivered.removeAll { identifiers.contains($0) }
    }
}
