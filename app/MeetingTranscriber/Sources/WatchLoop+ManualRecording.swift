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
            if stepMeetingEnd(state: &callEnd, now: now) { return }
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

    /// One meeting-end step, run from the monitor's poll: the call-end rule and
    /// the quiet-room rule, both behind the one setting. Returns true when the
    /// recording was stopped, so the monitor can exit rather than poll a loop
    /// that is now idle.
    ///
    /// The microphone is sampled once and both rules read that sample, so they
    /// can never disagree about whether another app held it on this poll. The
    /// call-end rule is asked first: when both are due, the call is the better
    /// explanation for the stop.
    ///
    /// A disabled setting clears the call-end state instead of merely skipping
    /// the step: otherwise a run observed before it was switched off would still
    /// count as unbroken after it is switched back on. The quiet-room rule has
    /// no state to clear.
    private func stepMeetingEnd(state: inout CallEndState, now: Date) -> Bool {
        guard autoStopWhenMeetingEnds() else {
            state = CallEndState()
            return false
        }
        let usage = micUsage()
        return stepCallEnd(state: &state, usage: usage, now: now)
            || stepQuietRoom(usage: usage, now: now)
    }

    private func stepCallEnd(state: inout CallEndState, usage: MicUsage, now: Date) -> Bool {
        let (next, decision) = callEndPolicy.step(
            state: state,
            micUsage: usage,
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

    private func stepQuietRoom(usage: MicUsage, now: Date) -> Bool {
        let decision = quietRoomPolicy.decide(
            micSpeech: micSpeech(),
            micUsage: usage,
            now: now,
        )
        guard case let .stopQuiet(quietFor) = decision else { return false }
        let quietSeconds = Int(quietFor)
        logger.info("No speech on the microphone for \(quietSeconds)s, stopping manual recording")
        stopManualRecording()
        // Best effort only, for the same reason as the call-end notification.
        let window = quietRoomPolicy.windowDescription
        let body = "Nobody has spoken for \(window), so the recording was stopped and saved."
        notifier.notify(
            title: "Recording Stopped",
            body: body,
            urgency: .standard,
        )
        return true
    }
}
