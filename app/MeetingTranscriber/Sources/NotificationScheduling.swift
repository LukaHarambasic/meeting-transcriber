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

    /// Whether the system will actually show an alert for this app right now.
    ///
    /// Has a default (below) rather than being satisfied at every conformer,
    /// so a test double that predates this requirement keeps compiling. The
    /// default answers `.unknown`, not `.deliverable`: `AskDeliverability`
    /// treats `.unknown` as not answerable, so a conformer that forgets this
    /// requirement makes the still-recording check cautious (it falls back to
    /// asking and, absent an answer, stopping), never destructive (it never
    /// reads a silently-suppressed ask as a real answer). Same reasoning as
    /// `AppNotifying.notify`'s urgency parameter in `AppState.swift`: default
    /// toward the safer failure, not the convenient one.
    func alertDeliverability() async -> AskDeliverability
}

extension NotificationScheduling {
    // `async` without an `await`: the signature is fixed by the requirement
    // above, which the real adapter satisfies with a continuation.
    // swiftlint:disable:next async_without_await
    func alertDeliverability() async -> AskDeliverability {
        .unknown
    }
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

    /// `getNotificationSettings` is completion-handler based and
    /// `UNNotificationSettings` is not `Sendable`, so the two fields this reads
    /// are pulled out *inside* the completion, mirroring why `add(_:)` above
    /// lifts `request.identifier` out before crossing the same boundary — the
    /// continuation is resumed with the resulting `AskDeliverability`, never
    /// with the settings object itself.
    func alertDeliverability() async -> AskDeliverability {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                let authorizationStatus = settings.authorizationStatus
                let alertSetting = settings.alertSetting
                let result: AskDeliverability = switch (authorizationStatus, alertSetting) {
                case (.authorized, .enabled), (.provisional, .enabled):
                    .deliverable

                case (.authorized, .disabled), (.provisional, .disabled):
                    .suppressed

                case (.denied, _), (.notDetermined, _), (.ephemeral, _):
                    .suppressed

                // Matched positively on `.enabled` rather than treating
                // "not disabled" as deliverable: `.notSupported` and any future
                // case would otherwise fall into `.deliverable`, which is the
                // one direction that can end a recording. `.unknown` is read as
                // not answerable downstream, so an unrecognised setting keeps
                // the recording instead.
                default:
                    .unknown
                }
                continuation.resume(returning: result)
            }
        }
    }
}
