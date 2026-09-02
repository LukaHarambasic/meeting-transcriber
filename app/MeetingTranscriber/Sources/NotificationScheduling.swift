import os.log
import UserNotifications

/// Port over the slice of `UNUserNotificationCenter` that `NotificationManager`
/// uses (add / register categories / set delegate / request permission), so its
/// posting + registration behaviour is testable against a fake. The real center
/// needs a proper app bundle and can't run in `swift test`, which is exactly why
/// the behaviour has to be driven through this seam.
///
/// The concrete `SystemNotificationScheduler` is the thin, deliberately-untested
/// adapter — its pass-throughs are exercised by the e2e-app lane's real
/// notifications, which unit coverage can't reach.
protocol NotificationScheduling: AnyObject, Sendable {
    func add(_ request: UNNotificationRequest)
    func setDelegate(_ delegate: (any UNUserNotificationCenterDelegate)?)
    func requestAuthorization()
    /// Register the action categories the app posts against. Required for the
    /// still-recording ask: a notification whose `categoryIdentifier` names an
    /// unregistered category still delivers, just with no buttons — a silent
    /// downgrade that leaves the user no way to answer, and the unanswered ask
    /// then stops their recording.
    func setCategories(_ categories: Set<UNNotificationCategory>)
}

/// Real adapter: forwards to `UNUserNotificationCenter.current()`. Sendable (its
/// only state is a `Logger`), so its `requestAuthorization` completion — a
/// `@Sendable` closure — can reference it.
final class SystemNotificationScheduler: NotificationScheduling, Sendable {
    private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "NotificationScheduler")

    /// Completion-handler form, only for the error. The fire-and-forget
    /// overload discards it, so a rejected post looked exactly like a
    /// successful one from inside the app. `.public` on the message:
    /// `localizedDescription`, never `String(describing:)`, which can carry a
    /// home-directory path.
    func add(_ request: UNNotificationRequest) {
        // The identifier is lifted out because `UNNotificationRequest` is not
        // Sendable and the completion is a `@Sendable` closure.
        let id = request.identifier
        UNUserNotificationCenter.current().add(request) { error in
            guard let error else { return }
            self.logger.error(
                """
                notification_post_failed id=\(id, privacy: .public) \
                error=\(error.localizedDescription, privacy: .public)
                """,
            )
        }
    }

    func setDelegate(_ delegate: (any UNUserNotificationCenterDelegate)?) {
        UNUserNotificationCenter.current().delegate = delegate
    }

    func setCategories(_ categories: Set<UNNotificationCategory>) {
        UNUserNotificationCenter.current().setNotificationCategories(categories)
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                self.logger.error("Notification permission error: \(error.localizedDescription, privacy: .public)")
            }
            if !granted {
                self.logger.warning("Notification permission denied")
            }
        }
    }
}
