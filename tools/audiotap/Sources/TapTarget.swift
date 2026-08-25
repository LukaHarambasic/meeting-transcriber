import Foundation

/// What a `CATapDescription` should listen to.
///
/// The original shape only knew how to name processes, which is right for a
/// detected meeting app (Zoom, Teams, a browser tab) but has no answer for
/// "record whatever the Mac plays" — a "Record Meeting" mode that starts
/// before any participant app is known, or that must also pick up a caller
/// joining mid-meeting from an app nobody enumerated. `.systemMixdown` exists
/// for exactly that case: it hands `CATapDescription` the global-tap
/// initializer instead of a process list, so nothing needs identifying up
/// front.
public enum TapTarget: Sendable, Equatable {
    /// Tap the given processes (root PID plus helpers). The original shape.
    case processes([pid_t])
    /// Tap the system-wide output mixdown — everything the Mac plays.
    case systemMixdown
}
