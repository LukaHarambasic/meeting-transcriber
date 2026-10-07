import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "WatchLoop")

/// The poll loop that decides when a manually started recording ends, split out
/// of `WatchLoop.swift` to keep that file under the line cap.
///
/// Only the monitor moved. The start and stop paths mutate `activeRecorder`
/// and `manualRecordingTask`, both of which are private to the class on
/// purpose, and moving them here would mean widening those to internal for a
/// line count. The monitor reads nothing but injected dependencies.
extension WatchLoop {
    func monitorManualRecording(pid: pid_t?) async {
        let startTime = nowProvider()
        // Per recording by construction: one monitor task runs per recording,
        // so a new recording starts from an empty state and one meeting's call
        // can never arm the rule for the next.
        var callEnd = CallEndState()
        while !Task.isCancelled {
            // No PID means a microphone-only recording, which has no process
            // that could exit; the duration cap below is its only stop signal.
            let target: ManualRecordingTarget = pid.map { pidAliveCheck($0) ? .alive : .exited } ?? .untargeted
            let decision = ManualRecordingMonitorPolicy.step(
                target: target,
                elapsed: nowProvider().timeIntervalSince(startTime),
                maxDuration: maxDuration,
            )
            switch decision {
            case .continuePolling:
                break

            case .stopPidExited:
                logger.info("Monitored app (PID \(pid ?? 0)) exited — stopping manual recording")
                stopManualRecording()
                return

            case .stopMaxDurationExceeded:
                logger.info("Max recording duration reached — stopping manual recording")
                stopManualRecording()
                return
            }
            // After the hard stop conditions, not before: a recording whose
            // target already exited should end for that reason, with that log
            // line, rather than being attributed to an unanswered check.
            let now = nowProvider()
            if stepCallEnd(state: &callEnd, now: now) { return }
            // Sampled every poll, because the point is to catch speech whenever
            // it happens, not only when an ask is due.
            let attendance = sampleAttendance(now: now)
            // Queried only while an ask is outstanding: that is the sole branch
            // of the policy that reads it, and this loop runs every few seconds
            // for the length of a meeting.
            let deliverability: AskDeliverability = if confirmationPromptedAt == nil {
                .unknown
            } else {
                await askDeliverability()
            }
            guard stepConfirmation(now: now, attendance: attendance, deliverability: deliverability) else { return }
            try? await sleepProvider(pollInterval)
        }
    }

    /// One call-end step, run from the monitor's poll. Returns true when the
    /// recording was stopped, so the monitor can exit rather than poll a loop
    /// that is now idle.
    ///
    /// A disabled setting clears the state instead of merely skipping the step:
    /// otherwise a run observed before it was switched off would still count as
    /// unbroken after it is switched back on.
    private func stepCallEnd(state: inout CallEndState, now: Date) -> Bool {
        guard autoStopWhenCallEnds() else {
            state = CallEndState()
            return false
        }
        let (next, decision) = callEndPolicy.step(
            state: state,
            micUsage: micUsage(),
            now: now,
        )
        state = next
        guard decision == .stopCallEnded else { return false }
        let released = Int(now.timeIntervalSince(next.releasedSince ?? now))
        logger.info("Call ended (microphone released by every other process for \(released)s), stopping manual recording")
        stopManualRecording()
        // Best effort only: notifications are switched off on some machines, so
        // nothing here may depend on this one being seen. The recording is
        // already stopped and saved.
        notifier.notify(
            title: "Recording Stopped",
            body: "The call ended, so the recording was stopped and saved.",
            urgency: .standard,
        )
        return true
    }
}
