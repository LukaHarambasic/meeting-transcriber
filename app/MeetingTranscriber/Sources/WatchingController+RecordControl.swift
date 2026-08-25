import Foundation

/// The `/v1/record` control surface: manual recordings as an idempotent
/// resource a remote caller can drive, alongside the watch control in
/// `WatchingController` proper.
///
/// Its own file because that one sits at the line cap; the handful of members it
/// reaches into (`settings`, `watchLoop`, `manualStartTask`, `joinStarts`,
/// `joinManualStart`, `beginManualRecording`, `stopManualRecording`,
/// `startWatching`) are internal rather than private for exactly that.
///
/// Every action is scoped to the recording its payload describes — the
/// microphone when the payload names nothing else (the endpoint's original,
/// only shape), or a specific app's capture. Anything *else* the loop can be
/// doing is somebody else's recording here: a start refuses rather than
/// clobbering it, and a stop leaves it alone rather than ending a meeting the
/// caller never asked about.
@MainActor
extension WatchingController {
    /// Whether a microphone-only recording is in progress.
    ///
    /// Derived from `activeRecordingSource`, the loop's own answer to "what is
    /// being captured", rather than from a flag this file would have to keep in
    /// step. It reads nil until the loop is actually recording, which is why
    /// every caller below settles the in-flight starts first.
    var isRecordingMicrophoneOnly: Bool {
        watchLoop?.activeRecordingSource == .micOnly
    }

    /// Whether something other than a microphone recording owns the loop.
    ///
    /// Both halves of that matter. It is what makes a start a 409 instead of a
    /// clobbered recording (#624), and it is what keeps a microphone recording
    /// that is *already running* out of the way of a request to start one — that
    /// is not a conflict, it is the requested end state.
    var isRecordingOtherThanMicrophone: Bool {
        guard let source = watchLoop?.activeRecordingSource else { return false }
        return source != .micOnly
    }

    /// Whether a manual start is registered but has not produced a recording
    /// yet. Deliberately not "some manual recording exists": an app recording
    /// that is already running is reported by `isRecordingOtherThanMicrophone`,
    /// and calling that pending would tell a key to wait for something that is
    /// never going to become its recording.
    var isManualStartPending: Bool {
        manualStartTask != nil
    }

    /// Whether the recording `request` describes is the one in progress.
    ///
    /// The app case matches only a *manual* recording of the same pid: an
    /// auto-detected meeting of that app is deliberately not "the requested
    /// recording", because a caller who never started it must not be able to
    /// stop it, and a start alongside it is a conflict, not a satisfied wish.
    private func isRecordingRequested(_ request: ManualRecordingRequest) -> Bool {
        switch request {
        case .microphone:
            return isRecordingMicrophoneOnly

        case let .app(pid, _, _):
            guard let loop = watchLoop, loop.isManualRecording else { return false }
            return loop.activeRecordingSource != nil && loop.manualRecordingInfo?.pid == pid
        }
    }

    /// Whether a recording that is *not* the requested one owns the loop — the
    /// 409 predicate, generalised from `isRecordingOtherThanMicrophone` so an
    /// app-scoped request refuses against a mic recording (and against a
    /// different app's) the same way a mic request refuses against an app's.
    private func isOtherRecordingActive(than request: ManualRecordingRequest) -> Bool {
        guard watchLoop?.activeRecordingSource != nil else { return false }
        return !isRecordingRequested(request)
    }

    /// Apply a record action against the microphone — the payload-less shape the
    /// menu-adjacent callers and the original API clients use.
    @discardableResult
    func applyRecordAction(_ action: RecordAction) async -> RecordControlOutcome {
        await applyRecordAction(RecordActionPayload(action: action))
    }

