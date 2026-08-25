import Foundation

/// Wire shape for `GET`/`POST /v1/record` — the microphone-recording lifecycle
/// as a small, stable projection, for a Stream Deck key, a Shortcut, or a shell
/// script to poll and drive.
///
/// The fields are facts, not advice. A client decides what to draw from them:
/// `recording` for the key itself, and `otherRecordingActive` / `noMic` /
/// `microphoneHealthy` to explain a refusal it just received — or to grey the
/// key out before pressing.
struct RecordStatusDTO: Codable, Equatable {
    /// Whether a microphone-only recording is in progress.
    ///
    /// Deliberately narrower than "something is recording": an app or system
    /// capture is not this endpoint's recording, and reporting it here would
    /// invite a client to `stop` one it never started. `otherRecordingActive`
    /// carries those.
    let recording: Bool
    /// Whether a start has been accepted but is not recording yet.
    ///
    /// A start can sit for a while: it waits on the microphone permission gate,
    /// and on a first run that means an OS dialog nobody has answered. Without
    /// this field the whole window reads as plain idle, so a key that renders
    /// "press to start" from `recording` keeps offering a press that will only
    /// queue behind the one already waiting.
    let startPending: Bool
    /// `WatchLoop.State` raw value (`idle`/`recording`/`error`), or nil when no
    /// loop exists.
    let state: String?
    /// `BadgeKind` raw value — what the menu bar icon is showing right now.
    let badge: String
    /// Whether an app or system capture (rather than a plain microphone
    /// recording) owns the loop. A start is refused with 409 while this is
    /// true, because it would clobber a recording already in progress.
    let otherRecordingActive: Bool
    /// Whether the user set "No Microphone (app audio only)". A start is refused
    /// with 412 while it is: honouring the setting here would record nothing,
    /// and overriding it would put on tape the one thing the setting exists to
    /// keep off it.
    let noMic: Bool
    /// False only when a microphone probe has actually failed — denied, or
    /// allowed-but-not-working. A check that has not run yet reports true, so
    /// an unknown result never reads as broken.
    ///
    /// Scoped to the one permission a microphone recording needs, not the
    /// aggregate: a denied Screen Recording grant is irrelevant here (nothing
    /// taps a process), and reporting it would describe this endpoint as broken
    /// on exactly the machines where it is the capture path that still works.
    let microphoneHealthy: Bool
    /// The Screen Recording arm, on the same unknown-reads-true terms. It
    /// explains the 412 the microphone fields cannot: an `app` or `system`
    /// start opens a process tap, which that grant gates (it is the only
    /// preflightable proxy for the tap), while a plain microphone start is
    /// unaffected however unhealthy this reads.
    let screenRecordingHealthy: Bool

    /// Fallback for the window between server start and `AppState` being
    /// reachable. Reports "not recording, nothing in the way" rather than
    /// failing the request, so a client polling on an interval never has to
    /// special-case launch.
    static let notRecording = Self(
        recording: false,
        startPending: false,
        state: nil,
        badge: BadgeKind.inactive.rawValue,
        otherRecordingActive: false,
        noMic: false,
        microphoneHealthy: true,
        screenRecordingHealthy: true,
    )
}

/// What a `POST /v1/record` asks for. `start`/`stop` sit alongside `toggle`
/// because a caller driving a physical key (Stream Deck) often doesn't track
/// which state the recording is currently in — `toggle` lets it press blind.
enum RecordAction: String, Codable {
    case start
    case stop
    case toggle
}

/// What a record-control request actually achieved. Maps 1:1 onto the HTTP
/// status code, so a caller can tell "already recording" from "refused" without
/// diffing state before and after.
///
/// Deliberately not `Codable`: it never crosses the wire. The route reads it to
/// pick a status code and builds the body from `recordStatusDTO()`.
enum RecordControlOutcome: Equatable {
    /// The request changed the recording state. → 200
    case changed
    /// Already in the requested state; nothing to do. → 200
    case unchanged
    /// Refused: another recording owns the loop and starting would clobber it. → 409
    case blocked
    /// Refused on a precondition the caller has to fix first — "No Microphone"
    /// is set, or the microphone permission is denied or broken. → 412
    ///
    /// Distinct from `.failed` because retrying changes nothing: the answer is
    /// stable until someone flips a switch, in Settings or in System Settings.
    case refused
    /// The request was accepted but the state did not settle as asked. → 503
    case failed
}

/// What a `POST /v1/record` records. Absent from the payload means the
/// microphone — the payload's original, only shape — so every existing client
/// keeps the meaning it was written against.
///
/// `app` is the same capture the app picker starts: the target process's audio
/// plus the microphone (unless "No Microphone" is set). It exists on the wire so
/// automation can record a specific app without a human in front of the picker.
///
/// `system` is "Record Meeting": the whole system output mixdown plus the
/// microphone, for an in-room meeting with no single app to target.
enum RecordSource: String, Codable {
    case microphone = "mic"
    case app
    case system
}

/// Request body for `POST /v1/record`. An unrecognised action string fails to
/// decode, which the route turns into a 400 — better than silently treating a
/// typo'd verb as a toggle.
///
/// The optional fields describe the recording's target and are read only where
/// `source` makes them meaningful; `manualRecordingRequest` is the one place
/// that mapping lives, and its nil is what the route answers 400 with (an app
/// source without a pid names nothing recordable).
struct RecordActionPayload: Codable, Equatable {
    let action: RecordAction
    let source: RecordSource?
    /// Target process for `source == .app`; required there, ignored otherwise.
    let pid: Int32?
    /// Display name for the recording (menu bar, job list, sidecar). Read only
    /// for `source == .app`; defaults to "App".
    let appName: String?
    /// Meeting title, which drives output-file naming. Read only for
    /// `source == .app`; defaults to the app name.
    let title: String?

    init(
        action: RecordAction,
        source: RecordSource? = nil,
        pid: Int32? = nil,
        appName: String? = nil,
        title: String? = nil,
    ) {
        self.action = action
        self.source = source
        self.pid = pid
        self.appName = appName
        self.title = title
    }

    /// The manual-recording request this payload asks for, or nil when the
    /// payload names nothing recordable (an app source without a pid). The
    /// route turns that nil into a 400 before the controller is involved.
    ///
    /// `pid`/`appName`/`title` are ignored for `.system`: the identity of a
    /// "Record Meeting" recording is fixed by `ManualRecordingInfo`'s
    /// `meetingAppName`/`meetingTitle` constants, the same way `.microphone`
    /// ignores them for its own fixed identity.
    var manualRecordingRequest: ManualRecordingRequest? {
        switch source ?? .microphone {
        case .microphone:
            return .microphone

        case .system:
            return .meeting

        case .app:
            guard let pid else { return nil }
            let name = appName.flatMap { $0.isEmpty ? nil : $0 } ?? "App"
            let title = title.flatMap { $0.isEmpty ? nil : $0 } ?? name
            return .app(pid: pid_t(pid), appName: name, title: title)
        }
    }
}
