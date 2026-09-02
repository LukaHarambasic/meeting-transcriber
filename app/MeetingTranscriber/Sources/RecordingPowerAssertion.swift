import Foundation
import IOKit.pwr_mgt
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "RecordingPowerAssertion")

/// Keeps the Mac awake for the duration of a recording.
///
/// A seam rather than a bare type so a test can assert that a recording takes
/// the assertion and gives it back, without asking the machine's real power
/// management anything.
@MainActor
protocol RecordingSleepBlocking: AnyObject {
    /// Take the assertion. Idempotent — a second call while held does nothing,
    /// so a start path that runs twice cannot leak one.
    func hold(reason: String)
    /// Give it back. Safe to call when nothing is held.
    func release()
}

// `isHeld` is deliberately NOT a requirement here. Production only ever tells a
// blocker what to do, never asks it anything, and the tests that do ask hold the
// concrete `SpySleepBlocker`. As a requirement it was reachable through no call
// site at all, which `unused_declaration` correctly flagged: a protocol should
// require what is called through it, not everything its conformers happen to
// expose. Both conformers still have the property.

/// Production `RecordingSleepBlocking`: an IOKit power assertion of type
/// `kIOPMAssertPreventUserIdleSystemSleep`, held from the moment a recording
/// starts until it stops.
///
/// **Why this type of assertion and not the display one.** The reported failure
/// was a recording that stopped when the MacBook's screen darkened and the Mac
/// then went to sleep, with nothing saved. Idle *system* sleep suspends the
/// process and tears down the audio devices under it, which ends capture;
/// display sleep does not. Blocking only system sleep is therefore the whole
/// fix, and it deliberately leaves display sleep and the lock screen alone: the
/// screen still darkens and still asks for the password, which is what the user
/// asked to keep. `kIOPMAssertPreventUserIdleDisplaySleep` would additionally
/// keep the panel lit through every meeting, which nobody asked for and which
/// costs battery.
///
/// **What it cannot do.** An assertion only blocks *idle* sleep. Closing the lid
/// and choosing Sleep from the Apple menu both sleep the machine regardless, and
/// on Apple Silicon there is no assertion that changes that. Those paths are
/// covered by finalizing the recording on `NSWorkspace.willSleepNotification`
/// instead — see `WatchingController.finalizeForSleep()`. The two mechanisms are
/// complementary, and neither is sufficient alone: without the assertion an
/// unattended meeting is cut short at the idle timeout, and without the
/// sleep handler a closed lid loses the tail of the recording.
@MainActor
final class RecordingPowerAssertion: RecordingSleepBlocking {
    /// `IOPMAssertionID` of the live assertion, or nil when nothing is held.
    /// Nil-vs-zero rather than a separate flag: `IOPMAssertionRelease(0)` is not
    /// a documented no-op, so "is anything held" has to be answerable without
    /// consulting a sentinel value that IOKit might one day hand back for real.
    private var assertionID: IOPMAssertionID?

    var isHeld: Bool {
        assertionID != nil
    }

    func hold(reason: String) {
        // Through `isHeld` rather than `assertionID == nil` directly, so the
        // protocol's idempotence contract has exactly one definition and the
        // guard cannot drift from what the property reports.
        guard !isHeld else { return }
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id,
        )
        guard result == kIOReturnSuccess else {
            // Not fatal, and deliberately not surfaced to the user: the
            // recording still runs, it is just no longer protected from an idle
            // sleep. Reporting it would put a scary banner in front of someone
            // who is about to start a meeting and can do nothing about it.
            logger.error("power_assertion_failed status=\(result, privacy: .public)")
            return
        }
        assertionID = id
        logger.info("power_assertion_held id=\(id, privacy: .public)")
    }

    func release() {
        guard let id = assertionID else { return }
        assertionID = nil
        let result = IOPMAssertionRelease(id)
        if result == kIOReturnSuccess {
            logger.info("power_assertion_released id=\(id, privacy: .public)")
        } else {
            logger.error("power_assertion_release_failed status=\(result, privacy: .public)")
        }
    }
}

// A `deinit` releasing a leaked assertion is deliberately absent: `deinit` is
// nonisolated, so reading the main-actor `assertionID` from it is a Swift 6
// error, and the fallback matters less than it looks. The kernel drops every
// assertion held by a dead process, and `WatchLoop` releases on both its stop
// paths (`stopManualRecording` and `cleanupManualRecording`), so the only way to
// leak one is to keep the process alive while dropping the loop — which no call
// site does.
