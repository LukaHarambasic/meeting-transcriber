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

    /// Withdraw already-delivered notifications. Only the consent prompt needs
    /// it: macOS clears a notification the user tapped, but not one that
    /// expired or was answered out of band, so without this the dead prompts
    /// pile up in Notification Center.
    func removeDelivered(withIdentifiers identifiers: [String])

    func setCategories(_ categories: Set<UNNotificationCategory>)
    func setDelegate(_ delegate: (any UNUserNotificationCenterDelegate)?)
    func requestAuthorization()
}

/// Real adapter: forwards to `UNUserNotificationCenter.current()`. Sendable (its
/// only state is a `Logger`), so its `requestAuthorization` completion — a
/// `@Sendable` closure — can reference it.
final class SystemNotificationScheduler: NotificationScheduling, Sendable {
    private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "NotificationScheduler")

    /// Completion-handler form, only for the error. The fire-and-forget
    /// overload discards it, so a rejected post looked exactly like a
    /// successful one from inside the app — and the consent prompt is the one
    /// notification where that difference decides whether a meeting is
    /// recorded. `.public` on the message: `localizedDescription`, never
    /// `String(describing:)`, which can carry a home-directory path.
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

    func removeDelivered(withIdentifiers identifiers: [String]) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func setCategories(_ categories: Set<UNNotificationCategory>) {
        UNUserNotificationCenter.current().setNotificationCategories(categories)
    }

    func setDelegate(_ delegate: (any UNUserNotificationCenterDelegate)?) {
        UNUserNotificationCenter.current().delegate = delegate
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