    /// Apply a record action, resolving `.toggle` against settled state.
    ///
    /// The join leads, for the reason `applyWatchAction` gives: deciding against
    /// a mid-launch snapshot would read "nothing is recording" for a recording
    /// that is seconds from running, and start a second one.
    @discardableResult
    func applyRecordAction(_ payload: RecordActionPayload) async -> RecordControlOutcome {
        // The route 400s an invalid payload before calling in; this guard is for
        // direct callers, and .failed is honest — nothing was asked for.
        guard let request = payload.manualRecordingRequest else { return .failed }
        guard await joinStarts() else { return .failed }
        switch payload.action {
        case .start: return await applyRecordStart(request)

        case .stop: return applyRecordStop(matching: request)

        case .toggle:
            return isRecordingRequested(request)
                ? applyRecordStop(matching: request)
                : await applyRecordStart(request)
        }
    }

    /// Idempotent start. Awaits the start it launched — mic gate, queue, loop
    /// construction, the permission gate inside `WatchLoop` — so the caller
    /// reports the settled result rather than a snapshot taken mid-launch, and
    /// so a refusal reaches it as a refusal instead of as a silent no-op.
    private func applyRecordStart(_ request: ManualRecordingRequest) async -> RecordControlOutcome {
        if isRecordingRequested(request) { return .unchanged }
        if isOtherRecordingActive(than: request) { return .blocked }
        // "No Microphone" refuses only a recording that would capture nothing
        // under it. An app recording still captures the app's audio.
        if case .microphone = request, settings.noMic { return .refused }
        // Read before the start, because the start is what takes the loop away.
        let wasWatching = isWatching
        // nil means an ownership guard refused between the check above and here.
        guard let start = beginManualRecording(request) else { return .blocked }
        // Bound the start we just launched, not only the ones we found running.
        // Without this the endpoint has no deadline at all in the one case the
        // docs name for its 503: an unanswered microphone prompt.
        guard await joinManualStart() else { return .failed }
        switch await start.value {
        // Trust the result rather than re-reading the state: a stop that landed
        // between the task finishing and this line would turn a recording that
        // started, and was then deliberately ended, into "did not settle".
        case .started: return .changed
        case .blockedByActiveRecording: return .blocked
        case .permissionRefused: await rearmWatching(wasWatching); return .refused
        case .failed: await rearmWatching(wasWatching); return .failed
        }
    }

    /// Put meeting watching back after a start that captured nothing.
    ///
    /// A manual start stops an active auto loop before it knows whether it can
    /// record, so a refusal leaves detection off. That is survivable in the menu
    /// bar, where the icon shows it. Over the API it is not: the answer says
    /// "nothing changed, fix a setting and retry" while the machine has quietly
    /// stopped watching for meetings, and nothing re-arms it until relaunch.
    private func rearmWatching(_ wasWatching: Bool) async {
        guard wasWatching, !isWatching else { return }
        await startWatching()
    }

    /// Idempotent stop, and only of the recording the request describes.
    ///
    /// Anything else running reports `.unchanged` rather than `.blocked`: the
    /// requested recording is not in progress, so the asked-for end state
    /// already holds and there is nothing to refuse. Same asymmetry
    /// `stopWatching` documents, and the same reason — a stop that reached
    /// across and ended somebody else's meeting would be far worse than a 200
    /// that did nothing.
    private func applyRecordStop(matching request: ManualRecordingRequest) -> RecordControlOutcome {
        guard isRecordingRequested(request) else { return .unchanged }
        let loop = watchLoop
        let errorBeforeStop = loop?.lastError
        stopManualRecording()
        if isRecordingRequested(request) { return .failed }
        // A stop whose recorder threw is not a success, however idle the loop
        // looks afterwards: `WatchLoop.stopManualRecording` skips the enqueue on
        // a throw, so there is no job, no transcript and no protocol, and this
        // controller has already dropped the loop that knows why. Answering 200
        // there tells the caller their recording is safe when it is gone.
        if let errorAfterStop = loop?.lastError, errorAfterStop != errorBeforeStop {
            return .failed
        }
        return .changed
    }
}
