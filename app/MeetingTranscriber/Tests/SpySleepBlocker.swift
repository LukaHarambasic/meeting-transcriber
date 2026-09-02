@testable import MeetingTranscriber

/// Spy `RecordingSleepBlocking` recording the hold/release calls a recording
/// makes, so the power-assertion wiring is testable without IOKit — whose
/// effect a unit test could not observe anyway.
///
/// Its own file, matching how the other shared doubles here are organised
/// (`MockRecorder`, `RecordingNotifier`, `FakeNotificationScheduler`), so a
/// second suite can drive it without importing another suite's file.
///
/// The `isHeld` guards mirror the production type's idempotence: a second
/// `hold` while held does nothing, and a `release` with nothing held does
/// nothing. A double that counted those anyway would let a real double-hold
/// leak past.
@MainActor
final class SpySleepBlocker: RecordingSleepBlocking {
    private(set) var holdCount = 0
    private(set) var releaseCount = 0
    private(set) var lastReason: String?
    private(set) var isHeld = false

    func hold(reason: String) {
        guard !isHeld else { return }
        holdCount += 1
        lastReason = reason
        isHeld = true
    }

    func release() {
        guard isHeld else { return }
        releaseCount += 1
        isHeld = false
    }
}
