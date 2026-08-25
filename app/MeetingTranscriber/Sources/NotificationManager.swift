import Foundation
import os.log
import UserNotifications

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "NotificationManager")

/// Sends macOS notifications for meeting state transitions. Marked
/// `@unchecked Sendable` because:
/// - `UNUserNotificationCenter` is thread-safe per Apple's docs
/// - `isSetUp` is written exactly once in `setUp()` (called from the
///   `@main` scene) and read thereafter, so no real race
/// `@MainActor` would be cleaner but conflicts with the
/// `UNUserNotificationCenterDelegate` callbacks, which the framework
/// invokes from arbitrary queues.
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate, AppNotifying, @unchecked Sendable {
    static let shared = NotificationManager()

    private(set) var isSetUp = false

    #if !APPSTORE
        /// Bounded in-memory log of every notification posted through
        /// `notify(...)`, read by the dev-only debug RPC `/state.notifications`
        /// snapshot (via the `AppNotifying.recentNotifications` conformance).
        /// Gated out of the App Store variant, which has no RPC reader.
        let recentNotificationsLog = NotificationRingBuffer()

        var recentNotifications: [NotificationRingBuffer.Entry] {
            recentNotificationsLog.entries
        }
    #endif

    /// The notification center behind a port (so posting + registration are
    /// testable against a fake) and the "can we deliver?" check (a real app
    /// bundle is required — `Bundle.main.bundleIdentifier` is nil in `swift
    /// test`). Both injected; production uses the real system center + the bundle
    /// check, tests inject a fake scheduler and flip `canDeliver`.
    private let scheduler: any NotificationScheduling
    private let canDeliver: @Sendable () -> Bool

    init(
        scheduler: any NotificationScheduling = SystemNotificationScheduler(),
        canDeliver: @escaping @Sendable () -> Bool = { Bundle.main.bundleIdentifier != nil },
    ) {
        self.scheduler = scheduler
        self.canDeliver = canDeliver
        super.init()
    }

    /// Set up delegate and request permission. Must be called after the app bundle is loaded.
    func setUp() {
        guard !isSetUp else { return }
        // UNUserNotificationCenter crashes without a proper app bundle.
        guard canDeliver() else {
            logger.warning("Skipping setup — notifications not deliverable")
            return
        }
        isSetUp = true
        scheduler.setDelegate(self)
        scheduler.requestAuthorization()
    }

    func notify(title: String, body: String, urgency: NotificationUrgency) {
        let deliverable = isSetUp && canDeliver()

        #if !APPSTORE
            // Record before the delivery guard so the app's *decision* to notify
            // is captured even in headless/test contexts where
            // `UNUserNotificationCenter` (which needs a real app bundle) is
            // absent. The `posted` flag preserves that distinction, and claims
            // nothing beyond it — whether anything was actually rendered to the
            // user is a separate question this flag does not answer.
            recentNotificationsLog.record(title: title, body: body, posted: deliverable)
        #endif

        guard deliverable else { return }

        scheduler.add(UNNotificationRequest(
            identifier: UUID().uuidString,
            content: Self.makeNotificationContent(title: title, body: body, urgency: urgency),
            trigger: nil,
        ))
    }

    /// Pure builder for a notification's `UNMutableNotificationContent` (title,
    /// body, sound, optional category, urgency). Split out so the content
    /// mapping is unit-testable without a real notification center.
    ///
    /// `urgency` defaults to `.standard`, a banner that auto-dismisses and is
    /// suppressed under Focus, which is right for anything the user can read
    /// whenever they get round to it. `NotificationUrgency` is the app's whole
    /// vocabulary here, so this is the only place a raw
    /// `UNNotificationInterruptionLevel` is set.
    static func makeNotificationContent(
        title: String,
        body: String,
        categoryID: String? = nil,
        urgency: NotificationUrgency = .standard,
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = urgency.interruptionLevel
        if let categoryID { content.categoryIdentifier = categoryID }
        return content
    }

    /// Pure function: determines notification content for a state transition.
    /// Returns nil if no notification should be sent.
    static func notificationContent(
        for state: TranscriberState,
        status: TranscriberStatus,
    ) -> (title: String, body: String)? {
        switch state {
        case .recording:
            let meetingTitle = status.meeting?.title ?? "Unknown"
            let app = status.meeting?.app ?? ""
            return ("Meeting Detected", "Recording: \(meetingTitle) (\(app))")

        case .protocolReady:
            let meetingTitle = status.meeting?.title ?? "Meeting"
            return ("Protocol Ready", "Protocol for \"\(meetingTitle)\" is ready.")

        case .waitingForSpeakerNames:
            return ("Name Speakers", "Speakers detected — open the app to assign names")

        case .error:
            if let error = status.error {
                return ("Transcriber Error", error)
            }
            return nil

        default:
            return nil
        }
    }

    /// Handle state transitions and send appropriate notifications.
    func handleTransition(
        from _: TranscriberState?,
        to newState: TranscriberState,
        status: TranscriberStatus,
    ) {
        if let content = Self.notificationContent(for: newState, status: status) {
            notify(title: content.title, body: content.body)
        }
    }

    // Show notifications even when app is in foreground
    // swiftlint:disable:next async_without_await
    func userNotificationCenter(_: UNUserNotificationCenter, willPresent _: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
