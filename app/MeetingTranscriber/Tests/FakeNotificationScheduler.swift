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
    private(set) var categories: Set<UNNotificationCategory> = []
    private var _alertDeliverabilityStub: AskDeliverability = .unknown
    private var _alertDeliverabilityCallCount = 0

    init() {}

    var added: [UNNotificationRequest] {
        lock.lock(); defer { lock.unlock() }; return _added
    }

    /// What `alertDeliverability()` returns on its next call. Defaults to
    /// `.unknown`, matching the protocol's own default so a test that never
    /// sets this stub exercises the same fallback production hits when a
    /// scheduler forgets the requirement.
    var alertDeliverabilityStub: AskDeliverability {
        get { lock.lock(); defer { lock.unlock() }; return _alertDeliverabilityStub }
        set { lock.lock(); _alertDeliverabilityStub = newValue; lock.unlock() }
    }

    /// How many times `alertDeliverability()` has been called, so a test can
    /// assert the query actually happened rather than just that its result
    /// was honoured.
    var alertDeliverabilityCallCount: Int {
        lock.lock(); defer { lock.unlock() }; return _alertDeliverabilityCallCount
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

    func setCategories(_ categories: Set<UNNotificationCategory>) {
        self.categories = categories
    }

    // `async` without an `await`: the signature is fixed by the protocol
    // requirement, which the real adapter satisfies with a continuation.
    // swiftlint:disable:next async_without_await
    func alertDeliverability() async -> AskDeliverability {
        lock.lock()
        _alertDeliverabilityCallCount += 1
        let stub = _alertDeliverabilityStub
        lock.unlock()
        return stub
    }
}
