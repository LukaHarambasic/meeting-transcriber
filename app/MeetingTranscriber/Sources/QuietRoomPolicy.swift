import Foundation

/// What `QuietRoomPolicy` decided on one poll of the manual-recording monitor.
enum QuietRoomDecision: Equatable {
    /// Nothing to do: no evidence, another app owns the microphone, or the room
    /// has not been quiet for long enough.
    case wait
    /// The microphone has heard no speech for the whole quiet window. The
    /// recording should stop and be saved. Carries how long it had been quiet.
    case stopQuiet(quietFor: TimeInterval)
}

/// Decides when an in-person recording should end because nobody is talking.
///
/// The call-end rule cannot cover a meeting in a room: no other app ever holds
/// the microphone, so there is no release to wait for. This is its counterpart,
/// driven by the live speech detector instead of by CoreAudio's per-process
/// input flag.
///
/// Pure, with no state of its own: the reading carries both times, so the
/// monitor holds nothing extra for it and a new recording starts fresh by
/// construction.
///
/// Three rules, all deliberate:
///
/// 1. **No reading, no stop.** `.unavailable` means no detector is running
///    (no microphone channel, model still loading, load failed), which is no
///    evidence about the room.
/// 2. **Only a free microphone allows it.** While another app holds the input
///    the user is probably on a call and may just be listening, which is the
///    call-end rule's case. `.unknown` is no evidence either, so only `.free`
///    lets this rule stop anything.
/// 3. **The clock starts when listening started.** Until the first speech the
///    quiet run is measured from `since`, never from the recording's start, so
///    a detector that began late still observes the whole window rather than
///    having it assumed.
struct QuietRoomPolicy: Equatable {
    /// How long the microphone must hear no speech before the room counts as
    /// empty. Ten minutes outlasts a long pause for thought or a screen share
    /// being walked through, and stopping wrongly costs the rest of a meeting,
    /// never what was captured, since the recording is saved.
    static let defaultQuietWindow: TimeInterval = 10 * 60

    let quietWindow: TimeInterval

    init(quietWindow: TimeInterval = Self.defaultQuietWindow) {
        self.quietWindow = quietWindow
    }

    /// The window as a short phrase for the notification, such as "10 minutes".
    /// Never below a minute, so an injected test window still reads sensibly.
    var windowDescription: String {
        let minutes = max(1, Int((quietWindow / 60).rounded()))
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    func decide(
        micSpeech: MicSpeechReading,
        micUsage: MicUsage,
        now: Date,
    ) -> QuietRoomDecision {
        guard micUsage == .free else { return .wait }
        guard case let .listening(since, lastSpeech) = micSpeech else { return .wait }
        let quietFor = now.timeIntervalSince(lastSpeech ?? since)
        return quietFor >= quietWindow ? .stopQuiet(quietFor: quietFor) : .wait
    }
}
