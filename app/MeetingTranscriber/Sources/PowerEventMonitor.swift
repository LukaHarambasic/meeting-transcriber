import AppKit
import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "PowerEventMonitor")

/// Bridges the two `NSWorkspace` power notifications a recording has to react to
/// into plain closures, so the recording lifecycle never imports AppKit and can
/// be driven from a test by calling the closures directly.
///
/// Both notifications come from `NSWorkspace.shared.notificationCenter`, not
/// `NotificationCenter.default` — the same name registered on the default center
/// is never posted, which is a silent no-op rather than an error, so it is worth
/// having exactly one place that gets it right.
///
/// `willSleep` is delivered synchronously and macOS waits (briefly) for every
/// observer to return before it sleeps. The handler is therefore expected to do
/// the short thing — close the capture and hand the recording to the queue —
/// and nothing that waits on the network or a model load.
@MainActor
final class PowerEventMonitor {
    /// Retained so the observers outlive the initialiser. Dropping them would
    /// deregister silently, which looks exactly like a machine that never
    /// slept — hence the `discarded_notification_center_observer` lint rule.
    ///
    /// Retention is its whole job; nothing reads it. `AppState` owns the one
    /// monitor and lives for the whole process, the same reasoning its other
    /// permanent observer is annotated with, so there is no deregistration path
    /// to write. (A `stop()` for symmetry was written and deleted: nothing
    /// called it, which the `unused_declaration` analyzer caught. `deinit`
    /// cannot do it either — `deinit` is nonisolated and this is `@MainActor`.)
    private let observers: [any NSObjectProtocol]

    init(
        onWillSleep: @escaping @MainActor () -> Void,
        onDidWake: @escaping @MainActor () -> Void,
    ) {
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(
                forName: NSWorkspace.willSleepNotification, object: nil, queue: .main,
            ) { _ in MainActor.assumeIsolated { onWillSleep() } },
            center.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main,
            ) { _ in MainActor.assumeIsolated { onDidWake() } },
        ]
        // Worth a breadcrumb precisely because the failure this guards against
        // is silent: registering on the wrong notification center, or dropping
        // the tokens, both look exactly like a Mac that never slept. If a
        // recording is lost to a lid close, the first question is whether the
        // handler was ever armed, and this answers it.
        logger.info("power_event_monitor_armed observations=\(self.observers.count, privacy: .public)")
    }
}
