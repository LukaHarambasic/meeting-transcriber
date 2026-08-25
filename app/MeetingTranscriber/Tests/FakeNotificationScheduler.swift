import Foundation
@testable import MeetingTranscriber
import UserNotifications

/// Fake `NotificationScheduling` recording what `NotificationManager` posts and
/// registers, so posting behaviour is testable without a real
/// `UNUserNotificationCenter` (which needs an app bundle absent in `swift test`).
/// Shared: two suites drive the same manager, and a protocol requirement added
/// in one place should not have to be implemented twice.
final class FakeNotificationScheduler: NotificationScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var _added: [UNNotificationRequest] = []
    private(set) weak var delegate: (any UNUserNotificationCenterDelegate)?
    private(set) var authRequested = false

    init() {}

    var added: [UNNotificationRequest] {
        lock.lock(); defer { lock.unlock() }; return _added
    }

    func add(_ request: UNNotificationRequest) {
        lock.lock(); _added.append(request); lock.unlock()
    }

    func setDelegate(_ delegate: (any UNUserNotificationCenterDelegate)?) {
        self.delegate = delegate
    }

    func requestAuthorization() {
        authRequested = true
    }
}
