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
        scheduler.setCategories([Self.recordingConfirmationCategory()])
        scheduler.requestAuthorization()
    }

    // MARK: - Still-recording confirmation

    /// Category identifier for the "Still recording?" ask.
    static let recordingConfirmationCategoryID = "recording-confirmation"

    /// Action identifier for its "Keep Recording" button.
    static let keepRecordingActionID = "keep-recording"

    /// Posted when the user answers the ask, so the recording lifecycle hears
    /// about it without this AppKit-adjacent, non-`@MainActor` type reaching
    /// into `WatchLoop`. `AppState` observes it and forwards.
    static let recordingConfirmedNotification = Notification.Name("recordingStillWantedConfirmed")

    /// The category the ask is posted under, with the one action that answers it.
    ///
    /// `.foreground` on the action so answering also brings the app forward —
    /// harmless for a menu-bar app, and it means a click that macOS routes as
    /// the action rather than the default still visibly does something.
    static func recordingConfirmationCategory() -> UNNotificationCategory {
        let keep = UNNotificationAction(
            identifier: keepRecordingActionID,
            title: "Keep Recording",
            options: [.foreground],
        )
        return UNNotificationCategory(
            identifier: recordingConfirmationCategoryID,
            actions: [keep],
            intentIdentifiers: [],
            options: [],
        )
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
            content: Self.makeNotificationContent(
                title: title,
                body: body,
                categoryID: Self.categoryID(forTitle: title),
                urgency: urgency,
            ),
            trigger: nil,
        ))
    }

    /// Which action category a notification with this title belongs to, or nil
    /// for the ordinary no-buttons kind.
    ///
    /// Routing on the title rather than adding a `category` parameter to
    /// `AppNotifying.notify`: that protocol is deliberately narrow, is witnessed
    /// by a silent no-op and by test doubles, and its own doc comment explains
    /// why widening it invites conformers that quietly drop the new argument.
    /// One notification in the whole app has an action, and it owns its title as
    /// a shared constant, so a title match is exact rather than a guess.
    static func categoryID(forTitle title: String) -> String? {
        title == RecordingConfirmationPolicy.promptTitle ? recordingConfirmationCategoryID : nil
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
            return ("Name Speakers", "Speakers detected. Open the app to assign names.")

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

    /// Route an answered "Still recording?" ask back to the recording lifecycle.
    ///
    /// Both the "Keep Recording" button and a click on the banner body itself
    /// (`UNNotificationDefaultActionIdentifier`) count as an answer — the body
    /// click is the one most people make, and treating it as no answer would
    /// stop a recording the user just told the app they wanted. An explicit
    /// dismiss deliberately does not count: swiping the ask away is not
    /// confirming it.
    func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
    ) async {
        let content = response.notification.request.content
        guard content.categoryIdentifier == Self.recordingConfirmationCategoryID else { return }
        let answered = response.actionIdentifier == Self.keepRecordingActionID
            || response.actionIdentifier == UNNotificationDefaultActionIdentifier
        guard answered else { return }
        // Hop to the main actor: this delegate is invoked on an arbitrary queue
        // (the reason the whole class is `@unchecked Sendable` rather than
        // `@MainActor`), and the observer on the other end mutates `WatchLoop`.
        await MainActor.run {
            NotificationCenter.default.post(name: Self.recordingConfirmedNotification, object: nil)
        }
    }
}
