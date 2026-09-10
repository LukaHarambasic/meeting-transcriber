import Foundation
import Observation

// MARK: - PermissionsController

/// Owns live TCC permission-health state and the debounced re-check.
///
/// Extracted from `AppState` as the first concern-specific controller (see the
/// AppState god-class split). `AppState` exposes it as a sub-controller and
/// composes its `health` into `currentBadge`.
///
/// Every caller of this controller is proactive (launch, app activation,
/// `/state`), so its probe must be `PermissionHealthCheck.runPassive()`, which
/// opens no audio device. Wiring the probing variant in here is what made
/// opening the menu bar dropdown break the user's Bluetooth playback; the
/// reasoning is written out on `runPassive` and is not a detail of this class.
///
/// The `probe` seam additionally lets tests exercise the debounce +
/// notification logic without touching real TCC.
@Observable
@MainActor
final class PermissionsController {
    /// Latest health result from `check()` / `handle(_:)`. Drives the menu-bar
    /// permission-problem overlay and the `currentBadge` `.error` state.
    private(set) var health: HealthCheckResult?

    /// Timestamp of the last completed `check()` run. Used to debounce repeated
    /// calls triggered by `NSApplication.didBecomeActiveNotification`, which
    /// fires on every Cmd-Tab and every menu bar dropdown.
    ///
    /// This is a cheapness measure only. It was once the *mitigation* for the
    /// mic probe churning the audio HAL, and it never worked as one: the probe
    /// is gone from this path instead (see `PermissionHealthCheck.runPassive`).
    private(set) var lastCheckAt: Date?

    private let notifier: any AppNotifying
    private let probe: () async -> HealthCheckResult

    init(
        notifier: any AppNotifying,
        probe: @escaping () async -> HealthCheckResult = { PermissionHealthCheck.runPassive() },
    ) {
        self.notifier = notifier
        self.probe = probe
    }

    /// Store the latest health result and notify on a newly-appeared problem
    /// set. A repeated identical problem set is deduped (no re-notify); a
    /// recovery to healthy clears the dedup memory so the next problem notifies.
    func handle(_ result: HealthCheckResult) {
        let previousProblems = health?.problems ?? []
        health = result
        let line = "[PermissionHealthCheck] screen=\(result.screenRecording) mic=\(result.microphone) " +
            "healthy=\(result.isHealthy) problems=\(result.problems)"
        PermissionHealthCheck.debugLog(line)

        let problems = result.problems
        if !problems.isEmpty, problems != previousProblems {
            PermissionHealthCheck.debugLog("[PermissionHealthCheck] Sending notification: \(result.notificationBody)")
            notifier.notify(
                title: "Permission Problem",
                body: result.notificationBody,
            )
        }
    }

    /// Run the live permission health check.
    ///
    /// - Parameter minimumInterval: if non-nil, skip the run when the last completed check
    ///   happened less than `minimumInterval` seconds ago. The initial startup call passes
    ///   `nil` so it always runs; the `didBecomeActive` handler passes a small value so
    ///   rapid re-activations don't repeat the work.
    func check(minimumInterval: TimeInterval? = nil) async {
        if let minimumInterval, let last = lastCheckAt,
           Date().timeIntervalSince(last) < minimumInterval {
            return
        }
        let result = await probe()
        lastCheckAt = Date()
        handle(result)
    }
}
