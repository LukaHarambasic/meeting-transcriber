import Foundation

/// What a single recording captures.
///
/// Replaces the `(appPID: pid_t, noMic: Bool)` pair the recording path used to
/// pass around. That pair had no way to express "microphone, no app tap"
/// (issue #633) without also being able to express "no app tap and no
/// microphone", which is a recording of nothing. Folding both questions into
/// one value makes that state unrepresentable.
///
/// It also gives the consumers downstream a single thing to switch on. The
/// permission gate needs to know whether a process tap is opened, not which
/// PID it targets, and the channel-health monitors need to know which channels
/// exist at all — a level of `-120` cannot tell a deliberately absent channel
/// from a dead one.
enum RecordingSource: Equatable {
    /// Tap the target process and record the microphone alongside it. The
    /// ordinary meeting and "Record App..." shape.
    case appAndMic(pid: pid_t)

    /// Tap the target process only, because the user set "No Microphone".
    case appOnly(pid: pid_t)

    /// Record the microphone with no process tap at all, for a meeting that
    /// happens in the room rather than in an app.
    case micOnly

    /// Tap the whole system output mixdown and record the microphone
    /// alongside it — "Record Meeting": everything the Mac plays plus the
    /// room, for a meeting whose remote side plays through the speakers
    /// rather than headphones.
    case systemAndMic

    /// Tap the system mixdown only, because the user set "No Microphone".
    case systemOnly
}

extension RecordingSource {
    /// The process to tap, or nil when this source opens no tap — including
    /// both system-wide cases, which tap the whole output mixdown rather than
    /// any one process. Also the process whose exit ends the recording — a
    /// microphone-only or system-wide session has none, so only its duration
    /// cap applies.
    var appPID: pid_t? {
        switch self {
        case let .appAndMic(pid), let .appOnly(pid): pid
        case .micOnly, .systemAndMic, .systemOnly: nil
        }
    }

    /// Whether a CATap process tap is opened. Explicit per case rather than
    /// derived from `appPID != nil`: the system-wide cases target no single
    /// process, so a PID-based derivation would read them as opening no tap —
    /// wrong, since `.systemMixdown` is itself a tap, and the Screen Recording
    /// arm of the permission gate (that grant is only a preflightable proxy for
    /// the tap) applies to it exactly as it does to an app tap.
    var capturesAppAudio: Bool {
        switch self {
        case .appAndMic, .appOnly, .systemAndMic, .systemOnly: true
        case .micOnly: false
        }
    }

    /// Whether the microphone is recorded.
    var capturesMicrophone: Bool {
        switch self {
        case .appAndMic, .micOnly, .systemAndMic: true
        case .appOnly, .systemOnly: false
        }
    }

    /// The source for a recording aimed at a running app, honouring the user's
    /// "No Microphone (app audio only)" setting.
    static func forApp(pid: pid_t, noMic: Bool) -> Self {
        noMic ? .appOnly(pid: pid) : .appAndMic(pid: pid)
    }

    /// The source for "Record Meeting" — the whole system output plus the
    /// microphone, honouring the same "No Microphone" setting the app path
    /// does.
    static func forSystem(noMic: Bool) -> Self {
        noMic ? .systemOnly : .systemAndMic
    }

    var capturedChannels: CapturedChannels {
        switch self {
        case .appAndMic, .systemAndMic: .micAndApp
        case .appOnly, .systemOnly: .appOnly
        case .micOnly: .micOnly
        }
    }

    /// How this source names its target in logs. One wording so `PID 1234`
    /// finds every line about that recording, whichever subsystem wrote it.
    var logDescription: String {
        switch self {
        case let .appAndMic(pid), let .appOnly(pid): "PID \(pid)"
        case .micOnly: "microphone only"
        case .systemAndMic: "system audio"
        case .systemOnly: "system audio only"
        }
    }
}

/// Which capture channels a recording actually opens.
///
/// The health monitors need exactly this and nothing else about the source.
/// They read per-channel levels, and `RecordingProvider` documents `-120` dBFS
/// as "no capture session is active **or** the tap stopped delivering buffers",
/// so a level alone cannot tell a channel that was never opened from one that
/// died. Without this they report the first as the second.
/// The three values mirror the three channel combinations `RecordingSource`'s
/// cases can produce (app-and-mic, app-only, mic-only — the system-wide cases
/// share the app-target values since a monitor cares which channels exist, not
/// what the app channel is tapping), and the memberwise init stays private so
/// the fourth combination stays unbuildable: a recording with neither channel
/// is the state `RecordingSource` exists to rule out, and a projection of it
/// must not quietly hand that state back.
struct CapturedChannels: Equatable {
    let mic: Bool
    let app: Bool

    private init(mic: Bool, app: Bool) {
        self.mic = mic
        self.app = app
    }

    /// The ordinary dual-source recording, and the default the monitors assume
    /// when nobody says otherwise.
    static let micAndApp = Self(mic: true, app: true)
    /// "No Microphone (app audio only)".
    static let appOnly = Self(mic: false, app: true)
    /// A microphone-only recording (issue #633).
    static let micOnly = Self(mic: true, app: false)
}
