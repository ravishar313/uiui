import Foundation
import UserNotifications

/// Compatibility for reminders scheduled by older uiui versions. This adapter
/// only removes an explicitly deleted record's notifications; it never schedules
/// or reconciles requests and never asks for notification permission.
@MainActor
protocol LegacyReminderNotificationClient {
    func pendingIdentifiers() async -> [String]
    func deliveredIdentifiers() async -> [String]
    func removePending(identifiers: [String])
    func removeDelivered(identifiers: [String])
}

@MainActor
enum LegacyReminderCleanup {
    static func remove(id: UUID) async {
        // Construction is deferred until the user deletes a legacy reminder in
        // a production lifecycle. Starting the app never opens this OS service.
        await remove(id: id, client: SystemLegacyReminderNotificationClient())
    }

    static func remove(id: UUID, client: any LegacyReminderNotificationClient) async {
        let prefix = "uiui.reminder.\(id.uuidString)"
        let pending = await client.pendingIdentifiers().filter { matches($0, prefix: prefix) }
        let delivered = await client.deliveredIdentifiers().filter { matches($0, prefix: prefix) }
        if !pending.isEmpty { client.removePending(identifiers: pending) }
        if !delivered.isEmpty { client.removeDelivered(identifiers: delivered) }
    }

    private static func matches(_ identifier: String, prefix: String) -> Bool {
        identifier == prefix || identifier.hasPrefix(prefix + ".")
    }
}

@MainActor
private final class SystemLegacyReminderNotificationClient: LegacyReminderNotificationClient {
    private let center = UNUserNotificationCenter.current()
    func pendingIdentifiers() async -> [String] {
        await center.pendingNotificationRequests().map(\.identifier)
    }
    func deliveredIdentifiers() async -> [String] {
        await center.deliveredNotifications().map { $0.request.identifier }
    }
    func removePending(identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
    func removeDelivered(identifiers: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}
