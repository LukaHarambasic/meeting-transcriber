import Foundation

/// What one poll of the system found about the microphone.
///
/// A three-case enum rather than `Bool?` because the third case is a real
/// answer with its own rule (it is no evidence either way), and an optional
/// boolean reads as "false, if you forgot to check".
enum MicUsage: Equatable {
    /// At least one process other than this app is capturing from an input
    /// device: a conferencing app holding its call open.
    case held
    /// Every process other than this app is off the microphone.
    case free
    /// The probe could not tell. Never counts toward arming or stopping.
    case unknown
}

/// What `CallEndPolicy` decided on one poll of the manual-recording monitor.
enum CallEndDecision: Equatable {
    /// Nothing to do: no call has been seen yet, the call is still going, or
    /// the release has not lasted long enough.
    case wait
    /// A call was seen, and every other process has stayed off the microphone
    /// for the whole release grace. The recording should stop and be saved.
    case stopCallEnded
}

/// What the call-end rule has observed so far in one recording.
///
/// A value the monitor holds for the length of one recording and starts fresh
/// for the next, so one meeting's call can never vouch for the following one.
struct CallEndState: Equatable {
    /// When the current unbroken run of "another process holds the microphone"
    /// began, or nil when the last poll did not see one.
    var micHeldSince: Date?
    /// True once another process held the microphone for a whole
    /// `minimumCallDuration` in this recording. Latches: the recording stays
    /// armed through later releases, because the release is what it waits for.
    var callSeen: Bool = false
    /// When the current unbroken run of "nobody else holds the microphone"
    /// began, or nil when the last poll did not see one. Only runs once
    /// `callSeen` is set, so the log line can say how long the release lasted.
    var releasedSince: Date?
}

/// Decides when a meeting recording should end because the call ended.
///
/// The signal is the meeting app letting go of the microphone, read from
/// CoreAudio's per-process "is running input" flag. It replaces the idea of
/// judging a recording by how loud it is: the app's own audio tap hears
/// whatever the Mac plays (a music player is enough), so loudness says nothing
/// about whether a call is still on, while a conferencing app holds the input
/// open for exactly as long as the call lasts and releases it on hang-up.
///
/// Pure, and separate from the async monitor, for the same reason as
/// `RecordingConfirmationPolicy`: the interesting behaviour is when each
/// outcome becomes due, which is not worth asserting through real minutes.
///
/// Three rules, all deliberate:
///
/// 1. **A call has to be seen before it can end.** Another process must hold
///    the microphone continuously for `minimumCallDuration`. A dictation tool
///    or a voice memo taken during an in-person meeting lasts seconds and
///    must not arm the rule. A recording that never sees a call is never
///    stopped by this policy; the existing mechanisms cover it.
/// 2. **A release must last.** After a call was seen, the recording stops only
///    once the microphone has been free of every other process for
///    `releaseGrace`. Any poll that sees it held again restarts the countdown,
///    so back-to-back meetings keep recording.
/// 3. **Unknown is no evidence.** A failed probe (`.unknown`) neither arms the rule
///    nor advances a countdown. It also discards the run in progress, so the
///    two minutes have to be observed rather than assumed across a gap of
///    unknown length. The cost is that a probe that always fails never stops
///    anything, which is the safe direction.
struct CallEndPolicy: Equatable {
    /// How long another process must hold the microphone without a break to
    /// count as a call. A minute is longer than any dictation burst or voice
    /// memo during a meeting, and far shorter than any call worth recording.
    static let defaultMinimumCallDuration: TimeInterval = 60

    /// How long the microphone must stay free of other processes before the
    /// call counts as ended. Two minutes rides out someone hanging up to rejoin
    /// with a better connection and the gap between back-to-back meetings.
    /// Stopping wrongly costs the rest of a meeting, never what was captured,
    /// since the recording is saved.
    static let defaultReleaseGrace: TimeInterval = 120

    let minimumCallDuration: TimeInterval
    let releaseGrace: TimeInterval

    init(
        minimumCallDuration: TimeInterval = Self.defaultMinimumCallDuration,
        releaseGrace: TimeInterval = Self.defaultReleaseGrace,
    ) {
        self.minimumCallDuration = minimumCallDuration
        self.releaseGrace = releaseGrace
    }

    /// - Parameters:
    ///   - state: what has been observed so far in this recording.
    ///   - micUsage: whether any process other than this app is capturing from
    ///     an input device right now.
    ///   - now: current time.
    /// - Returns: the updated state, and whether to stop.
    func step(
        state: CallEndState,
        micUsage: MicUsage,
        now: Date,
    ) -> (CallEndState, CallEndDecision) {
        var next = state
        switch micUsage {
        case .unknown:
            next.micHeldSince = nil
            next.releasedSince = nil
            return (next, .wait)

        case .held:
            next.releasedSince = nil
            let heldSince = state.micHeldSince ?? now
            next.micHeldSince = heldSince
            if now.timeIntervalSince(heldSince) >= minimumCallDuration {
                next.callSeen = true
            }
            return (next, .wait)

        case .free:
            next.micHeldSince = nil
            guard state.callSeen else { return (next, .wait) }
            let releasedSince = state.releasedSince ?? now
            next.releasedSince = releasedSince
            let released = now.timeIntervalSince(releasedSince) >= releaseGrace
            return (next, released ? .stopCallEnded : .wait)
        }
    }
}
