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

    /// The lock is taken in a *synchronous* helper deliberately. `NSLock.lock()`
    /// and `unlock()` are `noasync`, so taking the lock directly inside
    /// `alertDeliverability()` (which the protocol requires to be `async`) is a
    /// hard compile error, not a warning: "instance method 'lock' is unavailable
    /// from asynchronous contexts". Calling a sync method that locks is the
    /// sanctioned shape. Every other member here locks from a sync context
    /// already, which is why this is the only one that needs the indirection.
    private func recordDeliverabilityCall() -> AskDeliverability {
        lock.lock()
        defer { lock.unlock() }
        _alertDeliverabilityCallCount += 1
        return _alertDeliverabilityStub
    }

    // `async` without an `await`: the signature is fixed by the protocol
    // requirement, which the real adapter satisfies with a continuation.
    // swiftlint:disable:next async_without_await
    func alertDeliverability() async -> AskDeliverability {
        recordDeliverabilityCall()
    }
}
