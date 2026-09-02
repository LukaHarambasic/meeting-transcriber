import AppKit
import Foundation

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
    private var observers: [any NSObjectProtocol] = []

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
    }

    /// Deregister explicitly. Not called in production — `AppState` owns the one
    /// monitor and lives for the whole process, the same reasoning its other
    /// permanent observer is annotated with — but a test that builds a monitor
    /// per case needs a way to stop the previous one from also answering.
    ///
    /// A `deinit` doing this would be the obvious home and cannot be: `deinit`
    /// is nonisolated and `observers` is main-actor isolated, which Swift 6
    /// rejects.
    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers {
            center.removeObserver(observer)
        }
        observers = []
    }
}
