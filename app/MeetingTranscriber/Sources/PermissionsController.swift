import Foundation
import Observation

// MARK: - PermissionsController

/// Owns live TCC permission-health state and the debounced re-check.
///
/// Extracted from `AppState` as the first concern-specific controller (see the
/// AppState god-class split). `AppState` exposes it as a sub-controller and
/// composes its `health` into `currentBadge`.
///
/// The `probe` seam lets tests exercise the debounce + notification logic
/// without the real ~500 ms `PermissionHealthCheck.runLive()` TCC probe, which
/// churns the audio HAL and was untestable while wired directly into AppState.
@Observable
@MainActor
final class PermissionsController {
    /// Latest health result from `check()` / `handle(_:)`. Drives the menu-bar
    /// permission-problem overlay and the `currentBadge` `.error` state.
    private(set) var health: HealthCheckResult?

    /// Timestamp of the last completed `check()` run. Debounces the repeated
    /// calls that `NSApplication.didBecomeActiveNotification` produces.
    ///
    /// It no longer protects the audio HAL: this controller's probe does not
    /// open the microphone at all (see `init`). Kept because the screen-recording
    /// check and the notification dedup are still worth not re-running on every
    /// Cmd-Tab.
    private(set) var lastCheckAt: Date?

    private let notifier: any AppNotifying
    private let probe: () async -> HealthCheckResult

    init(
        notifier: any AppNotifying,
        // `.trustSystemVerdict`, not the default `.probe`: this controller runs at
        // launch and on every app activation, and opening the microphone there
        // drags a Bluetooth headset out of A2DP into HFP, corrupting the user's
        // playback until they reconnect it. A headset is usually the default
        // input as well as the default output, so "just checking the mic" breaks
        // the audio they are listening to. The debounce below predates this and
        // only reduced how often it happened.
        probe: @escaping () async -> HealthCheckResult = {
            await PermissionHealthCheck.runLive(micProbe: .trustSystemVerdict)
        },
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
    ///   `nil` so it always runs; the `didBecomeActive` handler passes a small value to
    ///   avoid HAL churn on rapid re-activations.
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
