import Foundation

/// What the still-recording check decided on one poll of the manual-recording
/// monitor.
enum RecordingConfirmationDecision: Equatable {
    /// Nothing due. Either the interval has not elapsed, or a prompt is
    /// outstanding and still inside its grace period.
    case wait
    /// Speech was heard recently enough to prove the recording is wanted.
    /// The caller resets `confirmedAt` and clears any outstanding prompt, so
    /// a meeting people are talking in is never asked and never stopped.
    ///
    /// Distinct from `.wait` because it mutates the caller's clock. Returning
    /// `.wait` here would leave a prompt posted mid-meeting standing, and its
    /// grace period would then expire while everyone was still speaking.
    case attended
    /// Ask the user whether the recording should continue.
    case prompt
    /// The outstanding prompt went unanswered for the whole grace period, the
    /// ask was deliverable, and the levels do not contradict it — stop the
    /// recording (and save it).
    case stopUnconfirmed
    /// The grace period expired on an ask the system could not deliver. Keep
    /// recording and surface it where the user will actually see it (the menu),
    /// because the silence proves nothing about the user.
    ///
    /// A recording that outlives its ask this way is bounded by
    /// `WatchLoop.maxDuration`, so this defers the runaway guard rather than
    /// removing it.
    case keepUnanswerable
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

    /// How recent measured speech has to be to count as proof the recording is
    /// still attended. Deliberately its own knob rather than reusing `grace`
    /// or `interval`: this is about how quickly the room can go quiet after
    /// the last word (a meeting winding down), not about how long an ask may
    /// go unanswered or how often to ask in the first place.
    ///
    /// Five minutes, the same value as `defaultGrace` today, but the two are
    /// not the same question and are allowed to diverge later.
    static let defaultAttentionWindow: TimeInterval = 5 * 60

    let interval: TimeInterval
    let grace: TimeInterval
    let attentionWindow: TimeInterval

    init(
        interval: TimeInterval = Self.defaultInterval,
        grace: TimeInterval = Self.defaultGrace,
        attentionWindow: TimeInterval = Self.defaultAttentionWindow,
    ) {
        self.interval = interval
        self.grace = grace
        self.attentionWindow = attentionWindow
    }

    /// - Parameters:
    ///   - now: current time.
    ///   - confirmedAt: when the recording was last known to be wanted — the
    ///     start time, or the last confirmation.
    ///   - promptedAt: when the outstanding ask was posted, or nil if none is.
    ///   - attendance: measured audio evidence for the current recording, independent
    ///     of whether anyone has answered a prompt.
    ///   - deliverability: whether the OS actually surfaced (or would surface) the ask,
    ///     independent of whether measured audio says anyone is there.
    ///
    /// Rule order is load-bearing, not incidental:
    ///
    /// 1. Recent speech wins over everything else, including an outstanding,
    ///    already-expired prompt. A prompt is posted from a single instant's
    ///    silence; if the room goes quiet for a beat around minute 30 the ask
    ///    still fires, and without this rule taking priority, five minutes of
    ///    grace could run out while the meeting was audibly still going,
    ///    stopping a live 55-minute meeting at 35. Checking attendance first
    ///    means speech at any point before the grace deadline reopens the
    ///    question instead of the countdown finishing regardless.
    /// 2. Otherwise, an outstanding prompt is judged on its own: still inside
    ///    grace waits; past grace with no corroborating attendance and a
    ///    deliverable ask stops the recording; past grace with either no
    ///    level data at all or an ask that could not reach the user keeps
    ///    recording instead, because unanswered silence is not evidence of
    ///    anything when the ask was never truly asked.
    /// 3. With nothing outstanding, the interval alone decides whether it is
    ///    time to ask.
    func step(
        now: Date,
        confirmedAt: Date,
        promptedAt: Date?,
        attendance: RecordingAttendance,
        deliverability: AskDeliverability,
    ) -> RecordingConfirmationDecision {
        // A `.lastSpeech` older than `attentionWindow` is deliberately treated
        // the same as `.noSpeechObserved` below, not as a weaker positive
        // signal: this is exactly the "meeting ended and the room went
        // quiet" case the whole feature exists to catch, so stale speech
        // must not keep protecting a recording indefinitely.
        if case let .lastSpeech(heardAt) = attendance, now.timeIntervalSince(heardAt) < attentionWindow {
            return .attended
        }
        if let promptedAt {
            if now.timeIntervalSince(promptedAt) < grace {
                return .wait
            }
            // `.unmonitored` (no recorder, no level data at all) can never
            // stop a recording: without levels the app has neither an answer
            // nor evidence either way, and treating silence-of-evidence as
            // silence-of-attendance would be exactly the false stop this
            // rewrite exists to remove. `WatchLoop.maxDuration` (four hours)
            // remains the backstop for a recording that runs unattended this
            // way.
            if attendance == .unmonitored {
                return .keepUnanswerable
            }
            // An ask that could not be delivered (muted at the OS level, or
            // `.timeSensitive` unavailable without a provisioning profile) is
            // not evidence the user was asked and declined to answer — it is
            // evidence the user was never asked. `.unknown` counts as not
            // answerable for the same reason: an ask whose delivery cannot be
            // confirmed must not be allowed to end a recording on the strength
            // of a silence that might just be undelivered mail.
            if !deliverability.canBeAnswered {
                return .keepUnanswerable
            }
            return .stopUnconfirmed
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
        let tail = "Click here to keep going. Otherwise the recording stops and is saved in "
        return lead + tail + String(minutes) + " minutes."
    }
}
