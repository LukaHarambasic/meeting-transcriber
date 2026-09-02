import Foundation

/// What the still-recording check decided on one poll of the manual-recording
/// monitor.
enum RecordingConfirmationDecision: Equatable {
    /// Nothing due. Either the interval has not elapsed, or a prompt is
    /// outstanding and still inside its grace period.
    case wait
    /// Ask the user whether the recording should continue.
    case prompt
    /// The outstanding prompt went unanswered for the whole grace period —
    /// stop the recording (and save it).
    case stopUnconfirmed
}

/// Decides when to ask "are you still recording?" and when an unanswered ask
/// ends the recording.
///
/// A recording nobody is attending is the failure mode this exists for: a
/// meeting that ended while the user walked away, and a Mac that then records
/// the room for hours. The duration cap (`WatchLoop.maxDuration`, four hours) is
/// too blunt to catch it — it is there to stop a runaway, not to notice an
/// absence.
///
/// Pure, and separated from the async monitor for the usual reason: the
/// interesting behaviour is entirely in *when* each of the three outcomes is
/// due, and asserting that through real 30-minute sleeps is not a test anyone
/// would run.
///
/// The prompt is deliberately one-at-a-time. `promptedAt` being non-nil means an
/// ask is outstanding, and while it is, the interval is not consulted at all —
/// so a user who ignores one prompt gets the grace period, not a second prompt
/// stacked on top of the first and a doubled deadline.
struct RecordingConfirmationPolicy: Equatable {
    /// How long a recording may run unattended before the app asks. 30 minutes,
    /// as requested: long enough not to interrupt a normal meeting twice, short
    /// enough that a forgotten recording costs half an hour of disk rather than
    /// a night.
    static let defaultInterval: TimeInterval = 30 * 60

    /// How long an outstanding ask may go unanswered before the recording stops.
    ///
    /// Five minutes is a judgement call, not a derived number, and it is the one
    /// knob worth revisiting: it is the window in which someone who is mid-flow
    /// (or looking at a locked screen) has to notice the notification. Too short
    /// ends live meetings; too long defeats the check. The cost of it firing
    /// wrongly is bounded — the recording is stopped *and saved*, so a mistake
    /// costs the rest of the meeting, never what was already captured.
    static let defaultGrace: TimeInterval = 5 * 60

    let interval: TimeInterval
    let grace: TimeInterval

    init(interval: TimeInterval = Self.defaultInterval, grace: TimeInterval = Self.defaultGrace) {
        self.interval = interval
        self.grace = grace
    }

    /// - Parameters:
    ///   - now: current time.
    ///   - confirmedAt: when the recording was last known to be wanted — the
    ///     start time, or the last confirmation.
    ///   - promptedAt: when the outstanding ask was posted, or nil if none is.
    func step(now: Date, confirmedAt: Date, promptedAt: Date?) -> RecordingConfirmationDecision {
        if let promptedAt {
            return now.timeIntervalSince(promptedAt) >= grace ? .stopUnconfirmed : .wait
        }
        return now.timeIntervalSince(confirmedAt) >= interval ? .prompt : .wait
    }

    // MARK: - Wording

    /// Title of the ask. Load-bearing, not cosmetic: `NotificationManager`
    /// matches on it to decide which notification carries the "Keep Recording"
    /// action and which answered notification to route back here, so an edit
    /// here silently removes the user's only way to answer. It lives on this
    /// type rather than on `WatchLoop` because `WatchLoop` is `@MainActor` and
    /// the notification delegate reading it is not.
    static let promptTitle = "Still recording?"

    static let timedOutBody = "Nobody confirmed the recording was still wanted, "
        + "so it was stopped. The audio is saved and is being processed."

    /// Body of the ask, naming the deadline it actually enforces.
    ///
    /// Built through explicitly-typed locals rather than one interpolated
    /// literal: an `Int(...)` conversion interpolated into a `+`-concatenated
    /// multi-line string took 1.8 s to type-check at the call site, against this
    /// package's 300 ms warnings-as-errors budget.
    var promptBody: String {
        let minutes = Int(grace / 60)
        let lead = "Meeting Transcriber has been recording for a while. "
        let tail = "Click here to keep going — otherwise the recording stops and is saved in "
        return lead + tail + String(minutes) + " minutes."
    }
}
